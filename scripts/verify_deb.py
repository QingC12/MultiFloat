#!/usr/bin/env python3
"""校验 MultiFloat DEB 是否符合目标环境约定（roothide / arm64e / 有效签名）。

用法：
    python3 scripts/verify_deb.py packages/*.deb Probe/packages/*.deb

校验项（任一不符即退出码非 0，阻断 CI）：
    1. control 的 Architecture 必须为 iphoneos-arm64e
    2. data.tar 布局必须是 roothide/rootful 风格：
       Library/MobileSubstrate/DynamicLibraries/...（不得出现 var/jb/）
       —— v0.1.x 是 rootless(/var/jb) + iphoneos-arm64，装在 roothide 设备上
          疑似因此进安全模式，故在此拦住
    3. dylib 所有切片必须都是 arm64e
    4. dylib 必须有 LC_CODE_SIGNATURE，且签名要**真正覆盖**二进制：
       把 CodeDirectory 的页哈希集合与按 codeLimit 计算出的实际页哈希集合做
       全量比对（不等即说明是占位/损坏签名）

注意（勿误判）：
    - identifier 形如 "Foo.dylib.<md5>.unsigned" 是 Theos 构建中间产物的文件名
      （rules.mk 先产出 <name>.<tag>.unsigned 再签名改名），**不代表签名无效**；
      同理 ldid 产出的 CodeDirectory flags 为 0x0 也属正常，不要据此报错。
"""
import gzip
import hashlib
import io
import lzma
import struct
import sys
import tarfile

EXPECTED_ARCH = "iphoneos-arm64e"
EXPECTED_PREFIX = "Library/MobileSubstrate/DynamicLibraries/"
CS_MAGIC = 0xFADE0CC0
CD_MAGIC = 0xFADE0C02
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
HASH_FUNCS = {1: ("SHA1", hashlib.sha1), 2: ("SHA256", hashlib.sha256),
              3: ("SHA256-trunc", hashlib.sha256), 4: ("SHA384", hashlib.sha384),
              5: ("SHA512", hashlib.sha512)}


def die(msg):
    print("  [FAIL] " + msg)
    sys.exit(1)


def decompress(blob):
    for fn in (lzma.decompress, gzip.decompress):
        try:
            return fn(blob)
        except Exception:
            pass
    return blob


def ar_members(raw):
    if raw[:8] != b"!<arch>\n":
        die("不是 ar 归档")
    off, members = 8, {}
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode("utf-8", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode().strip())
        except ValueError:
            break
        members[name] = raw[off + 60:off + 60 + size]
        off += 60 + size + (size % 2)
    return members


def read_control(members):
    for name, blob in members.items():
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(decompress(blob))) as tar:
                for m in tar.getmembers():
                    if m.name.rstrip("/").endswith("control"):
                        return tar.extractfile(m).read().decode("utf-8", "replace")
    die("找不到 control 文件")


def read_data_files(members):
    for name, blob in members.items():
        if name.startswith("data.tar"):
            out = []
            with tarfile.open(fileobj=io.BytesIO(decompress(blob))) as tar:
                for m in tar.getmembers():
                    if m.isfile():
                        out.append((m.name, tar.extractfile(m).read()))
            return out
    die("找不到 data.tar")


def slices_of(dylib):
    if struct.unpack(">I", dylib[:4])[0] in (0xCAFEBABE, 0xBEBAFECA):
        n = struct.unpack(">I", dylib[4:8])[0]
        out = []
        for i in range(n):
            _, _, off, size = struct.unpack(">iiII", dylib[8 + i * 20:8 + i * 20 + 16])
            out.append((off, size))
        return out
    return [(0, len(dylib))]


def verify_signature(sl, label):
    """确认签名真正覆盖该切片（页哈希集合全量比对）。"""
    sizeofcmds = struct.unpack("<I", sl[20:24])[0]
    off, sig = 32, None
    while off < 32 + sizeofcmds:
        cmd, cmdsize = struct.unpack("<II", sl[off:off + 8])
        if cmd == 0x1D:
            sig = struct.unpack("<II", sl[off + 8:off + 16])
        if cmdsize < 8:
            break
        off += cmdsize
    if sig is None:
        die(f"{label}: 缺少 LC_CODE_SIGNATURE")
    dataoff, datasize = sig
    blob = sl[dataoff:dataoff + datasize]
    if struct.unpack(">I", blob[:4])[0] != CS_MAGIC:
        die(f"{label}: 签名 SuperBlob magic 非法")

    count = struct.unpack(">I", blob[8:12])[0]
    checked = 0
    for i in range(count):
        _, boff = struct.unpack(">II", blob[12 + i * 8:20 + i * 8])
        if struct.unpack(">I", blob[boff:boff + 4])[0] != CD_MAGIC:
            continue
        _, _, ver, flags, hash_off, ident_off, n_special, n_code, code_limit = \
            struct.unpack(">IIIIIIIII", blob[boff:boff + 36])
        hash_size, hash_type, _, page_log = struct.unpack(">BBBB", blob[boff + 36:boff + 40])
        if hash_type not in HASH_FUNCS:
            die(f"{label}: 未知 hashType={hash_type}")
        hname, hfn = HASH_FUNCS[hash_type]
        if code_limit != dataoff:
            die(f"{label}: codeLimit={code_limit} 与签名偏移 {dataoff} 不一致")
        page = 1 << page_log
        actual, idx = [], 0
        while idx * page < code_limit:
            actual.append(hfn(sl[idx * page:min((idx + 1) * page, code_limit)]).digest()[:hash_size])
            idx += 1
        slots = [blob[boff + hash_off + k * hash_size:boff + hash_off + (k + 1) * hash_size]
                 for k in range(n_code)]
        if len(actual) != n_code or sorted(actual) != sorted(slots):
            die(f"{label}: 签名未覆盖全部页面（{hname}，页={len(actual)} 槽={n_code}）")
        print(f"  [ok] {label}: 签名有效且覆盖完整（{hname}，{n_code} 页，ident@0x{ident_off:x}）")
        checked += 1
    if checked == 0:
        die(f"{label}: SuperBlob 内无 CodeDirectory")


def check_slice(dylib, base, size, label):
    sl = dylib[base:base + size]
    if struct.unpack("<I", sl[:4])[0] != 0xFEEDFACF:
        die(f"{label}: 不是 64 位 Mach-O")
    cputype, cpusubtype = struct.unpack("<ii", sl[4:12])
    sub = cpusubtype & 0xFFFFFFFF
    if cputype != CPU_TYPE_ARM64 or (sub & 0xFF) != CPU_SUBTYPE_ARM64E:
        die(f"{label}: 切片架构不是 arm64e (cputype=0x{cputype:x} cpusub={sub:#x})")
    verify_signature(sl, label)


def check_deb(path):
    print(f"\n== {path}")
    with open(path, "rb") as fh:
        raw = fh.read()

    control = read_control(ar_members(raw))
    fields = {}
    for line in control.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
    if str(fields.get("Architecture", "")) != EXPECTED_ARCH:
        die(f"control Architecture={fields.get('Architecture')!r}，期望 {EXPECTED_ARCH!r}")
    print(f"  [ok] control: {fields.get('Package')} {fields.get('Version')} "
          f"{fields.get('Architecture')}")

    dylibs = []
    for name, data in read_data_files(ar_members(raw)):
        norm = name.lstrip("./")
        if norm.startswith("var/jb/"):
            die(f"含 var/jb（rootless 布局），roothide 不允许: {norm}")
        if not norm.startswith(EXPECTED_PREFIX):
            die(f"文件不在 roothide 预期目录 {EXPECTED_PREFIX} 下: {norm}")
        if norm.endswith(".dylib"):
            dylibs.append((norm, data))
        else:
            print(f"  [ok] {norm} ({len(data)} B)")
    if not dylibs:
        die("deb 内没有 dylib")

    for norm, data in dylibs:
        for i, (off, size) in enumerate(slices_of(data)):
            check_slice(data, off, size, f"{norm} slice{i}")


def main():
    debs = sys.argv[1:]
    if not debs:
        die("未提供 deb 路径")
    for d in debs:
        check_deb(d)
    print("\n全部校验通过。")


if __name__ == "__main__":
    main()
