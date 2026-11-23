pkgs: { src, mesonFlags ? [], nativeBuildInputs ? [], buildInputs ? [], doCheck ? true }:
let
  inherit (pkgs) lib;
  subprojects = src + "/subprojects";
  files = builtins.filter (f: lib.hasSuffix ".wrap" f) (builtins.attrNames (builtins.readDir subprojects));
  wraps = pkgs.linkFarm "locked-meson-wraps" (map (name: {
    inherit name; path = pkgs.writeText name (builtins.readFile (subprojects + ("/" + name)));
  }) files);
  planner = import ./planner.nix pkgs;
  plan = builtins.fromJSON (builtins.readFile (pkgs.runCommand "drvcpp-plan.json" {} ''
    ${planner}/bin/drvcpp-plan ${lib.concatMapStringsSep " " (f: "${wraps}/" + lib.escapeShellArg f) files} > "$out"
  ''));
  cache = pkgs.linkFarm "meson-packagecache" (lib.mapAttrsToList (name: archive: {
    inherit name; path = pkgs.fetchurl { inherit name; inherit (archive) urls sha256; };
  }) plan.archives);
in
assert lib.assertMsg (files != []) "drvcpp requires subprojects/*.wrap archive locks";
pkgs.stdenv.mkDerivation {
  name = "drvcpp-meson";
  inherit src buildInputs doCheck;
  nativeBuildInputs = [ pkgs.meson pkgs.ninja pkgs.pkg-config ] ++ nativeBuildInputs;
  inherit mesonFlags;
  mesonWrapMode = "nodownload";
  postPatch = ''
    rm -rf -- subprojects/packagecache ${lib.escapeShellArgs (map (d: "subprojects/" + d) plan.directories)}
    mkdir -p subprojects/packagecache
    cp -a ${cache}/. subprojects/packagecache/
  '';
}
