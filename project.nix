# Resolve project-local settings before drvkit filters sources and selects a target.
{ lib, projectSource, legacyPackages, name }:
args:
let
  src = args.src or args.root or null;
  manifest = src + "/drvlang.json";
  hasManifest = src != null && !lib.isDerivation src && builtins.pathExists manifest;
  manifestData = if hasManifest then builtins.fromJSON (builtins.readFile manifest) else {};
  config = manifestData.${name} or {};
  pkgs = legacyPackages.${args.system};
  packages = field: map (pkg: pkgs.${pkg} or (throw "${name}: unknown Nixpkgs package '${pkg}' in ${field}")) (config.${field} or []);
  rootPath = if builtins.isPath src then src else /. + builtins.unsafeDiscardStringContext (toString src);
  pathFor = file:
    if !builtins.isString file || lib.any (part: builtins.elem part [ "" "." ".." ]) (lib.splitString "/" file)
    then throw "${name}: expected a project-relative path in files, got ${builtins.toJSON file}"
    else rootPath + "/${file}";
  target = args.target or "";
  targetFiles = config.targetFiles or {};
  commands = args.commands or manifestData.commands or {};
  matchingTargets = lib.filterAttrs (name: path: name == target || path == target) commands;
  files = if !(config ? files) && targetFiles == {} then null else
    (config.files or []) ++ lib.concatLists (builtins.attrValues (
      if target == "" || target == null then targetFiles
      else builtins.intersectAttrs matchingTargets targetFiles));
  selectFiles = files != null && !(args ? srcForTarget) && !(src ? _isLibCleanSourceWith);
  separate = args.separateSubprojects or config.separateSubprojects or {};
  componentRoot = if builtins.pathExists (rootPath + "/meson.build") || target == "" || target == null || target == "."
    then rootPath else pathFor (commands.${target} or target);
  defaults = lib.optionalAttrs (manifestData ? commands) { inherit (manifestData) commands; }
    // builtins.intersectAttrs { program = null; separateSubprojects = null; } config;
in assert lib.assertMsg (!(args ? root && args ? src)) "${name}: supply either root or src";
   assert lib.assertMsg (!(args ? root) || files != null) "${name}: root requires ${name}.files in drvlang.json";
   assert lib.assertMsg (builtins.isAttrs config &&
     lib.subtractLists [ "files" "targetFiles" "libraries" "tools" "program" "separateSubprojects" ] (builtins.attrNames config) == [])
     "${name}: unknown field in the ${name} section of drvlang.json";
   defaults // removeAttrs args [ "root" ] // lib.optionalAttrs (src != null) {
     src = if selectFiles then projectSource { root = rootPath; files = map pathFor files; } else src;
   } // lib.optionalAttrs (selectFiles && separate != {}) {
     componentSrc = projectSource {
       root = componentRoot;
       files = map (n:
         assert lib.assertMsg (builtins.match "[a-zA-Z0-9][a-zA-Z0-9_+.-]*" n != null)
           "Expected a Meson subproject name, got ${builtins.toJSON n}";
         componentRoot + "/subprojects/${n}"
       ) (builtins.attrNames separate);
     };
   } // {
     buildInputs = packages "libraries" ++ (args.buildInputs or []);
     nativeBuildInputs = packages "tools" ++ (args.nativeBuildInputs or []);
   }
