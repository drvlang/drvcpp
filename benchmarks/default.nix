{ self, pkgs, system }:
let
  src = (import ./source.nix).outPath;
  codec = self.lib.mkPackage {
    inherit system src;
    nativeBuildInputs = pkgs.lib.optional pkgs.stdenv.hostPlatform.isx86 pkgs.nasm;
    mesonFlags = [ "-Dtests=enabled" ];
  };
in pkgs.runCommand "drvcpp-openh264-codec" {
  __contentAddressed = true;
  nativeBuildInputs = [ pkgs.stdenv.cc pkgs.pkg-config ];
  buildInputs = [ codec ];
} ''
  c++ ${./check.cpp} $(pkg-config --cflags --libs openh264) -o check
  ./check > "$out"
''
