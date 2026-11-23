{ drvkit, test ? false }:
pkgs: { src, memberPath ? ".", mesonFlags ? [], nativeBuildInputs ? [], buildInputs ? [],
        doCheck ? true, testSuite ? null, testArgs ? [] }:
let
  inherit (pkgs) lib;
  dynamic = import (drvkit + "/dynamic.nix") { inherit pkgs; };
  planner = import ./planner.nix pkgs;
  inputs = deps: lib.concatMapStringsSep " "
    (dep: "(builtins.storePath ${lib.strings.escapeNixString (toString (lib.getDev dep))})") deps;
in dynamic {
  name = if test then "drvcpp-test" else "drvcpp-package";
  prepare = ''
    shopt -s nullglob
    root=${lib.escapeShellArg (toString src)}
    if [[ ! -f "$root/meson.build" ]]; then root="$root/"${lib.escapeShellArg memberPath}; fi
    if [[ ! -f "$root/meson.build" ]]; then echo "drvcpp: missing meson.build in $root" >&2; exit 1; fi
    ${planner}/bin/drvcpp-plan "$root"/subprojects/*.wrap > plan.json
  '';
  expression = ''
    let pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
    in import ${./build.nix} pkgs {
      src = builtins.storePath "${src}";
      memberPath = ${lib.strings.escapeNixString memberPath};
      plan = builtins.fromJSON (builtins.readFile ./plan.json);
      mesonFlags = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON mesonFlags)};
      testSuite = ${if testSuite == null then "null" else lib.strings.escapeNixString testSuite};
      testArgs = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON testArgs)};
      doCheck = ${lib.boolToString (doCheck || test)};
      test = ${lib.boolToString test};
      nativeBuildInputs = [ ${inputs nativeBuildInputs} ];
      buildInputs = [ ${inputs buildInputs} ];
    }
  '';
}
