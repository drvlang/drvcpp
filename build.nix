pkgs: { src, memberPath, plan, mesonFlags, nativeBuildInputs, buildInputs, doCheck, test, testSuite, testArgs }:
let
  inherit (pkgs) lib;
  workspace = builtins.pathExists (src + "/meson.build");
  selectMember = workspace && memberPath != ".";
  cache = pkgs.linkFarm "meson-packagecache" (lib.mapAttrsToList (name: archive: {
    inherit name; path = pkgs.fetchurl { inherit name; inherit (archive) urls sha256; };
  }) plan.archives);
  package = pkgs.stdenv.mkDerivation {
    name = "drvcpp-meson";
    src = if workspace then src else src + "/${memberPath}";
    inherit buildInputs doCheck mesonFlags;
    nativeBuildInputs = [ pkgs.meson pkgs.ninja pkgs.pkg-config ] ++ nativeBuildInputs;
    mesonWrapMode = "nodownload";
    mesonCheckFlags = lib.optionals (testSuite != null) [ "--suite" testSuite ];
    preCheck = lib.optionalString (testArgs != []) ''mesonCheckFlagsArray+=(${lib.escapeShellArgs testArgs})'';
    postPatch = lib.optionalString (plan.directories != []) ''
      rm -rf -- subprojects/packagecache ${lib.escapeShellArgs (map (d: "subprojects/" + d) plan.directories)}
      mkdir -p subprojects/packagecache
      cp -a ${cache}/. subprojects/packagecache/
    '';
    postConfigure = lib.optionalString selectMember ''
      memberDir=$(realpath -- "../"${lib.escapeShellArg memberPath})
      meson introspect --targets . > "$TMPDIR/targets.json"
      ${pkgs.jq}/bin/jq -er --arg dir "$memberDir/meson.build" '
        [.[] | select(.defined_in == $dir and .type == "executable" and .installed) | .install_filename[]]
        | if length == 1 then .[0] else error("expected one installed executable defined in " + $dir) end
      ' "$TMPDIR/targets.json" > "$TMPDIR/drvcpp-program"
    '' + lib.optionalString (selectMember && testSuite == null && testArgs == [] && doCheck) ''
      meson introspect --tests . > "$TMPDIR/tests.json"
      ${pkgs.jq}/bin/jq -r --slurpfile targets "$TMPDIR/targets.json" \
        --arg dir "$memberDir/" --arg suite ":${baseNameOf memberPath}" '
        [$targets[0][] | select(.defined_in | startswith($dir)) | .id] as $ids
        | .[] | select(any(.depends[]; . as $id | $ids | index($id))
                     or any(.suite[]; endswith($suite))) | .name
      ' "$TMPDIR/tests.json" > "$TMPDIR/member-tests"
      if [[ -s "$TMPDIR/member-tests" ]]; then
        mapfile -t mesonCheckFlagsArray < "$TMPDIR/member-tests"
      fi
    '';
    postInstall = lib.optionalString (selectMember && !test) ''
      mkdir -p "$out/nix-support"
      cat "$TMPDIR/drvcpp-program" > "$out/nix-support/drvcpp-program"
    '';
  };
in if !selectMember || test then package else pkgs.runCommand "drvcpp-member" {} ''
  read -r program < ${package}/nix-support/drvcpp-program
  test -x "$program"
  mkdir -p "$out/bin"
  ln -s "$program" "$out/bin/"
''
