{ drvkit ? null, nixpkgs ? null, test ? false, name ? "drvcpp" }:
pkgs: { src, memberPath ? ".", mesonFlags ? [], nativeBuildInputs ? [], buildInputs ? [],
        doCheck ? true, testSuite ? null, testArgs ? [], separateSubprojects ? {}, componentSrc ? null }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  python = pkgs.python3;
  script = ./drvcpp.py;
  darwinFixup = if pkgs.stdenv.hostPlatform.isDarwin then ./fix-darwin-paths.sh else null;
  names = builtins.attrNames separateSubprojects;
  validName = n: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_+.-]*" n != null;

  config = {
    src = "${src}";
    inherit memberPath mesonFlags testSuite testArgs separateSubprojects;
    builderName = name;
    inherit system;
    python = "${python}";
    script = "${script}";
    toolchain = {
      stdenv = "${pkgs.stdenv}";
      bash = "${pkgs.bashNonInteractive}";
      meson = "${pkgs.meson}";
      ninja = "${pkgs.ninja}";
      pkgConfig = "${pkgs.pkg-config}";
    };
    darwinFixup = if darwinFixup == null then null else "${darwinFixup}";
    nativeBuildInputs = map (d: "${lib.getDev d}") nativeBuildInputs;
    buildInputs = map (d: "${lib.getDev d}") buildInputs;
    doCheck = doCheck || test;
    componentSrc = if componentSrc == null then null else "${componentSrc}";
  };

  planner = builtins.derivation {
    name = "${name}-package.drv";
    inherit system;
    builder = "${python}/bin/python3";
    args = [ "-S" script "plan" ];
    CONFIG_JSON = builtins.toJSON config;
    requiredSystemFeatures = [ "recursive-nix" ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };

  built = builtins.outputOf planner.outPath "out";
  isMember = !test && memberPath != ".";

  result = builtins.derivation ({
    name = if isMember then "${name}-member" else "${name}-package";
    inherit system;
    builder = "${python}/bin/python3";
    args = [ "-S" script (if isMember then "member" else "forward") ];
    TARGET = built;
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  } // lib.optionalAttrs isMember {
    BUILDER_NAME = name;
  });
in assert lib.assertMsg (lib.all validName names) "Expected Meson subproject names in separateSubprojects";
result // { inherit planner; passthru = { inherit planner; }; }
