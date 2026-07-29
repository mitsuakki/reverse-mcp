#!/usr/bin/env python3
"""Build a minimal valid APK for testing apktool and jadx.

Produces an APK (ZIP) containing a binary AndroidManifest.xml and
a minimal classes.dex defining a HelloWorld class.

Usage:
    python3 apk-builder.py [output.apk]
"""

import hashlib
import os
import struct
import sys
import zlib
import zipfile


# =========================================================================
# ULEB128 encoder
# =========================================================================
def uleb128(val: int) -> bytes:
    buf = bytearray()
    while True:
        byte = val & 0x7F
        val >>= 7
        if val:
            buf.append(byte | 0x80)
        else:
            buf.append(byte)
            break
    return bytes(buf)


# =========================================================================
# DEX generation (DEX v035)
#
# Structure:
#   Single class LHelloWorld; extends Ljava/lang/Object;
#   Method: constructor <init>:()V calls Object.<init>:()V
# =========================================================================

# Raw string data (MUTF-8) for the string pool
DEX_STRINGS = [
    b"LHelloWorld;",
    b"Ljava/lang/Object;",
    b"<init>",
    b"()V",
    b"HelloWorld",
    b"V",
    b"Code",
]


def build_str_data_item(s: bytes) -> bytes:
    """DEX string_data_item: ULEB128(length) + MUTF-8 data + null."""
    return uleb128(len(s)) + s + b"\x00"


def build_dex() -> bytes:
    # --- Pre-build string data items (variable length) ---
    str_data_items = [build_str_data_item(s) for s in DEX_STRINGS]
    str_data_bytes = b"".join(str_data_items)

    # --- Pre-build code item (fixed) ---
    # invoke-direct {v0}, Object.<init>:()V  (method_id[1])
    insn1 = struct.pack("<BBHH", 0x6E, 0x10, 1, 0)
    # return-void
    insn2 = struct.pack("<BB", 0x0E, 0)
    insns = insn1 + insn2
    # CodeItem: registers_size=1, ins=1, outs=1, tries=0, debug_off=0, insns_size=4
    code_item = (
        struct.pack("<HHHH", 1, 1, 1, 0)
        + struct.pack("<II", 0, 4)
        + insns
    )

    # --- Pre-build class data (needs code_off, which we compute from layout) ---
    # static_fields_size=0, instance_fields=0, direct_methods=1, virtual_methods=0
    cd_header = b"".join([
        uleb128(0),  # static_fields_size
        uleb128(0),  # instance_fields_size
        uleb128(1),  # direct_methods_size
        uleb128(0),  # virtual_methods_size
        uleb128(0),  # encoded_method.method_idx_diff
        uleb128(0x10001),  # encoded_method.access_flags (ACC_PUBLIC|ACC_CONSTRUCTOR)
    ])
    # cd_header = 1+1+1+1+1+3 = 8 bytes

    # --- Compute offsets ---
    header_size = 0x70

    # string_ids
    str_ids_count = len(DEX_STRINGS)
    str_ids_size = str_ids_count * 4

    # type_ids — [0]="V"(str5), [1]="LHelloWorld;"(str0), [2]="Ljava/lang/Object;"(str1)
    type_ids_count = 3
    type_ids_size = type_ids_count * 4

    # proto_ids — [0]: shorty="()V"(str3), return=V(type0), params=0
    proto_ids_count = 1
    proto_ids_size = proto_ids_count * 12

    # method_ids — [0]=HelloWorld.<init>, [1]=Object.<init>
    method_ids_count = 2
    method_ids_size = method_ids_count * 8

    # class_defs — [0]: HelloWorld
    class_defs_count = 1
    class_defs_size = class_defs_count * 32

    # Fixed-size sections total
    fixed_off = header_size  # 0x70

    str_ids_off = fixed_off
    type_ids_off = str_ids_off + str_ids_size
    proto_ids_off = type_ids_off + type_ids_size
    method_ids_off = proto_ids_off + proto_ids_size
    class_defs_off = method_ids_off + method_ids_size

    # Data section starts after class_defs
    data_off = class_defs_off + class_defs_size

    # String data
    str_data_off = data_off
    str_data_end = str_data_off + len(str_data_bytes)

    # Pad to 4
    def align4(addr: int) -> int:
        return (addr + 3) & ~3

    class_data_off = align4(str_data_end)

    # code_item_off depends on class_data size, which depends on code_off encoding
    # Estimate code_off: class_data_off + len(cd_header) + ~2 bytes ≈ 0x110+8+2 = 0x11A
    # Aligned to 4 → 0x11C
    # uleb128(0x11C) = ? Let's estimate.
    # class_data_off + 8 is the code_off target (pointing to after cd_header),
    # but the actual value needs to point to the aligned code_item.
    # Use iterative approach:
    for _ in range(4):  # max 4 iterations
        code_off_estimate = class_data_off + len(cd_header)
        code_off_uleb = uleb128(code_off_estimate)
        class_data_size = len(cd_header) + len(code_off_uleb)
        class_data_end = class_data_off + class_data_size
        code_item_off = align4(class_data_end)
        if code_off_uleb == uleb128(code_item_off):
            break
        # Need larger code_off → uleb128 might grow
        class_data_off = class_data_off  # unchanged
        # code_item_off is now bigger → update code_off value
        new_code_off_uleb = uleb128(code_item_off)
        if len(new_code_off_uleb) <= len(code_off_uleb):
            # Same size → just use code_item_off
            actual_code_off = code_item_off
            code_off_uleb = new_code_off_uleb
            class_data_size = len(cd_header) + len(code_off_uleb)
            class_data_end = class_data_off + class_data_size
            code_item_off = align4(class_data_end)
            break
        # Size grew → adjust class_data
        old_len = len(code_off_uleb)
        code_off_uleb = new_code_off_uleb
        class_data_size = len(cd_header) + len(code_off_uleb)
        class_data_end = class_data_off + class_data_size
        code_item_off = align4(class_data_end)

    actual_code_off = code_item_off

    # Build final class data with correct code_off
    class_data = cd_header + uleb128(actual_code_off)
    assert len(class_data) == class_data_size, (
        f"class_data size mismatch: {len(class_data)} vs {class_data_size}"
    )

    # Map list
    map_items = [
        (0x0000, 1, 0),  # HEADER
        (0x0001, str_ids_count, str_ids_off),
        (0x0002, type_ids_count, type_ids_off),
        (0x0003, proto_ids_count, proto_ids_off),
        (0x0004, method_ids_count, method_ids_off),
        (0x0006, class_defs_count, class_defs_off),
        (0x000C, 1, code_item_off),
        (0x2003, len(DEX_STRINGS), str_data_off),
        (0x2002, 1, class_data_off),
        (0x1000, 1, 0),  # MAP_LIST offset filled below
    ]
    map_list_header = struct.pack("<I", len(map_items))
    map_list_body = b"".join(
        struct.pack("<HHII", typ, 0, cnt, off)
        for typ, cnt, off in map_items
    )
    # Patch MAP_LIST offset
    map_items[9] = (0x1000, 1, 0)  # placeholder
    map_list_off = align4(code_item_off + len(code_item))
    map_list_body = b"".join(
        struct.pack("<HHII", typ, 0, cnt, off)
        for typ, cnt, off in map_items[:-1]
    )
    map_list_body += struct.pack("<HHII", 0x1000, 0, 1, map_list_off)
    map_list = map_list_header + map_list_body

    file_size = map_list_off + len(map_list)

    # --- Assemble DEX ---
    dex = bytearray(file_size)

    # Header
    dex[0:8] = b"dex\n035\x00"
    struct.pack_into("<I", dex, 32, file_size)
    struct.pack_into("<I", dex, 36, 0x70)
    struct.pack_into("<I", dex, 40, 0x12345678)
    struct.pack_into("<II", dex, 44, 0, 0)  # link: 0
    struct.pack_into("<I", dex, 52, map_list_off)
    struct.pack_into("<II", dex, 56, str_ids_count, str_ids_off)
    struct.pack_into("<II", dex, 64, type_ids_count, type_ids_off)
    struct.pack_into("<II", dex, 72, proto_ids_count, proto_ids_off)
    struct.pack_into("<II", dex, 80, 0, 0)  # field_ids
    struct.pack_into("<II", dex, 88, method_ids_count, method_ids_off)
    struct.pack_into("<II", dex, 96, class_defs_count, class_defs_off)
    struct.pack_into("<II", dex, 104, file_size - data_off, data_off)

    # String IDs
    pos = str_ids_off
    sdo = str_data_off
    for sd in str_data_items:
        struct.pack_into("<I", dex, pos, sdo)
        pos += 4
        sdo += len(sd)

    # Type IDs: "V"(5), "LHelloWorld;"(0), "Ljava/lang/Object;"(1)
    struct.pack_into("<III", dex, type_ids_off, 5, 0, 1)

    # Proto IDs: shorty_idx="()V"(3), return_type=type0(V), params_off=0
    struct.pack_into("<III", dex, proto_ids_off, 3, 0, 0)

    # Method IDs: class_idx(ushort), proto_idx(ushort), name_idx(uint)
    struct.pack_into("<HHI", dex, method_ids_off, 1, 0, 2)  # HelloWorld.<init>
    struct.pack_into("<HHI", dex, method_ids_off + 8, 2, 0, 2)  # Object.<init>

    # Class Def
    struct.pack_into("<I", dex, class_defs_off, 1)         # class_idx=1
    struct.pack_into("<I", dex, class_defs_off + 4, 1)     # access_flags=1
    struct.pack_into("<I", dex, class_defs_off + 8, 2)     # superclass_idx=2
    struct.pack_into("<I", dex, class_defs_off + 12, 0)    # interfaces_off=0
    struct.pack_into("<I", dex, class_defs_off + 16, 4)    # source_file_idx=4
    struct.pack_into("<I", dex, class_defs_off + 20, 0)    # annotations_off=0
    struct.pack_into("<I", dex, class_defs_off + 24, class_data_off)
    struct.pack_into("<I", dex, class_defs_off + 28, 0)    # static_values_off=0

    # String data
    dex[str_data_off:str_data_off + len(str_data_bytes)] = str_data_bytes

    # Class data
    dex[class_data_off:class_data_off + len(class_data)] = class_data

    # Code item
    dex[code_item_off:code_item_off + len(code_item)] = code_item

    # Map list
    dex[map_list_off:map_list_off + len(map_list)] = map_list

    # --- Checksum & signature ---
    sha1 = hashlib.sha1(bytes(dex[32:])).digest()
    dex[12:32] = sha1
    adler = zlib.adler32(bytes(dex[8:]))
    dex[8:12] = struct.pack("<I", adler)

    # Sanity check: verify the DEX header is self-consistent
    dex_bytes = bytes(dex)
    assert len(dex_bytes) == file_size
    magic = dex_bytes[:8]
    assert magic[:4] == b"dex\n", f"Bad magic: {magic}"
    assert magic[4:8] == b"035\x00", f"Bad version: {magic}"

    return dex_bytes


# =========================================================================
# AXML (Android Binary XML) generation
#
# Produces:
#   <?xml version="1.0" encoding="utf-8"?>
#   <manifest xmlns:android="http://schemas.android.com/apk/res/android"
#             package="com.hello" />
# =========================================================================
def build_axml() -> bytes:
    strings = [
        "android",
        "http://schemas.android.com/apk/res/android",
        "manifest",
        "package",
        "com.hello",
    ]

    # ---- String Pool (type=0x0001) ----
    str_offsets = []
    str_data = b""
    for s in strings:
        str_offsets.append(len(str_data))
        encoded = s.encode("utf-16-le")
        str_data += struct.pack("<H", len(s)) + encoded + b"\x00\x00"

    sp_hdr_size = 28
    sp_total = sp_hdr_size + len(str_data)
    sp = struct.pack("<HHI", 0x0001, sp_hdr_size, sp_total)
    sp += struct.pack(
        "<IIIIII",
        len(strings),  # stringCount
        0,  # styleCount
        0x0000,  # flags (UTF-16)
        0,  # null terminated
        sp_hdr_size,  # stringsStart
        0,  # stylesStart
    )
    for off in str_offsets:
        sp += struct.pack("<I", off)
    sp += str_data

    # ---- Namespace Start (type=0x0100) ----
    # prefix="android"(0), uri="http://..."(1)
    ns_start = struct.pack(
        "<HHIIIII", 0x0100, 24, 24, 0, 0xFFFFFFFF, 0, 1
    )

    # ---- Start Element: <manifest package="com.hello"> (type=0x0102) ----
    # Element name = "manifest"(2)
    # One attribute: name="package"(3), value="com.hello"(4)
    # Attribute namespace: 0xFFFFFFFF (no namespace)
    elem_hdr = struct.pack(
        "<HHI", 0x0102, 24, 24 + 12 + 20
    )
    # lineNumber, comment, element_name_idx, namespace_uri
    elem_hdr += struct.pack("<IIII", 0, 0xFFFFFFFF, 2, 0)
    # attr_count, attr_start_id, class_attr, style_attr
    elem_hdr += struct.pack("<HHHH", 1, 0, 0, 0)
    # Attribute:
    #   namespace=0xFFFFFFFF (none), name=3, value=4,
    #   typed_value: type=0x03000008 (STRING), data=0
    elem_hdr += struct.pack(
        "<IIIIII",
        0xFFFFFFFF,  # ns
        3,  # name idx
        4,  # value idx
        0x03000008,  # typed value type (STRING)
        0x00000000,  # data
        0x00000000,
    )

    # ---- End Element: </manifest> (type=0x0103) ----
    end_elem = struct.pack(
        "<HHIIII", 0x0103, 20, 20, 0, 0xFFFFFFFF, 2
    )

    # ---- Namespace End (type=0x0101) ----
    ns_end = struct.pack(
        "<HHIIIII", 0x0101, 24, 24, 0, 0xFFFFFFFF, 0, 1
    )

    return sp + ns_start + elem_hdr + end_elem + ns_end


# =========================================================================
# APK assembly
# =========================================================================
def build_apk(output_path: str):
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    dex_bytes = build_dex()
    axml_bytes = build_axml()

    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("AndroidManifest.xml", axml_bytes)
        zf.writestr("classes.dex", dex_bytes)

    size = os.path.getsize(output_path)
    print(f"APK generated: {output_path}")
    print(f"  ZIP size: {size} bytes")
    print(f"  classes.dex: {len(dex_bytes)} bytes")
    print(f"  AndroidManifest.xml: {len(axml_bytes)} bytes")

    # Quick validation
    with zipfile.ZipFile(output_path, "r") as zf:
        names = zf.namelist()
        for n in names:
            info = zf.getinfo(n)
            print(f"  {n}: {info.file_size} bytes (compressed: {info.compress_size})")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "HelloWorld.apk"
    build_apk(out)
