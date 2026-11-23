# drvcpp

Build and test C and C++ projects with Meson and Ninja. A Rust planner reads the project's hashed `subprojects/*.wrap` archives inside a dynamic Nix derivation. Nix fetches each source archive and WrapDB patch by its locked checksum. Meson then uses the populated package cache with downloads disabled.

```sh
nix run github:drvlang/drvcpp -- build -C ./app
nix run github:drvlang/drvcpp -- test -C ./app
nix run github:drvlang/drvcpp -- run -C ./app -- --help
```

Enable `ca-derivations`, `dynamic-derivations` and `recursive-nix` in Nix and the build daemon. The builder needs the `recursive-nix` system feature. The flake supports x86-64 and AArch64 Linux.

The builder accepts public HTTPS `[wrap-file]` archives and projects with no external packages. Use `--options '{"mesonFlags":["-Dtests=enabled"]}'` for a project's Meson options. Nix callers can supply `nativeBuildInputs` and `buildInputs` for tools and system libraries. For a project that installs several programs, select one with `--options '{"program":"my-tool"}'`.

## Flakes and monorepos

Use `drvcpp.lib.mkFlake { src = ./.; }` for one project. In a shared Meson project, give each command the directory where its single installed executable is declared. Meson builds the root workspace and exposes the selected member's installed binary with its shared libraries. A repository of independent Meson projects can use the same directory map.

```nix
outputs = { drvcpp, ... }: drvcpp.lib.mkMonorepoFlake {
  src = ./.;
  commands = { api = "apps/api"; worker = "apps/worker"; };
};
```

Use `nix build .#api`, `nix run .#worker` and `nix flake check`. For the same names on the CLI, put `{"commands":{"api":"apps/api","worker":"apps/worker"}}` in `drvlang.json` and run `drvcpp test api`. Tests select Meson tests that depend on the member's targets or belong to a suite named for the member directory. When neither is declared, they run the project's full suite. Use `testSuite` to select a suite explicitly. [Working workspace](tests/workspace)

## Benchmark

The check builds Cisco OpenH264 with its pinned GoogleTest archive and Meson patch, runs its upstream suites and links a separate C++ client against the installed codec. The Rust runner repeats the client build and checks encoder initialization. [Benchmark definition](benchmarks/default.nix) · [OpenH264 source](https://github.com/cisco/openh264/tree/78783f195ce116ecbaea83f7fac0ea8a355518b5)

```sh
nix run github:drvlang/drvcpp#bench -- --runs 5
```
