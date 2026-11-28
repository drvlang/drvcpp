#!/usr/bin/env python3
"""Self-contained Python stdlib Nix daemon ATerm planner and Meson helper for drvcpp/drvc."""

import configparser
import glob
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import socket
import struct
import sys

# --- Nix store paths, ATerm formatting, and protocol-1.21 daemon client ---

NIX_B32 = "0123456789abcdfghijklmnpqrsvwxyz"
CLIENT_MAGIC = 0x6E697863
SERVER_MAGIC = 0x6478696F
PROTOCOL_1_21 = (1 << 8) | 21
STDERR_NEXT = 0x6F6C6D67
STDERR_LAST = 0x616C7473
STDERR_ERROR = 0x63787470
WOP_ADD_TEXT_TO_STORE = 8
WOP_QUERY_VALID_PATHS = 31


def store_dir() -> str:
    d = os.environ.get("NIX_STORE", "/nix/store")
    if d.startswith("/"):
        return d.rstrip("/") or "/"
    return "/nix/store"


def nix_base32(data: bytes) -> str:
    out_len = (len(data) * 8 - 1) // 5 + 1
    out = []
    for n in range(out_len):
        b = (out_len - 1 - n) * 5
        i = b // 8
        j = b % 8
        c = data[i] >> j
        if j > 0 and i + 1 < len(data):
            c |= data[i + 1] << (8 - j)
        out.append(NIX_B32[c & 0x1F])
    return "".join(out)


def compress_hash(digest: bytes, size: int) -> bytes:
    out = bytearray(size)
    for i, b in enumerate(digest):
        out[i % size] ^= b
    return bytes(out)


def make_store_path(sdir: str, typ: str, sha256_hex: str, name: str) -> str:
    fp = f"{typ}:sha256:{sha256_hex}:{sdir}:{name}".encode()
    h = nix_base32(compress_hash(hashlib.sha256(fp).digest(), 20))
    return f"{sdir}/{h}-{name}"


def make_text_path(sdir: str, name: str, text: bytes, refs: list[str]) -> str:
    digest = hashlib.sha256(text).hexdigest()
    typ = "text" + "".join(f":{r}" for r in sorted(set(refs)))
    return make_store_path(sdir, typ, digest, name)


def make_fixed_output_path(sdir: str, name: str, sha256_hex: str) -> str:
    inner = hashlib.sha256(f"fixed:out:sha256:{sha256_hex}:".encode()).hexdigest()
    return make_store_path(sdir, "output:out", inner, name)


def hash_placeholder(output_name: str) -> str:
    return "/" + nix_base32(hashlib.sha256(f"nix-output:{output_name}".encode()).digest())


def downstream_placeholder(drv_path: str, output_name: str) -> str:
    base = os.path.basename(drv_path)
    hash_part = base[:32]
    drv_name = base[33:].removesuffix(".drv")
    out_name = drv_name if output_name == "out" else f"{drv_name}-{output_name}"
    digest = hashlib.sha256(f"nix-upstream-output:{hash_part}:{out_name}".encode()).digest()
    return "/" + nix_base32(digest)


def aterm_str(s: str) -> str:
    return (
        '"'
        + s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
        + '"'
    )


def format_derivation(
    outputs: list[tuple[str, str, str, str]],
    input_drvs: dict[str, list[str]],
    input_srcs: set[str],
    platform: str,
    builder: str,
    args: list[str],
    env: dict[str, str],
) -> bytes:
    outs = ",".join(
        f"({aterm_str(n)},{aterm_str(p)},{aterm_str(a)},{aterm_str(h)})"
        for n, p, a, h in sorted(outputs, key=lambda x: x[0])
    )
    idrvs = ",".join(
        f"({aterm_str(d)},[{','.join(aterm_str(o) for o in sorted(set(os_)))}])"
        for d, os_ in sorted(input_drvs.items())
    )
    isrcs = ",".join(aterm_str(s) for s in sorted(input_srcs))
    a_str = ",".join(aterm_str(a) for a in args)
    e_str = ",".join(f"({aterm_str(k)},{aterm_str(v)})" for k, v in sorted(env.items()))
    return (
        f"Derive([{outs}],[{idrvs}],[{isrcs}],"
        f"{aterm_str(platform)},{aterm_str(builder)},[{a_str}],[{e_str}])"
    ).encode()


def make_fetchurl_drv(sdir: str, name: str, urls: list[str], sha256_hex: str):
    out_path = make_fixed_output_path(sdir, name, sha256_hex)
    primary = urls[0]
    env = {
        "builder": "builtin:fetchurl",
        "executable": "",
        "impureEnvVars": "http_proxy https_proxy ftp_proxy all_proxy no_proxy",
        "name": name,
        "out": out_path,
        "outputHash": sha256_hex,
        "outputHashAlgo": "sha256",
        "outputHashMode": "flat",
        "preferLocalBuild": "1",
        "system": "builtin",
        "unpack": "",
        "url": primary,
        "urls": " ".join(urls),
    }
    aterm = format_derivation(
        [("out", out_path, "sha256", sha256_hex)],
        {},
        set(),
        "builtin",
        "builtin:fetchurl",
        [],
        env,
    )
    drv_name = f"{name}.drv"
    drv_path = make_text_path(sdir, drv_name, aterm, [])
    return drv_path, out_path, drv_name, aterm, []


def make_ca_drv(
    sdir: str,
    name: str,
    system: str,
    builder: str,
    args: list[str],
    input_drvs: dict[str, list[str]],
    input_srcs: set[str],
    env: dict[str, str],
):
    ph = hash_placeholder("out")
    full_env = dict(env)
    full_env.update(
        {
            "builder": builder,
            "name": name,
            "out": ph,
            "outputHashAlgo": "sha256",
            "outputHashMode": "recursive",
            "system": system,
        }
    )
    aterm = format_derivation(
        [("out", "", "r:sha256", "")],
        input_drvs,
        input_srcs,
        system,
        builder,
        args,
        full_env,
    )
    refs = sorted(set(input_drvs.keys()) | set(input_srcs))
    drv_name = f"{name}.drv"
    drv_path = make_text_path(sdir, drv_name, aterm, refs)
    return drv_path, drv_name, aterm, refs


class DaemonClient:
    def __init__(self, remote: str):
        if remote.startswith("unix://"):
            sock_path = remote[len("unix://") :].split("?", 1)[0]
        elif remote == "daemon":
            sock_path = "/nix/var/nix/daemon-socket/socket"
        else:
            raise RuntimeError(f"unsupported NIX_REMOTE={remote!r}")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(sock_path)
        self.buf = bytearray()
        self._handshake()

    def close(self):
        self.sock.close()

    def _send_u64(self, v: int):
        self.buf.extend(struct.pack("<Q", v))

    def _send_bytes(self, b: bytes):
        self._send_u64(len(b))
        self.buf.extend(b)
        pad = (8 - (len(b) % 8)) % 8
        if pad:
            self.buf.extend(b"\x00" * pad)

    def _send_str(self, s: str):
        self._send_bytes(s.encode())

    def _send_str_set(self, items: list[str]):
        self._send_u64(len(items))
        for s in items:
            self._send_str(s)

    def _flush(self):
        if self.buf:
            self.sock.sendall(self.buf)
            self.buf.clear()

    def _recv_exact(self, n: int) -> bytes:
        chunks = []
        rem = n
        while rem > 0:
            chunk = self.sock.recv(rem)
            if not chunk:
                raise RuntimeError("unexpected EOF from nix daemon")
            chunks.append(chunk)
            rem -= len(chunk)
        return b"".join(chunks)

    def _recv_u64(self) -> int:
        return struct.unpack("<Q", self._recv_exact(8))[0]

    def _recv_bytes(self) -> bytes:
        n = self._recv_u64()
        data = self._recv_exact(n)
        pad = (8 - (n % 8)) % 8
        if pad:
            self._recv_exact(pad)
        return data

    def _recv_str(self) -> str:
        return self._recv_bytes().decode()

    def _recv_str_set(self) -> list[str]:
        n = self._recv_u64()
        return [self._recv_str() for _ in range(n)]

    def _drain_stderr(self):
        while True:
            code = self._recv_u64()
            if code == STDERR_LAST:
                return
            if code == STDERR_NEXT:
                self._recv_bytes()
            elif code == STDERR_ERROR:
                msg = self._recv_str()
                self._recv_u64()
                raise RuntimeError(f"nix daemon error: {msg}")
            else:
                raise RuntimeError(f"unexpected nix daemon stderr code {code:#x}")

    def _handshake(self):
        self._send_u64(CLIENT_MAGIC)
        self._flush()
        magic = self._recv_u64()
        if magic != SERVER_MAGIC:
            raise RuntimeError(f"unexpected nix daemon magic {magic:#x}")
        self._recv_u64()  # server version
        self._send_u64(PROTOCOL_1_21)
        self._send_u64(0)  # cpuAffinity
        self._send_u64(0)  # reserveSpace
        self._flush()
        self._drain_stderr()

    def query_valid_paths(self, paths: list[str]) -> set[str]:
        if not paths:
            return set()
        self._send_u64(WOP_QUERY_VALID_PATHS)
        self._send_str_set(paths)
        self._flush()
        self._drain_stderr()
        return set(self._recv_str_set())

    def add_text_to_store(self, name: str, text: bytes, refs: list[str]) -> str:
        self._send_u64(WOP_ADD_TEXT_TO_STORE)
        self._send_str(name)
        self._send_bytes(text)
        self._send_str_set(refs)
        self._flush()
        self._drain_stderr()
        return self._recv_str()


def register_nodes(remote: str, nodes: list[tuple[str, str, bytes, list[str]]]):
    if not nodes:
        return
    unique = []
    seen = set()
    for node in nodes:
        if node[0] not in seen:
            seen.add(node[0])
            unique.append(node)
    client = DaemonClient(remote)
    try:
        valid = client.query_valid_paths([p for p, _, _, _ in unique])
        for path, name, content, refs in unique:
            if path in valid:
                continue
            got = client.add_text_to_store(name, content, refs)
            if got != path:
                raise RuntimeError(f"daemon returned {got}, expected {path}")
            valid.add(path)
    finally:
        client.close()


# --- Meson wrap parser (parity with drvcpp-plan) ---


def valid_basename(value: str) -> bool:
    if not value or value.startswith("."):
        return False
    return all(c.isalnum() or c in "._+-" for c in value)


def parse_wrap_files(paths: list[str]) -> dict:
    directories: set[str] = set()
    archives: dict[str, dict] = {}
    for file_path in sorted(paths):
        parser = configparser.RawConfigParser(interpolation=None, strict=False, comment_prefixes=("#", ";"))
        with open(file_path, "r", encoding="utf-8") as f:
            parser.read_file(f)
        if not parser.has_section("wrap-file"):
            raise RuntimeError(f"{file_path}: expected a [wrap-file] archive lock")
        wrap = parser["wrap-file"]
        directory = wrap.get("directory")
        if directory is None:
            directory = pathlib.Path(file_path).stem
        else:
            directory = directory.strip()
        if (
            not valid_basename(directory)
            or directory in ("packagefiles", "packagecache")
            or directory in directories
        ):
            raise RuntimeError(f"{file_path}: invalid or repeated subproject directory: {directory}")
        directories.add(directory)
        for kind in ("source", "patch"):
            get = lambda field: wrap.get(f"{kind}_{field}", None)
            if kind == "patch" and all(get(k) is None for k in ("filename", "url", "hash", "fallback_url")):
                continue
            filename = get("filename")
            if filename is not None:
                filename = filename.strip()
            if not filename or not valid_basename(filename):
                raise RuntimeError(f"{file_path}: missing or unsafe archive filename")
            h = get("hash")
            if h is not None:
                h = h.strip()
            if not h or len(h) != 64 or not all(c in "0123456789abcdefABCDEF" for c in h):
                raise RuntimeError(f"{file_path}: expected archive SHA-256")
            url = get("url")
            if url is None:
                raise RuntimeError(f"{file_path}: missing archive URL")
            urls = [url.strip()]
            fallback = get("fallback_url")
            if fallback is not None:
                urls.append(fallback.strip())
            if not all(u.startswith("https://") and "@" not in u for u in urls):
                raise RuntimeError(f"{file_path}: expected public HTTPS archive URLs")
            h_lower = h.lower()
            entry = {"sha256": h_lower, "urls": urls}
            if filename in archives and archives[filename]["sha256"] != h_lower:
                raise RuntimeError(f"{file_path}: conflicting hashes for {filename}")
            archives[filename] = entry
    return {
        "directories": sorted(directories),
        "archives": dict(sorted(archives.items())),
    }


def scan_wrap_dir(root_dir: str) -> dict:
    wrap_files = sorted(glob.glob(os.path.join(root_dir, "subprojects", "*.wrap")))
    return parse_wrap_files(wrap_files)


# --- Direct ATerm Meson build planner ---


def add_input_drv(input_drvs: dict[str, list[str]], drv: str, out_name: str = "out"):
    outs = input_drvs.setdefault(drv, [])
    if out_name not in outs:
        outs.append(out_name)


def add_drv_ref(input_drvs: dict[str, list[str]], ref: dict):
    add_input_drv(input_drvs, ref["drv"], ref.get("outName", "out"))


def topo_sort_components(components: dict) -> list[str]:
    names = sorted(components.keys())
    for name, spec in components.items():
        for dep in spec.get("dependsOn", []):
            if dep not in components:
                raise RuntimeError(f"separateSubprojects: unknown dependency of {name}")
    # Kahn / DFS cycle detection
    state: dict[str, int] = {}  # 0=unvisited, 1=visiting, 2=done
    order: list[str] = []
    stack: list[str] = []

    def visit(n: str):
        st = state.get(n, 0)
        if st == 2:
            return
        if st == 1:
            idx = stack.index(n)
            cycle = ", ".join(stack[idx:])
            raise RuntimeError(f"separateSubprojects: dependency cycle involving {cycle}")
        state[n] = 1
        stack.append(n)
        for dep in components[n].get("dependsOn", []):
            visit(dep)
        stack.pop()
        state[n] = 2
        order.append(n)

    for n in names:
        visit(n)
    return order


def transitive_deps(components: dict, name: str) -> list[str]:
    seen = set()
    out = []

    def visit(n: str):
        for dep in components[n].get("dependsOn", []):
            if dep not in seen:
                seen.add(dep)
                visit(dep)
                out.append(dep)

    visit(name)
    return out


def make_slice_drv(sdir: str, system: str, python: str, script: str, src: str, rel: str, name: str):
    return make_ca_drv(
        sdir=sdir,
        name=name,
        system=system,
        builder=f"{python}/bin/python3",
        args=["-S", script, "slice", src, rel],
        input_drvs={},
        input_srcs={python, script, src},
        env={},
    )


def build_meson_drv(
    sdir: str,
    system: str,
    python: str,
    script: str,
    tc: dict,
    darwin_fixup: str | None,
    nodes: list,
    *,
    drv_name: str,
    builder_name: str,
    src_path: str,
    src_drv: str | None,
    member_path: str,
    select_member: bool,
    plan: dict,
    meson_flags: list[str],
    native_paths: list[str],
    build_paths: list[str],
    extra_build_drvs: list[str],
    do_check: bool,
    test_suite: str | None,
    test_args: list[str],
    external_subprojects: list[str],
):
    input_drvs: dict[str, list[str]] = {}
    input_srcs: set[str] = {
        python,
        script,
        tc["stdenv"],
        tc["bash"],
        tc["meson"],
        tc["ninja"],
        tc["pkgConfig"],
    }
    if darwin_fixup:
        input_srcs.add(darwin_fixup)

    if src_drv is not None:
        add_input_drv(input_drvs, src_drv, "out")
    else:
        input_srcs.add(src_path)

    for p in native_paths:
        input_srcs.add(p)
    for p in build_paths:
        input_srcs.add(p)
    for dep_drv in extra_build_drvs:
        add_input_drv(input_drvs, dep_drv, "out")

    archive_paths: dict[str, str] = {}
    for fname, arch in plan["archives"].items():
        f_drv, f_out, f_name, f_aterm, f_refs = make_fetchurl_drv(sdir, fname, arch["urls"], arch["sha256"])
        nodes.append((f_drv, f_name, f_aterm, f_refs))
        add_input_drv(input_drvs, f_drv, "out")
        archive_paths[fname] = f_out

    all_native = [tc["meson"], tc["ninja"], tc["pkgConfig"]] + list(native_paths)
    all_build = [downstream_placeholder(d, "out") for d in extra_build_drvs] + list(build_paths)

    bash_bin = f"{tc['bash']}/bin/bash"
    py_bin = f"{python}/bin/python3"

    lines = [
        f"export stdenv={shlex.quote(tc['stdenv'])}",
        'export NIX_BUILD_TOP="$TMPDIR"',
        f"export src={shlex.quote(src_path)}",
        f"export nativeBuildInputs={shlex.quote(' '.join(all_native))}",
        f"export buildInputs={shlex.quote(' '.join(all_build))}",
        "export strictDeps=",
        f"export doCheck={'1' if do_check else ''}",
        "export mesonWrapMode=nodownload",
        "export enableParallelBuilding=1",
        "export enableParallelChecking=1",
        "export enableParallelInstalling=1",
    ]
    if meson_flags:
        lines.append("mesonFlagsArray=(" + " ".join(shlex.quote(f) for f in meson_flags) + ")")
    check_flags = []
    if test_suite is not None:
        check_flags.extend(["--suite", test_suite])
    if test_args:
        check_flags.extend(test_args)
    if check_flags:
        lines.append("mesonCheckFlagsArray=(" + " ".join(shlex.quote(f) for f in check_flags) + ")")

    if plan["directories"]:
        rm_targets = " ".join(shlex.quote("subprojects/" + d) for d in plan["directories"])
        cp_cmds = "\n".join(
            f"cp -a {shlex.quote(p)} subprojects/packagecache/{shlex.quote(fname)}"
            for fname, p in sorted(archive_paths.items())
        )
        post_patch = f"rm -rf -- subprojects/packagecache {rm_targets}\nmkdir -p subprojects/packagecache\n{cp_cmds}"
        lines.append(f"postPatch={shlex.quote(post_patch)}")

    post_configure_parts = []
    if external_subprojects:
        ext_json = json.dumps(external_subprojects)
        post_configure_parts.append(
            f"{shlex.quote(py_bin)} -S {shlex.quote(script)} check-external {shlex.quote(ext_json)}"
        )
    if select_member:
        post_configure_parts.append(
            f"memberDir=$(realpath -- '../'\"${{MEMBER_PATH}}\")\n"
            f"{shlex.quote(py_bin)} -S {shlex.quote(script)} introspect-member "
            f'"$memberDir" {shlex.quote(os.path.basename(member_path))} '
            f"{'1' if (test_suite is None and not test_args and do_check) else '0'} "
            '"$TMPDIR/member-program" "$TMPDIR/member-tests"\n'
            'if [[ -s "$TMPDIR/member-tests" ]]; then\n'
            '  mapfile -t mesonCheckFlagsArray < "$TMPDIR/member-tests"\n'
            "fi"
        )
    if post_configure_parts:
        lines.append(f"postConfigure={shlex.quote(chr(10).join(post_configure_parts))}")

    if select_member:
        post_install = (
            'mkdir -p "$out/nix-support"\n'
            f'cat "$TMPDIR/member-program" > "$out/nix-support/{builder_name}-program"'
        )
        lines.append(f"postInstall={shlex.quote(post_install)}")

    if darwin_fixup:
        lines.append(f"postFixup={shlex.quote('source ' + darwin_fixup)}")

    lines.append('source "$stdenv/setup"')
    lines.append("genericBuild")
    build_cmd = "\n".join(lines) + "\n"

    env = {"BUILD_CMD": build_cmd}
    if select_member:
        env["MEMBER_PATH"] = member_path

    return make_ca_drv(
        sdir=sdir,
        name=drv_name,
        system=system,
        builder=bash_bin,
        args=["-e", "-c", 'eval "$BUILD_CMD"'],
        input_drvs=input_drvs,
        input_srcs=input_srcs,
        env=env,
    )


def cmd_plan():
    sdir = store_dir()
    cfg = json.loads(os.environ["CONFIG_JSON"])
    src = cfg["src"]
    member_path = cfg["memberPath"]
    builder_name = cfg["builderName"]
    system = cfg["system"]
    python = cfg["python"]
    script = cfg["script"]
    tc = cfg["toolchain"]
    darwin_fixup = cfg["darwinFixup"]
    meson_flags = cfg["mesonFlags"]
    native_refs = cfg["nativeBuildInputs"]
    build_refs = cfg["buildInputs"]
    do_check = cfg["doCheck"]
    test_suite = cfg["testSuite"]
    test_args = cfg["testArgs"]
    separate = cfg["separateSubprojects"]
    component_src = cfg["componentSrc"]

    workspace = os.path.isfile(os.path.join(src, "meson.build"))
    root = src if workspace else os.path.join(src, member_path)
    if not os.path.isfile(os.path.join(root, "meson.build")):
        raise RuntimeError(f"{builder_name}: missing meson.build in {root}")

    main_plan = scan_wrap_dir(root)
    nodes: list[tuple[str, str, bytes, list[str]]] = []

    component_drvs: dict[str, str] = {}
    comp_names = sorted(separate.keys())
    if comp_names:
        order = topo_sort_components(separate)
        comp_root = component_src if component_src is not None else root
        for cname in order:
            cdir = os.path.join(comp_root, "subprojects", cname)
            if not os.path.isfile(os.path.join(cdir, "meson.build")):
                raise RuntimeError(f"separateSubprojects: expected a local Meson project in subprojects/{cname}")
            cplan = scan_wrap_dir(cdir)
            spec = separate[cname]
            c_rel = os.path.relpath(cdir, component_src if component_src is not None else src)
            slice_base = component_src if component_src is not None else src
            s_drv, s_name, s_aterm, s_refs = make_slice_drv(
                sdir, system, python, script, slice_base, c_rel, "source"
            )
            nodes.append((s_drv, s_name, s_aterm, s_refs))
            deps = transitive_deps(separate, cname)
            c_drv, c_name, c_aterm, c_refs = build_meson_drv(
                sdir,
                system,
                python,
                script,
                tc,
                darwin_fixup,
                nodes,
                drv_name=f"{builder_name}-{cname}-meson",
                builder_name=f"{builder_name}-{cname}",
                src_path=downstream_placeholder(s_drv, "out"),
                src_drv=s_drv,
                member_path=".",
                select_member=False,
                plan=cplan,
                meson_flags=spec.get("mesonFlags", []),
                native_paths=native_refs,
                build_paths=build_refs,
                extra_build_drvs=[component_drvs[d] for d in deps],
                do_check=do_check,
                test_suite=None,
                test_args=[],
                external_subprojects=deps,
            )
            nodes.append((c_drv, c_name, c_aterm, c_refs))
            component_drvs[cname] = c_drv

    if workspace:
        main_src_path = src
        main_src_drv = None
    else:
        s_drv, s_name, s_aterm, s_refs = make_slice_drv(
            sdir, system, python, script, src, member_path, "project-source"
        )
        nodes.append((s_drv, s_name, s_aterm, s_refs))
        main_src_path = downstream_placeholder(s_drv, "out")
        main_src_drv = s_drv

    _, _, main_aterm, _ = build_meson_drv(
        sdir,
        system,
        python,
        script,
        tc,
        darwin_fixup,
        nodes,
        drv_name=f"{builder_name}-meson",
        builder_name=builder_name,
        src_path=main_src_path,
        src_drv=main_src_drv,
        member_path=member_path,
        select_member=(workspace and member_path != "."),
        plan=main_plan,
        meson_flags=meson_flags,
        native_paths=native_refs,
        build_paths=build_refs,
        extra_build_drvs=[component_drvs[n] for n in comp_names],
        do_check=do_check,
        test_suite=test_suite,
        test_args=test_args,
        external_subprojects=comp_names,
    )

    register_nodes(os.environ["NIX_REMOTE"], nodes)
    with open(os.environ["out"], "wb") as f:
        f.write(main_aterm)


def cmd_slice(src: str, rel: str):
    out = os.environ["out"]
    target = os.path.join(src, rel)
    shutil.copytree(target, out, symlinks=True)


def cmd_check_external(ext_json: str):
    external = set(json.loads(ext_json))
    with open("meson-info/intro-projectinfo.json", "r", encoding="utf-8") as f:
        info = json.load(f)
    embedded = [sp["name"] for sp in info.get("subprojects", []) if sp.get("name") in external]
    if embedded:
        names = "\n".join(embedded)
        sys.stderr.write(
            f"Meson configured these separateSubprojects again: {names}. "
            "Use dependency() to consume their installed libraries.\n"
        )
        sys.exit(1)


def cmd_introspect_member(member_dir: str, suite_name: str, select_tests: str, prog_out: str, tests_out: str):
    with open("meson-info/intro-targets.json", "r", encoding="utf-8") as f:
        targets = json.load(f)
    meson_file = os.path.join(member_dir, "meson.build")
    exes = []
    for t in targets:
        if t.get("defined_in") == meson_file and t.get("type") == "executable" and t.get("installed"):
            exes.extend(t.get("install_filename") or [])
    if len(exes) != 1:
        raise RuntimeError(f"expected one installed executable defined in {meson_file}")
    with open(prog_out, "w", encoding="utf-8") as f:
        f.write(exes[0] + "\n")

    if select_tests == "1":
        prefix = member_dir.rstrip("/") + "/"
        ids = {t["id"] for t in targets if (t.get("defined_in") or "").startswith(prefix)}
        suite_suffix = ":" + suite_name
        with open("meson-info/intro-tests.json", "r", encoding="utf-8") as f:
            tests = json.load(f)
        selected = []
        for test in tests:
            deps = test.get("depends") or []
            suites = test.get("suite") or []
            if any(d in ids for d in deps) or any(s.endswith(suite_suffix) for s in suites):
                selected.append(test["name"])
        with open(tests_out, "w", encoding="utf-8") as f:
            for name in selected:
                f.write(name + "\n")


def cmd_forward():
    os.symlink(os.environ["TARGET"], os.environ["out"])


def cmd_member():
    target = os.environ["TARGET"]
    builder_name = os.environ["BUILDER_NAME"]
    out = os.environ["out"]
    marker = os.path.join(target, "nix-support", f"{builder_name}-program")
    if os.path.isfile(marker):
        with open(marker, "r", encoding="utf-8") as f:
            program = f.readline().rstrip("\r\n")
        if not (os.path.isfile(program) and os.access(program, os.X_OK)):
            raise RuntimeError(f"expected executable member program: {program}")
        bin_dir = os.path.join(out, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        os.symlink(program, os.path.join(bin_dir, os.path.basename(program)))
    else:
        os.symlink(target, out)


def cmd_wrap_json(files: list[str]):
    plan = parse_wrap_files(files)
    json.dump(plan, sys.stdout, separators=(",", ":"))


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: drvcpp.py <plan|slice|check-external|introspect-member|forward|member|wrap-json>\n")
        sys.exit(2)
    cmd = sys.argv[1]
    try:
        if cmd == "plan":
            cmd_plan()
        elif cmd == "slice":
            cmd_slice(sys.argv[2], sys.argv[3])
        elif cmd == "check-external":
            cmd_check_external(sys.argv[2])
        elif cmd == "introspect-member":
            cmd_introspect_member(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
        elif cmd == "forward":
            cmd_forward()
        elif cmd == "member":
            cmd_member()
        elif cmd == "wrap-json":
            cmd_wrap_json(sys.argv[2:])
        else:
            raise RuntimeError(f"unknown drvcpp command: {cmd}")
    except Exception as e:
        sys.stderr.write(f"{e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
