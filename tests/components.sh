#!/usr/bin/env bash
# Run from a drvcpp or drvc checkout to exercise the public CLI and consumer flake.
set -euo pipefail
builder=${1:-drvcpp}
tool=$(nix flake archive --json | jq -er .path)
cli=$(nix build --print-out-paths --no-link ".#$builder")/bin/$builder
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp -R "$(dirname "$0")/components/." "$scratch/"
chmod -R u+w "$scratch"
cd "$scratch"
if [[ $builder != drvcpp ]]; then
  jq --arg builder "$builder" '{($builder): .drvcpp}' drvlang.json > manifest
  mv manifest drvlang.json
fi
cat > flake.nix <<NIX
{
  inputs.builder.url = "path:$tool";
  outputs = { builder, ... }: builder.lib.mkFlake { root = ./.; };
}
NIX
export NIX_CONFIG="${NIX_CONFIG:-}
allow-import-from-derivation = false"
nix flake lock
package() { nix build --print-out-paths --no-link "path:$PWD"; }
library() { nix-store -qR "$1" | grep -E "/[0-9a-z]+-$builder-$2-meson$"; }
before=$(package)
[[ $("$cli" build -C . --no-link) == "$before" ]]
[[ $("$cli" run -C .) == 11 ]]
"$cli" test -C .
base=$(library "$before" base)
greeting=$(library "$before" greeting)
echo docs > notes.md
[[ $(package) == "$before" ]]
echo '/* client edit */' >> main.c
after=$(package)
[[ $before != "$after" && $(library "$after" base) == "$base" && $(library "$after" greeting) == "$greeting" ]]
sed 's/+ 1/+ 2/' subprojects/greeting/greeting.c > changed.c
mv changed.c subprojects/greeting/greeting.c
edited=$(package)
[[ $("$edited/bin/client") == 12 && $(library "$edited" base) == "$base" && $(library "$edited" greeting) != "$greeting" ]]
sed 's/return 10/return 20/' subprojects/base/base.c > changed.c
mv changed.c subprojects/base/base.c
edited_base=$(package)
[[ $("$edited_base/bin/client") == 22 && $(library "$edited_base" base) != "$base" && $(library "$edited_base" greeting) != "$(library "$edited" greeting)" ]]
if "$cli" test -C . --options '{"separateSubprojects":{"base":{"dependsOn":["greeting"]},"greeting":{"dependsOn":["base"]}}}' > failure.log 2>&1; then exit 1; fi
grep -q 'dependency cycle' failure.log
if "$cli" build -C . --no-link --options '{"mesonFlags":["--force-fallback-for=greeting"]}' > failure.log 2>&1; then exit 1; fi
grep -q 'configured these separateSubprojects again: greeting' failure.log

# Independent Meson projects share a checkout but no root meson.build.
cd "$scratch"
mkdir -p independent/{one,two}
cd independent
for member in one two; do
  cat > "$member/meson.build" <<'MESON'
project('command', 'c')
app = executable('command', 'main.c', install: true)
test('run command', app)
MESON
  echo 'int main(void) { return 0; }' > "$member/main.c"
done
echo '{"commands":{"one":"one","two":"two"}}' > drvlang.json
cat > flake.nix <<NIX
{
  inputs.builder.url = "path:$tool";
  outputs = { builder, ... }: builder.lib.mkMonorepoFlake {
    src = builder.lib.projectSource { root = ./.; files = [ ./one ./two ./drvlang.json ]; };
  };
}
NIX
nix flake lock
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
recipes() { nix eval --raw "path:$PWD#$1.$system.$2.drvPath"; }
one=$(recipes packages one)
check=$(recipes checks one)
two=$(recipes packages two)
cli_before=$("$cli" build -C . one --no-link)
echo '/* sibling edit */' >> two/main.c
[[ $(recipes packages one) == "$one" && $(recipes checks one) == "$check" && $(recipes packages two) != "$two" ]]
[[ $("$cli" build -C . one --no-link) == "$cli_before" ]]
echo '/* selected edit */' >> one/main.c
[[ $(recipes packages one) != "$one" && $(recipes checks one) != "$check" ]]
"$cli" test -C . one
