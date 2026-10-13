#!/usr/bin/env python3
"""校验 MultiFloat DEB 是否符合目标环境约定（roothide / arm64e / 有效签名）。

用法：
    python3 scripts/verify_deb.py packages/*.deb Probe/packages/*.deb

校验项（任一不符即退出码非 0，阻断 CI）：
    1. control 的 Architecture 必须为 iphoneos-arm64e
    2. data.tar 布局必须是 roothide/rootful 风格：
       Library/MobileSubstrate/DynamicLibraries/...（不得出现 var/jb/）
    3. dylib 所有切片必须都是 arm64e
    4. dylib 必须有 LC_CODE_SIGNATURE，且 CodeDirectory：
         - flags 含 ad-hoc 位（0x2）
         - identifier 不含 ".unsigned"
       （v0.1.x 构建出来的就是 ident=.unsigned / flags=0 的占位签名，
         在 roothide 上会导致 SpringBoard 崩溃进安全模式，必须在此拦住）
"""
import gzip
import io
import lzma
import struct
import sys
import tarfile

EXPECTED_ARCH = "iphoneos-arm64e"
EXPECTED_PREFIX = "Library/MobileSubstrate/DynamicLibraries/"
CS_MAGIC = 0xFADE0CC0
CD_MAGIC = 0xFADE0C02
CS_ADHOC = 0x2
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2


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


def check_slice(dylib_bytes, base, size, label):
    sl = dylib_bytes[base:base + size]
    if struct.unpack("<I", sl[:4])[0] != 0xFEEDFACF:
        die(f"{label}: 不是 64 位 Mach-O")
    cputype, cpusubtype = struct.unpack("<ii", sl[4:12])
    sub = cpusubtype & 0xFFFFFFFF
    if cputype != CPU_TYPE_ARM64 or (sub & 0xFF) != CPU_SUBTYPE_ARM64E:
        die(f"{label}: 切片架构不是 arm64e (cputype=0x{cputype:x} cpusub={sub:#x})")

    ncmds = struct.unpack("<I", sl[16:20])[0]
    off, sig = 32, None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", sl[off:off + 8])
        if cmd == 0x1D:
            sig = struct.unpack("<II", sl[off + 8:off + 16])
        off += cmdsize
    if sig is None:
        die(f"{label}: 缺少 LC_CODE_SIGNATURE（未签名）")
    dataoff, datasize = sig
    blob = sl[dataoff:dataoff + datasize]
    if struct.unpack(">I", blob[:4])[0] != CS_MAGIC:
        die(f"{label}: 签名 SuperBlob magic 非法")
    count = struct.unpack(">I", blob[8:12])[0]
    found = False
    for i in range(count):
        _, boff = struct.unpack(">II", blob[12 + i * 8:20 + i * 8])
        if struct.unpack(">I", blob[boff:boff + 4])[0] != CD_MAGIC:
            continue
        found = True
        flags = struct.unpack(">I", blob[boff + 12:boff + 16])[0]
        ident_off = struct.unpack(">I", blob[boff + 20:boff + 24])[0]
        end = blob.index(b"\0", boff + ident_off)
        ident = blob[boff + ident_off:end].decode("utf-8", "replace")
        if not (flags & CS_ADHOC):
            die(f"{label}: CodeDirectory 非 ad-hoc 签名 (flags=0x{flags:x}) ident={ident}")
        if "unsigned" in ident.lower():
            die(f"{label}: 签名为占位无效签名 ident={ident}")
        print(f"  [ok] {label}: arm64e · adhoc · ident={ident}")


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

    files = read_data_files(ar_members(raw))
    dylibs = []
    for name, data in files:
        norm = name.lstrip("./")
        if norm.startswith("var/jb/"):
            die(f"布局含 var/jb（rootless 风格），roothide 不允许: {norm}")
        if not norm.startswith(EXPECTED_PREFIX):
            die(f"文件不在 roothide 预期目录 {EXPECTED_PREFIX} 下: {norm}")
        if norm.endswith(".dylib"):
            dylibs.append((norm, data))
        else:
            print(f"  [ok] {norm} ({len(data)} B)")
    if not dylibs:
        die("deb 内没有 dylib")

    for norm, data in dylibs:
        magic = struct.unpack(">I", data[:4])[0]
        if magic in (0xCAFEBABE, 0xBEBAFECA):
            n = struct.unpack(">I", data[4:8])[0]
            for i in range(n):
                _, _, off, size = struct.unpack(">iiII", data[8 + i * 20:8 + i * 20 + 16])
                check_slice(data, off, size, f"{norm} slice{i}")
        else:
            check_slice(data, 0, len(data), norm)


def main():
    debs = sys.argv[1:]
    if not debs:
        die("未提供 deb 路径")
    for d in debs:
        check_deb(d)
    print("\n全部校验通过。")


if __name__ == "__main__":
    main()
