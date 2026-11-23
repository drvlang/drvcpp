{
  description = "Build C and C++ Meson projects from hashed wrap archives";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/6b5e5b7a6631f065bf6908986990b37d845f847f";
  inputs.drvkit = { url = "github:drvlang/drvkit"; flake = false; };

  outputs = { self, nixpkgs, drvkit, ... }: let tools = import drvkit {
    inherit self nixpkgs;
    name = "drvcpp";
    extraChecks = system: let args = {
      pkgs = nixpkgs.legacyPackages.${system}; inherit self system;
    }; in {
      benchmark = import ./benchmarks args;
      workspace = import ./tests args;
    };
    mkPackage = import ./package.nix { inherit drvkit; };
    mkTest = import ./package.nix { inherit drvkit; test = true; };
    selectTarget = { src, target, ... }: { inherit src; memberPath = target; };
  };
  in tools // {
    packages = nixpkgs.lib.mapAttrs (system: packages: packages // {
      plan = import ./planner.nix nixpkgs.legacyPackages.${system};
    }) tools.packages;
  };
}
