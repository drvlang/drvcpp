pkgs:
let
  python = pkgs.python3;
  script = ./drvcpp.py;
in builtins.derivation {
  name = "drvcpp-plan";
  system = pkgs.stdenv.hostPlatform.system;
  builder = "${python}/bin/python3";
  args = [ "-S" "-c" ''
    import os
    out = os.environ["out"]
    bin_dir = os.path.join(out, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    wrapper = os.path.join(bin_dir, "drvcpp-plan")
    with open(wrapper, "w", encoding="utf-8") as f:
        f.write("#!${python}/bin/python3 -S\n")
        f.write("import os, sys\n")
        f.write('os.execv("${python}/bin/python3", ["${python}/bin/python3", "-S", "${script}", "wrap-json", *sys.argv[1:]])\n')
    os.chmod(wrapper, 0o755)
  '' ];
  __contentAddressed = true;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
}
