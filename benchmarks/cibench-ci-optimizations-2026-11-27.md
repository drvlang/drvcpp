# Optimizing drvcpp for CI

Across all seven CIBench CI cases, replacing `drvcpp`'s Rust/Cargo wrap planner (`rustPlatform.buildRustPackage`), `drvkit/dynamic.nix`, `nix-instantiate`, `nixpkgsSource`, `jq`, and `linkFarm` with a self-contained Python 3 stdlib direct Nix daemon ATerm planner (reusing the Python interpreter already in `pkgs.meson`'s closure) reduced cold builds from 48.96 s to 4.19 s (11.68× faster), remote cache restores from 17.07 s / 768.2 MiB to 3.26 s / 213.7 MiB (5.24× faster, 72.2% less traffic), local warm checks from 1.22 s to 0.70 s (1.74× faster), remote edits from 43.48 s / 768.2 MiB to 5.47 s / 213.7 MiB (7.95× faster, matching `stdenv.mkDerivation` transfer byte-for-byte), local edits from 23.49 s to 2.98 s (7.88× faster), remote dependency updates from 41.38 s / 775.7 MiB to 6.19 s / 213.6 MiB (6.68× faster, 72.5% less traffic and less than `stdenv.mkDerivation`'s 221.2 MiB), and local dependency updates from 22.86 s to 3.18 s (7.19× faster).

CIBench builds a C++ Meson executable (`parse-ini`) depending on the `inih` wrap subproject and checks its output. The source edit modifies `main.cpp` and the expected output without changing `meson.build` or `subprojects/inih.wrap`. The independent dependency update upgrades `inih` from `r62` to `r63` in `subprojects/inih.wrap` without any separate Nix hash.

| CIBench case | drvcpp `9b0f92a` (s) | drvcpp optimized (s) | `stdenv.mkDerivation` (s) | drvcpp cache transfer (before → after) | drvcpp builds (before → after) | drvcpp peak RAM (before → after) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| cold | 48.96 | 4.19 | 3.73 | 0.0 → 0.0 MiB | 15 → 5 | 4081 → 1036 MiB |
| remote-warm | 17.07 | 3.26 | 1.01 | 768.2 → 213.7 MiB | 0 → 0 | 3572 → 995 MiB |
| local-warm | 1.22 | 0.70 | 0.67 | 0.0 → 0.0 MiB | 0 → 0 | 444 → 290 MiB |
| edit-remote | 43.48 | 5.47 | 5.22 | 768.2 → 213.7 MiB | 5 → 4 | 3604 → 1044 MiB |
| edit-local | 23.49 | 2.98 | 2.76 | 0.0 → 0.0 MiB | 5 → 4 | 544 → 343 MiB |
| dependency-remote | 41.38 | 6.19 | 5.28 | 775.7 → 213.6 MiB | 7 → 5 | 3632 → 1035 MiB |
| dependency-local | 22.86 | 3.18 | 3.01 | 0.0 → 0.0 MiB | 7 → 5 | 544 → 340 MiB |

Times are medians of two trials for `9b0f92a`, three trials for the optimized tree, and five trials for the shared Nixpkgs `stdenv.mkDerivation` comparator, run in alternating order (`before-1`, `after-1` ×2, `before-2`, `after-2`) with no competing host workloads. Both builders used GCC 15.3.0, Meson 1.10.2, and Ninja 1.13.2. Each sample timed evaluation and realization of the package and check together. [Individual timings, build counts, cache traffic, peak memory, and realized outputs](cibench-ci-optimizations-2026-11-27.csv)

## Summary of optimizations

1. **Replaced Rust/Cargo planner and `drvkit/dynamic.nix` with Python 3 stdlib Nix daemon ATerm planner (`drvcpp.py`, `package.nix`, `planner.nix`, `flake.nix`)**: Eliminated `rustPlatform.buildRustPackage` (`rustc-1.97.1`, `cargo`, `llvm-lib`, 30+ crates), `pkgs.nix`, `nixpkgsSource` (202 MiB), `boost`, `icu4c`, `aws-sdk`, `curl`, and sandbox Nixpkgs evaluation. Reuses `pkgs.python3` (already in `pkgs.meson`'s closure) with `python3 -S` and speaks protocol 1.21 directly over `NIX_REMOTE` (`wopQueryValidPaths`, `wopAddTextToStore`).
2. **Direct `builtin:fetchurl` wrap archives and native Python JSON introspection (`drvcpp.py`)**: Replaced `pkgs.fetchurl` (`curl`, `openssl-dev`, `krb5-dev`, `libssh2-dev`), `pkgs.linkFarm`, and `pkgs.jq` with `builtin:fetchurl` derivations, direct `subprojects/packagecache/` population, and stdlib `json` introspection of `meson-info/intro-*.json`.
3. **Zero-`stdenv` CA forwarder/member wrapper and `bashNonInteractive` (`package.nix`, `drvcpp.py`)**: Replaced `pkgs.runCommand` (`stdenv-linux-no-cc`) and `pkgs.bash` (`bash-interactive`) with a `python3 -S` CA symlink wrapper and `pkgs.bashNonInteractive`, cutting `cold` peak RAM from 4081 MiB to 1036 MiB and removing the inner `drvkit/forward.nix` indirection.

## Correctness checks

- Realized package and check outputs were deterministic across all three optimized trials and matched between `cold`, `remote-warm`, and `local-warm`, between `edit-remote` and `edit-local`, and between `dependency-remote` and `dependency-local`.
- `nix flake check -L --option allow-import-from-derivation false` passed all checks:
  - `checks.x86_64-linux.benchmark` (Cisco OpenH264 C++ codec with GoogleTest wrap + patch, NASM, and downstream C++ client)
  - `checks.x86_64-linux.workspace` (multi-member Meson workspace `api` and `worker` sharing `pkg`)
  - `checks.x86_64-linux.cli`
- `nix flake show --all-systems`, `nix build .#plan`, and `tests/components.sh` (separate subprojects `base` and `greeting`, floating CA early cutoff on comment-only edit, incremental rebuild on `greeting` edit without rebuilding `base`, cycle detection, fallback guard, independent monorepo shared planner) passed.

## Reproduction

The runner used x86_64 Linux, an Intel Core i7-1280P, Nix 2.35.3, four logical CPUs (16–19), four jobs, four cores per builder, 8 GiB RAM, and zero swap. Sandboxing was enabled and IFD disabled. The simulated project cache used 5 ms latency and 100 MiB/s aggregate bandwidth. Both builders used the same local mirror of signed NixOS packages populated from `drvkit/cibench/results/bootstrap/cpp.txt`. Cold jobs started with an empty local store and project cache. Subsequent cases independently used the original job's local store or its published project cache. The recorded runner was `/nix/store/vpysz8ih9lhm154cjaamrncwjn08njp6-cibench-0.1.0`.

```sh
work=$(mktemp -d)
stock="file://$work/stock"
nix copy --from https://cache.nixos.org --to "$stock?compression=zstd&compression-level=1" \
  --stdin < ../drvkit/cibench/results/bootstrap/cpp.txt
runner="$(nix build --impure --no-link --print-out-paths -f ../drvkit/cibench)/bin/cibench"
mkdir "$work/before"
git archive 9b0f92a | tar -x -C "$work/before"
run() {
  taskset -c 16-19 "$runner" cpp --builder "$1" --out "$work/$2" --trials "$3" \
    --cpus 4 --memory-mib 8192 --latency-ms 5 --bandwidth-mib-s 100 \
    --upstream "$stock?priority=40"
}
run "$work/before" before-1 1
run "$PWD" after-1 2
run "$work/before" before-2 1
run "$PWD" after-2 1
```
