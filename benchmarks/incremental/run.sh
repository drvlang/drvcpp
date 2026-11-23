#!/usr/bin/env bash
set -euo pipefail
mode=${1:-separate}
runs=${2:-3}
case "$mode" in separate|together) ;; *) echo "usage: $0 [separate|together] [runs]" >&2; exit 2 ;; esac
repo=$(cd "$(dirname "$0")/../.." && pwd)
tool=$(nix flake archive --json "$repo" | jq -er .path)
codec=$(cd "$repo" && nix eval --raw --impure --expr '(import ./benchmarks/source.nix).outPath')
timer=$(nix build --no-link --print-out-paths "$repo#bench")/bin/drvbench
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
mkdir -p subprojects
cp -R "$codec" subprojects/openh264
chmod -R u+w subprojects/openh264
cp "$repo/benchmarks/incremental/meson.build" .
sed '/std::cout << version/i\
    std::cout << "edit @EDIT@" << std::endl;
' "$repo/benchmarks/check.cpp" > check.cpp.in
cp check.cpp.in check.cpp
echo 0 > trial
if [[ $mode == separate ]]; then
  component='separateSubprojects.openh264.mesonFlags = [ "-Dtests=disabled" ];'
else
  component=""
fi
cat > flake.nix <<NIX
{
  inputs.builder.url = "path:$tool";
  outputs = { builder, ... }: let
    system = builtins.currentSystem;
    pkgs = builder.inputs.nixpkgs.legacyPackages.\${system};
  in { packages.\${system}.default = builder.lib.mkPackage {
    inherit system;
    src = builder.lib.projectSource { root = ./.; files = [ ./meson.build ./check.cpp ./subprojects ]; };
    nativeBuildInputs = pkgs.lib.optional pkgs.stdenv.hostPlatform.isx86 pkgs.nasm;
    $component
  }; };
}
NIX
nix flake lock
cat > trial.sh <<'SH'
set -euo pipefail
# Change an observable result. A unique marker also prevents a previous
# benchmark invocation from supplying an already-built application.
revision=$(( $(cat trial) + 1 ))
echo "$revision" > trial
marker="$(basename "$PWD")-$revision"
sed "s/@EDIT@/$marker/" check.cpp.in > check.cpp
result=$(nix build --impure --no-link --print-out-paths "path:$PWD")
output=$("$result/bin/codec-client")
grep -Fxq "edit $marker" <<< "$output"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$output"
SH
# drvbench warms once, then times fresh source edits with the dependencies warm.
"$timer" --runs "$runs" -- bash trial.sh
