# Meson installs dylibs with an absolute LC_ID_DYLIB. Signing that temporary
# output path makes the bytes depend on the recipe and rewriting it breaks
# the signature. Use dyld-relative paths before the final ad-hoc signature.
fixDarwinPaths() {
  local file command path relative dir id
  local -a flags
  local -A libraryDirs=()
  while IFS= read -r -d "" file; do
    flags=()
    while IFS=$'\t' read -r command path; do
      [[ "$path" == "$out/"* ]] || continue
      dir=$(dirname "$file")
      case "$command" in
        LC_ID_DYLIB)
          id=@rpath/$(basename "$path")
          flags+=(-id "$id")
          libraryDirs["$(dirname "$path")"]=1
          ;;
        LC_RPATH)
          relative=$(realpath -m --relative-to="$dir" "$path")
          flags+=(-rpath "$path" "@loader_path/$relative")
          ;;
        LC_*DYLIB)
          relative=$(realpath -m --relative-to="$dir" "$path")
          flags+=(-change "$path" "@loader_path/$relative")
          ;;
      esac
    done < <(otool -l "$file" 2>/dev/null | awk '
      $1 == "cmd" { command = $2 }
      $1 == "name" || ($1 == "path" && command == "LC_RPATH") {
        sub(/^[[:space:]]*(name|path) /, ""); sub(/ \(offset [0-9]+\)$/, "")
        print command "\t" $0
      }')
    if (( ${#flags[@]} )); then
      # The Nixpkgs wrapper signs the binary after updating all load commands.
      install_name_tool "${flags[@]}" "$file"
    fi
  done < <(find "$out" -type f \( -perm -0100 -o -name '*.dylib' -o -name '*.so' -o -name '*.bundle' \) -print0)

  # Publish search paths for linkers consuming these relocatable install names.
  if (( ${#libraryDirs[@]} )); then
    mkdir -p "$out/nix-support"
    while IFS= read -r -d "" dir; do
      printf 'export NIX_LDFLAGS+=%q\n' " -rpath $dir" >> "$out/nix-support/setup-hook"
    done < <(printf '%s\0' "${!libraryDirs[@]}" | sort -z)
    while IFS= read -r -d "" file; do
      sed -i '/^Libs:.*-L${libdir}/s/$/ -Wl,-rpath,${libdir}/' "$file"
    done < <(find "$out" -type f -name '*.pc' -print0)
  fi
}
fixDarwinPaths
