{ drvkit, test ? false, name ? "drvcpp" }:
pkgs: { src, memberPath ? ".", mesonFlags ? [], nativeBuildInputs ? [], buildInputs ? [],
        doCheck ? true, testSuite ? null, testArgs ? [], separateSubprojects ? {} }:
let
  inherit (pkgs) lib;
  dynamic = import (drvkit + "/dynamic.nix") { inherit pkgs; };
  planner = import ./planner.nix pkgs;
  names = builtins.attrNames separateSubprojects;
  validName = n: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_+.-]*" n != null;
  inputs = deps: lib.concatMapStringsSep " "
    (dep: "(builtins.storePath ${lib.strings.escapeNixString (toString (lib.getDev dep))})") deps;
in assert lib.assertMsg (lib.all validName names) "Expected Meson subproject names in separateSubprojects";
dynamic {
  name = if test then "${name}-test" else "${name}-package";
  prepare = ''
    shopt -s nullglob
    root=${lib.escapeShellArg (toString src)}
    if [[ ! -f "$root/meson.build" ]]; then root="$root/"${lib.escapeShellArg memberPath}; fi
    if [[ ! -f "$root/meson.build" ]]; then echo "${name}: missing meson.build in $root" >&2; exit 1; fi
    ${planner}/bin/drvcpp-plan "$root"/subprojects/*.wrap > plan.json
    ${lib.optionalString (names != []) ''
      for name in ${lib.escapeShellArgs names}; do
        dir="$root/subprojects/$name"
        if [[ ! -f "$dir/meson.build" ]]; then
          echo "separateSubprojects: expected a local Meson project in subprojects/$name" >&2
          exit 1
        fi
        ${planner}/bin/drvcpp-plan "$dir"/subprojects/*.wrap > "component-$name.json"
      done
    ''}
  '';
  expression = ''
    let pkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
        build = import ${./build.nix} pkgs;
    in ${if names == [] then "build" else ''(import ${./components.nix} {
      inherit pkgs build;
      plans = ./.;
      components = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON separateSubprojects)};
    })''} {
      builderName = ${lib.strings.escapeNixString name};
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
