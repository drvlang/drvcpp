{
  description = "Build C and C++ Meson projects from hashed wrap archives";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/6b5e5b7a6631f065bf6908986990b37d845f847f";
  inputs.drvkit = { url = "github:drvlang/drvkit"; flake = false; };

  outputs = { self, nixpkgs, drvkit, ... }: let
    reader = import (drvkit + "/source-reader.nix");
    tools = import drvkit {
      inherit self nixpkgs;
      toolSource = {
        root = ./.;
        files = [
          ./build.nix ./components.nix ./fix-darwin-paths.sh ./package.nix ./planner.nix
          ./planner/Cargo.toml ./planner/Cargo.lock ./planner/src ./project.nix
          ./select-target.nix
        ];
        benchmarkFiles = [ ./benchmarks/default.nix ./benchmarks/source.nix ./benchmarks/check.cpp ];
      };
      name = "drvcpp";
      projectArgs = import ./project.nix reader {
        name = "drvcpp";
        inherit (nixpkgs) lib legacyPackages;
        inherit (tools.lib) projectSource;
      };
      extraChecks = system: let args = {
        pkgs = nixpkgs.legacyPackages.${system}; inherit self system;
      }; in {
        benchmark = import ./benchmarks args;
        workspace = import ./tests args;
      };
      mkPackage = import ./package.nix { inherit drvkit nixpkgs; };
      mkTest = import ./package.nix { inherit drvkit nixpkgs; test = true; };
      selectTarget = import ./select-target.nix reader nixpkgs.lib;
    };
  in tools // {
    lib = tools.lib // {
      mesonBuilder = import ./package.nix;
      mesonProjectArgs = import ./project.nix reader;
      mesonSelectTarget = import ./select-target.nix reader;
      mkMonorepoFlake = args: tools.lib.mkMonorepoFlake (
        nixpkgs.lib.optionalAttrs (args ? root && !(args ? commands)) {
          commands = (builtins.fromJSON (builtins.readFile (args.root + "/drvlang.json"))).commands;
        } // args
      );
    };
    packages = nixpkgs.lib.mapAttrs (system: packages: packages // {
      plan = import ./planner.nix nixpkgs.legacyPackages.${system};
    }) tools.packages;
  };
}
