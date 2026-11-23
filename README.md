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

For one Meson project, use `drvcpp.lib.mkFlake` with a source selection covering its Meson files, sources and test inputs. In a shared Meson project, give each command the directory where its single installed executable is declared. Meson builds the root workspace and exposes the selected member's installed binary with its shared libraries. A repository of independent Meson projects can use the same directory map.

```nix
outputs = { drvcpp, ... }: drvcpp.lib.mkMonorepoFlake {
  srcForTarget = { target, ... }: let member = ./. + "/${target}";
  in drvcpp.lib.projectSource {
    root = ./.;
    files = [
      ./meson.build ./pkg/meson.build
      ./pkg/shared.cpp
      (member + "/meson.build") (member + "/main.cpp")
    ];
  };
  commands = { api = "apps/api"; worker = "apps/worker"; };
};
```

The example’s root Meson file enters a command directory when it exists. If your root always configures every sibling, include their Meson files and sources too. Include `./subprojects` for wraps and local patches, plus any options files or other build inputs.

In a checkout of independent Meson projects with no root `meson.build`, selecting a command automatically isolates its directory. Editing a sibling preserves both the selected package and its test derivation.

Use `nix build .#api`, `nix run .#worker` and `nix flake check`. For CLI target names, put `{"commands":{"api":"apps/api","worker":"apps/worker"}}` in `drvlang.json` and run `drvcpp test api`. Tests select Meson tests that depend on the member's targets or belong to a suite named for the member directory. When neither is declared, they run the project's full suite. Use `testSuite` to select a suite explicitly. [Working workspace](tests/workspace)

Read that same map in the flake with `commands = (builtins.fromJSON (builtins.readFile ./drvlang.json)).commands;`.

## Cache a compiled library across application edits

If an application uses an independently installable Meson project under `subprojects/`, give it its own Nix derivation. For a client that calls `dependency('openh264', fallback: ['openh264', 'openh264_dep'])`, put this in `drvlang.json`:

```json
{
  "drvcpp": {
    "files": ["meson.build", "check.cpp"],
    "tools": ["nasm"],
    "separateSubprojects": { "openh264": { "mesonFlags": ["-Dtests=disabled"] } }
  }
}
```

`drvcpp build` and `drvcpp test` reuse the installed codec when only `check.cpp` changes. All compiled outputs and checks are content-addressed by default. An edit that installs identical codec files and store references can also reuse the client. With manifest file selection, the builder reads each declared component from its own directory. Include a component header, version file, or asset in `files` if the parent reads it directly. A flake reads the same manifest with `drvcpp.lib.mkFlake { root = ./.; }`. In a monorepo, `files` and `targetFiles` also filter CLI inputs by command.

Use this for checked-in, self-contained Meson projects that export an installed dependency, such as a pkg-config library. Each entry builds with its own Meson flags. Set any options the parent normally passes to the fallback. Use `"dependsOn": ["base"]` for a library that consumes another selected component. Nix caches each installed library separately and rebuilds its consumers when it changes. Wrap-only dependencies and in-tree `subdir()` targets keep their existing build behavior. [Two-library example](tests/components)

## Benchmark

The check builds Cisco OpenH264 with its pinned GoogleTest archive and Meson patch, runs its upstream suites and links a separate C++ client against the installed codec. The Rust runner repeats the client build and checks encoder initialization. [Benchmark definition](benchmarks/default.nix) · [OpenH264 source](https://github.com/cisco/openh264/tree/78783f195ce116ecbaea83f7fac0ea8a355518b5)

```sh
nix run github:drvlang/drvcpp#bench -- --runs 5
```

To measure incremental builds, run the following from this checkout. Each command warms the build once, then times three distinct edits to the OpenH264 client, builds it, initializes an encoder, and verifies the edited output.

```sh
bash benchmarks/incremental/run.sh together 3
bash benchmarks/incremental/run.sh separate 3
```

On x86-64 Linux with Nix 2.35.3 and warm dependencies, the median client edit took 19.67 s with the codec built in-tree and 12.24 s with it cached separately. The final edit compiled 91 C/C++ objects in-tree and one with the separate codec.
