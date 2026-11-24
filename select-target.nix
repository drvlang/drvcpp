reader: lib:
{ src, target, ... }:
let source = reader lib src;
in if target != "." && !source.generated && !(source.exists "meson.build")
      && source.exists "${target}/meson.build" then {
  src = source.subdirectory target;
} else { inherit src; memberPath = target; }
