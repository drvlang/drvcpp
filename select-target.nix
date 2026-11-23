lib:
{ src, target, ... }:
let
  # Generated sources can be inspected inside the planner, once realized.
  # Checking for meson.build in such a source here would require IFD.
  context = builtins.attrValues (builtins.getContext (toString src));
  generated = lib.isDerivation src || lib.any (dep: dep ? outputs || dep ? allOutputs) context;
  member = src + "/${target}";
in if target != "." && !generated && !(builtins.pathExists (src + "/meson.build"))
      && builtins.pathExists (member + "/meson.build") then {
  # An independent project's unpack phase only ever receives this directory.
  src = builtins.path { path = member; name = "project-source"; };
} else { inherit src; memberPath = target; }
