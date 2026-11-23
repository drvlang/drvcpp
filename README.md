# drvcpp

Build C and C++ projects with Meson and Ninja from `subprojects/*.wrap`. The Rust planner reads `[wrap-file]` locks. Nix fetches each source archive and WrapDB patch by its SHA-256 and seeds Meson's package cache. Meson then builds and tests with downloads disabled.

```sh
nix run github:drvlang/drvcpp -- build -C ./app
```

Pass project options with `--options '{"mesonFlags":["-Dtests=enabled"]}'`. In Nix, use `drvcpp.lib.mkFlake { src = ./app; }` or `lib.mkPackage { system, src, ... }` and supply any native build tools or system libraries through `nativeBuildInputs` and `buildInputs`. The builder supports public HTTPS archive wraps in the standard `subprojects` directory. Local patch overlays are applied by Meson. Nix reads the Rust planner output during evaluation.

## Benchmark

The check builds Cisco OpenH264 with its pinned GoogleTest archive and Meson patch, runs the upstream suites, and links a separate C++ client against the installed codec. The Rust runner repeats the client build and checks encoder initialization. [Benchmark definition](benchmarks/default.nix) · [OpenH264 source](https://github.com/cisco/openh264/tree/78783f195ce116ecbaea83f7fac0ea8a355518b5)

```sh
nix run github:drvlang/drvcpp#bench -- --runs 5
```
