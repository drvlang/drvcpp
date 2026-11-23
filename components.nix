# Evaluated by the recursive planner after the selected source is realized.
{ pkgs, build, plans, components }:
args:
let
  inherit (pkgs) lib;
  root = if builtins.pathExists (args.src + "/meson.build") then args.src
         else args.src + "/${args.memberPath}";
  names = builtins.attrNames components;
  specFor = name: { dependsOn ? [], mesonFlags ? [] }:
    assert lib.assertMsg (lib.all (d: builtins.hasAttr d components) dependsOn)
      "separateSubprojects: unknown dependency of ${name}";
    { inherit dependsOn mesonFlags; };
  specs = builtins.mapAttrs specFor components;
  order = lib.toposort (a: b: lib.elem a specs.${b}.dependsOn) names;
  dependenciesOf = name: map (item: item.key) (builtins.genericClosure {
    startSet = map (key: { inherit key; }) specs.${name}.dependsOn;
    operator = item: map (key: { inherit key; }) specs.${item.key}.dependsOn;
  });
  libraries = builtins.mapAttrs (name: spec: let deps = dependenciesOf name; in build {
    # Re-import just this directory. An edit elsewhere must produce the same
    # source store path even when the outer project came from a derivation.
    src = builtins.path { path = root + "/subprojects/${name}"; name = "source"; };
    plan = builtins.fromJSON (builtins.readFile (plans + "/component-${name}.json"));
    builderName = "${args.builderName}-${name}";
    memberPath = ".";
    inherit (args) nativeBuildInputs doCheck;
    inherit (spec) mesonFlags;
    buildInputs = map (dep: libraries.${dep}) deps ++ args.buildInputs;
    externalSubprojects = deps;
    test = false;
    testSuite = null;
    testArgs = [];
  }) specs;
in assert lib.assertMsg (order ? result)
     "separateSubprojects: dependency cycle involving ${lib.concatStringsSep ", " order.cycle}";
   build (args // {
     buildInputs = map (name: libraries.${name}) names ++ args.buildInputs;
     externalSubprojects = names;
   })
