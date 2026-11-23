{ pkgs, darwinFixup ? null }:
{ src, memberPath, plan, mesonFlags, nativeBuildInputs, buildInputs, doCheck, test, testSuite,
        testArgs, builderName, externalSubprojects ? [] }:
let
  inherit (pkgs) lib;
  workspace = builtins.pathExists (src + "/meson.build");
  selectMember = workspace && memberPath != ".";
  cache = (pkgs.linkFarm "meson-packagecache" (lib.mapAttrsToList (name: archive: {
    inherit name; path = pkgs.fetchurl { inherit name; inherit (archive) urls sha256; };
  }) plan.archives)).overrideAttrs { __contentAddressed = true; };
  package = pkgs.stdenv.mkDerivation ({
    __contentAddressed = true;
    name = "${builderName}-meson";
    src = if workspace then src else builtins.path {
      path = src + "/${memberPath}"; name = "project-source";
    };
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
    postConfigure = lib.optionalString (externalSubprojects != []) ''
      embedded=$(${pkgs.jq}/bin/jq -r --argjson external ${lib.escapeShellArg (builtins.toJSON externalSubprojects)} '
        .subprojects[].name as $name | select($external | index($name)) | $name
      ' meson-info/intro-projectinfo.json)
      if [[ -n "$embedded" ]]; then
        echo "Meson configured these separateSubprojects again: $embedded. Use dependency() to consume their installed libraries." >&2
        exit 1
      fi
    '' + lib.optionalString selectMember ''
      memberDir=$(realpath -- "../"${lib.escapeShellArg memberPath})
      ${pkgs.jq}/bin/jq -er --arg dir "$memberDir/meson.build" '
        [.[] | select(.defined_in == $dir and .type == "executable" and .installed) | .install_filename[]]
        | if length == 1 then .[0] else error("expected one installed executable defined in " + $dir) end
      ' meson-info/intro-targets.json > "$TMPDIR/member-program"
    '' + lib.optionalString (selectMember && testSuite == null && testArgs == [] && doCheck) ''
      ${pkgs.jq}/bin/jq -r --slurpfile targets meson-info/intro-targets.json \
        --arg dir "$memberDir/" --arg suite ":${baseNameOf memberPath}" '
        [$targets[0][] | select(.defined_in | startswith($dir)) | .id] as $ids
        | .[] | select(any(.depends[]; . as $id | $ids | index($id))
                     or any(.suite[]; endswith($suite))) | .name
      ' meson-info/intro-tests.json > "$TMPDIR/member-tests"
      if [[ -s "$TMPDIR/member-tests" ]]; then
        mapfile -t mesonCheckFlagsArray < "$TMPDIR/member-tests"
      fi
    '';
    postInstall = lib.optionalString (selectMember && !test) ''
      mkdir -p "$out/nix-support"
      cat "$TMPDIR/member-program" > "$out/nix-support/${builderName}-program"
    '';
  } // lib.optionalAttrs (darwinFixup != null) {
    postFixup = "source ${darwinFixup}";
  });
in if !selectMember || test then package else pkgs.runCommand "${builderName}-member" { __contentAddressed = true; } ''
  read -r program < ${package}/nix-support/${builderName}-program
  test -x "$program"
  mkdir -p "$out/bin"
  ln -s "$program" "$out/bin/"
''
