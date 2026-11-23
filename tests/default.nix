{ self, system, pkgs }:
let
  root = ./workspace;
  commands = (builtins.fromJSON (builtins.readFile ./workspace/drvlang.json)).commands;
  common = [
    ./workspace/meson.build
    ./workspace/pkg/meson.build
    ./workspace/pkg/shared.cpp
  ];
  srcForTarget = { target, ... }: let member = root + "/${target}";
  in self.lib.projectSource {
    inherit root;
    files = common ++ [ (member + "/meson.build") (member + "/main.cpp") ];
  };
  workspace = self.lib.mkMonorepoFlake { inherit commands srcForTarget; };
  apps = workspace.apps.${system};
in pkgs.runCommand "check-workspace" {
  __contentAddressed = true;
  memberTests = builtins.attrValues workspace.checks.${system};
} ''
  test "$(${apps.api.program})" = 'api drvlang'
  test "$(${apps.worker.program})" = 'worker drvlang'
  touch "$out"
''
