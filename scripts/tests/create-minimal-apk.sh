#!/bin/bash
# ============================================================================
# create-minimal-apk.sh — Generate a minimal HelloWorld APK
#
# Produces a valid .apk that apktool and jadx can decode/decompile.
#
# Strategy (in order of preference):
#   1. If apktool is available: write smali + AndroidManifest.xml, then
#      run `apktool b` to build a real APK.
#   2. Fallback: use a pure-Python generator that builds the binary
#      AXML and DEX from scratch and zips them.
#
# Usage:
#   ./scripts/tests/create-minimal-apk.sh [output.apk]
#
# Default output: /workspace/tests/fixtures/HelloWorld.apk
# ============================================================================

set -euo pipefail

OUTPUT="${1:-/workspace/tests/fixtures/HelloWorld.apk}"
OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------
# Option 1: apktool-based generation (smali + apktool b)
# ---------------------------------------------------------------
if command -v apktool &>/dev/null && [ -s "$(command -v apktool)" ] 2>/dev/null; then
    BUILD_DIR="$(mktemp -d)"
    trap 'rm -rf "$BUILD_DIR"' EXIT

    # --- smali source for HelloWorld ---
    mkdir -p "$BUILD_DIR/smali/com/example/helloworld"

    cat > "$BUILD_DIR/smali/com/example/helloworld/MainActivity.smali" <<'SMALI'
.class public Lcom/example/helloworld/MainActivity;
.super Landroid/app/Activity;
.source "MainActivity.java"

# direct methods
.method public constructor <init>()V
    .registers 1
    invoke-direct {p0}, Landroid/app/Activity;-><init>()V
    return-void
.end method

.method public onCreate(Landroid/os/Bundle;)V
    .registers 2
    invoke-super {p0, p1}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V
    return-void
.end method
SMALI

    # --- AndroidManifest.xml (plain text XML) ---
    cat > "$BUILD_DIR/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.helloworld">
    <application android:label="HelloWorld">
        <activity android:name=".MainActivity">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
XML

    # --- apktool.yml (metadata) ---
    cat > "$BUILD_DIR/apktool.yml" <<'YML'
!!brut.androlib.meta.MetaInfo
apkFileName: HelloWorld.apk
compressionType: false
isFrameworkApk: false
sdkInfo:
  minSdkVersion: '1'
  targetSdkVersion: '1'
packageInfo:
  forcedPackageId: '127'
  renameManifestPackage: null
versionInfo:
  versionCode: '1'
  versionName: '1.0'
YML

    echo "Building APK with apktool..."
    apktool b "$BUILD_DIR" -o "$OUTPUT" 2>&1
    echo "APK generated at: $OUTPUT"
    exit 0
fi

# ---------------------------------------------------------------
# Option 2: Pure-Python generation (no apktool dependency)
# ---------------------------------------------------------------
echo "apktool not available — generating APK with Python..."
exec python3 -c "
import hashlib, struct, zlib, zipfile, sys, os

OUTPUT = sys.argv[1]
os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)

# =========================================================================
# Build a minimal valid DEX file (v035)
#
# A single class: LHelloWorld; extends Ljava/lang/Object;
# with constructor <init>:()V that calls Object.<init>:()V.
# =========================================================================

# ---- helper: ULEB128 ----
def uleb128(val):
    buf = []
    while True:
        byte = val & 0x7F
        val >>= 7
        if val:
            buf.append(byte | 0x80)
        else:
            buf.append(byte)
            break
    return bytes(buf)

# ---- string pool data ----
strings = [
    # (mutf8_bytes)
    b'LHelloWorld;',
    b'Ljava/lang/Object;',
    b'<init>',
    b'()V',
    b'HelloWorld',
    b'V',
]

# Build string data items (ULEB128-size + MUTF8 + null terminator)
str_data_list = []
for s in strings:
    item = uleb128(len(s)) + s + b'\x00'
    str_data_list.append(item)

# ---- layout calculation ----
off = 0x70  # header size

# string_ids
str_ids_off = off
str_ids_count = len(strings)
off += str_ids_count * 4

# type_ids
type_ids_off = off
type_ids_count = 3  # 'V', 'LHelloWorld;', 'Ljava/lang/Object;'
off += type_ids_count * 4

# proto_ids
proto_ids_off = off
proto_ids_count = 1
off += proto_ids_count * 12

# method_ids
method_ids_off = off
method_ids_count = 2
off += method_ids_count * 8

# class_defs
class_defs_off = off
class_defs_count = 1
off += class_defs_count * 32

# data section
data_off = off

# string data
str_data_off = off
for sd in str_data_list:
    off += len(sd)

# padding to 4 bytes
while off % 4:
    off += 1

# class data
class_data_off = off
# Encode class data
cd_fields_static = uleb128(0)
cd_fields_instance = uleb128(0)
cd_methods_direct = uleb128(1)
cd_methods_virtual = uleb128(0)

# encoded method: method_idx_diff=0, access_flags=0x10001, code_off=???
# The code_off will be at a different offset. Let's compute it.
cd_method_idx = uleb128(0)
cd_access_flags = uleb128(0x10001)  # ACC_PUBLIC | ACC_CONSTRUCTOR

# We don't know code_off yet. Save position and update later.
class_data_header = cd_fields_static + cd_fields_instance + cd_methods_direct + cd_methods_virtual + cd_method_idx + cd_access_flags
class_data_payload_pos = len(class_data_header)  # where code_off ULEB128 goes
off += len(class_data_header)

# code_off placeholder (2 bytes for now, might need adjustment)
placeholder_code_off = uleb128(0)
off += len(placeholder_code_off)

# padding to 4 bytes for code item
while off % 4:
    off += 1

# code item
code_item_off = off
code_item_regs = struct.pack('<HHHH', 1, 1, 1, 0)  # regs=1, ins=1, outs=1, tries=0
code_item_debug = struct.pack('<II', 0, 4)  # debug_off=0, insns_size=4

# invoke-direct {v0}, Object.<init>:()V  (method_id[1])
# format: op=6E, byte1=0x10 (A=1,G=0), method=0x0001, regs=0x0000
insn1 = struct.pack('<BBH', 0x6E, 0x10, 1) + struct.pack('<H', 0)
# return-void
insn2 = struct.pack('<BB', 0x0E, 0x00)
insns = insn1 + insn2
code_item = code_item_regs + code_item_debug + insns
off += len(code_item)

# Map list
map_list_off = off
map_items = [
    (0x0000, 1, 0),           # HEADER
    (0x0001, str_ids_count, str_ids_off),  # STRING_ID
    (0x0002, type_ids_count, type_ids_off),  # TYPE_ID
    (0x0003, proto_ids_count, proto_ids_off),  # PROTO_ID
    (0x0004, method_ids_count, method_ids_off),  # METHOD_ID
    (0x0006, class_defs_count, class_defs_off),  # CLASS_DEF
    (0x000C, 1, code_item_off),  # CODE_ITEM
    (0x2003, len(strings), str_data_off),  # STRING_DATA
    (0x2002, 1, class_data_off),  # CLASS_DATA
    (0x1000, 1, map_list_off),  # MAP_LIST
]
map_list = struct.pack('<I', len(map_items))
for type_, size, offset in map_items:
    map_list += struct.pack('<HHII', type_, 0, size, offset)
off += len(map_list)

file_size = off

# ---- Now we know code_off. Patch it. ----
actual_code_off = class_data_off + len(class_data_header)
code_off_uleb128 = uleb128(actual_code_off)

# Rebuild class_data with correct code_off
class_data = class_data_header + code_off_uleb128
class_data_size = len(class_data)
off_verify = class_data_off + class_data_size
# Recompute needed padding:
# After class_data, we need 4-byte aligned for code_item
pad_needed = (4 - (off_verify % 4)) % 4
off_verify += pad_needed
assert off_verify == code_item_off, f'miscalc: off_verify={off_verify:#x} code_item_off={code_item_off:#x}'

# ---- Recompute with correct code_off ----
# Use the pre-computed consistent layout.

# ---- Build the sections ----
# Header (header_size=0x70, fill later)
header_bytes = bytearray(0x70)

# magic
header_bytes[0:8] = b'dex\n035\x00'

# header_size
struct.pack_into('<I', header_bytes, 0x08 + 8, 0x70)
# endian_tag
struct.pack_into('<I', header_bytes, 0x0C + 8, 0x12345678)
# file_size
struct.pack_into('<I', header_bytes, 0x04 + 8, file_size)

# link: 0
struct.pack_into('<II', header_bytes, 0x10 + 8, 0, 0)

# map_off
struct.pack_into('<I', header_bytes, 0x14 + 8, map_list_off)

# string_ids
struct.pack_into('<II', header_bytes, 0x18 + 8, str_ids_count, str_ids_off)
# type_ids
struct.pack_into('<II', header_bytes, 0x20 + 8, type_ids_count, type_ids_off)
# proto_ids
struct.pack_into('<II', header_bytes, 0x28 + 8, proto_ids_count, proto_ids_off)
# field_ids
struct.pack_into('<II', header_bytes, 0x30 + 8, 0, 0)
# method_ids
struct.pack_into('<II', header_bytes, 0x38 + 8, method_ids_count, method_ids_off)
# class_defs
struct.pack_into('<II', header_bytes, 0x40 + 8, class_defs_count, class_defs_off)
# data_size, data_off
struct.pack_into('<II', header_bytes, 0x48 + 8, file_size - data_off, data_off)

# ---- Assemble DEX ----
dex = bytearray(file_size)

# Header
dex[0:0x70] = header_bytes

# String IDs
str_off_val = str_data_off
for sd in str_data_list:
    struct.pack_into('<I', dex, str_ids_off, str_off_val)
    str_ids_off += 4
    str_off_val += len(sd)

# Type IDs: [0]='V'(str5), [1]='LHelloWorld;'(str0), [2]='Ljava/lang/Object;'(str1)
struct.pack_into('<III', dex, type_ids_off, 5, 0, 1)

# Proto IDs
# proto[0]: shorty=str_idx("()V")=3, return_type=type_idx(0)=0, params_off=0
struct.pack_into('<III', dex, proto_ids_off, 3, 0, 0)

# Method IDs
# method[0]: HelloWorld.<init>:()V  (class=1, proto=0, name=2)
# method[1]: Object.<init>:()V     (class=2, proto=0, name=2)
struct.pack_into('<HHH', dex, method_ids_off, 1, 0, 2)  # method 0
struct.pack_into('<HHH', dex, method_ids_off + 8, 2, 0, 2)  # method 1

# Class Defs
# class_def[0]: class=1, access=1(public), super=2, iface=0, src=4, ann=0, class_data=class_data_off, values=0
struct.pack_into('<IIIIIIII', dex, class_defs_off,
    1,     # class_idx
    1,     # access_flags = ACC_PUBLIC
    2,     # superclass_idx
    0,     # interfaces_off
    4,     # source_file_idx
    0,     # annotations_off
    class_data_off,
    0)     # static_values_off

# Data: string data
str_pos = str_data_off
for sd in str_data_list:
    dex[str_pos:str_pos+len(sd)] = sd
    str_pos += len(sd)

# Padding after string data
str_pos = data_off + sum(len(sd) for sd in str_data_list)
while str_pos % 4:
    dex[str_pos] = 0
    str_pos += 1

# Class data
dex[class_data_off:class_data_off+len(class_data)] = class_data
pos = class_data_off + len(class_data)
while pos % 4:
    dex[pos] = 0
    pos += 1

# Code item
dex[code_item_off:code_item_off+len(code_item)] = code_item

# Map list
dex[map_list_off:map_list_off+len(map_list)] = map_list

# ---- Compute checksum and signature ----
# SHA-1 of everything after the signature field (offset 32 to end)
sha1 = hashlib.sha1(bytes(dex[32:])).digest()
dex[12:12+20] = sha1  # signature at bytes 12-31

# Adler32 of everything after the checksum field (offset 8 to end, excluding bytes 8-11)
adler = zlib.adler32(bytes(dex[8:]))
dex[8:12] = struct.pack('<I', adler)  # checksum at bytes 8-11

dex_bytes = bytes(dex)

# =========================================================================
# Build a minimal Android Binary XML (AXML) file
# =========================================================================
# Minimal manifest:
#   <manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"
#             package=\"com.hello\" />
#
# Required chunks: StringPool, StartNamespace, StartElement, EndElement, EndNamespace

# Ensure 4-byte alignment
def pad4(data):
    while len(data) % 4:
        data += b'\\x00'
    return data

def build_chunk(type_, header_size, data):
    total_size = len(data)
    return struct.pack('<HHI', type_, header_size, total_size) + data

def build_string_pool(strings_utf16):
    \"\"\"Build a ResStringPool chunk (type=0x0001).\"\"\"
    # Each string: uint16 length, UTF-16LE bytes, uint16 null
    str_offsets = []
    str_bytes = b''
    for s in strings_utf16:
        str_offsets.append(len(str_bytes))
        encoded = s.encode('utf-16-le')
        str_bytes += struct.pack('<H', len(s)) + encoded + b'\\x00\\x00'

    # String pool header: 28 bytes
    header_size = 28
    # flags = 0x0000 (UTF-16, sorted, no style)
    flags = 0x0000

    chunk_header = struct.pack('<HHI', 0x0001, header_size, header_size + len(str_bytes))
    pool_header = chunk_header
    pool_header += struct.pack('<IIIIII',
        len(strings_utf16),  # stringCount
        0,                    # styleCount
        flags,                # flags
        0,                    # null terminated
        header_size,          # stringsStart
        0)                    # stylesStart
    # String offsets
    for off in str_offsets:
        pool_header += struct.pack('<I', off)

    return pool_header + str_bytes

# Build the minimal AXML
strings = ['android', 'http://schemas.android.com/apk/res/android', 'manifest', 'package', 'com.hello']
string_pool = build_string_pool(strings)

# Namespace start: xmlns:android=\"...\"
# prefix = string_idx('android') = 0
# uri = string_idx('http://...') = 1
ns_start = struct.pack('<HHIIII',
    0x0100, 24, 24+0,  # type, headerSize, chunkSize  (no extra data)
    0,                  # lineNumber
    0xFFFFFFFF,         # comment
    0,                  # prefix string index
    1)                  # uri string index

# Namespace end
ns_end = struct.pack('<HHIIII',
    0x0101, 24, 24+0,
    0, 0xFFFFFFFF,
    0, 1)

# Start element: <manifest package=\"com.hello\">
# element name = string_idx('manifest') = 2
# attr name = string_idx('package') = 3
# attr value = string_idx('com.hello') = 4
# namespace URI (for the attribute) — use 0xFFFFFFFF (no namespace)

start_elem_size = 24 + 12 + 1 * 20  # header + namespace + 1 attribute
start_elem_data = struct.pack('<HHI', 0x0102, 24, start_elem_size)
start_elem_data += struct.pack('<IIII',
    0,                  # lineNumber
    0xFFFFFFFF,         # comment
    2,                  # element name (string idx)
    0,                  # attribute start (namespace prefix for element? usually 0... actually this is 'namespace')
)
# attribute count = 1, attribute ID start, class attribute, style attribute
start_elem_data += struct.pack('<HHHH', 1, 0, 0, 0
)

# ns = 0xFFFFFFFF (no namespace), name = 3 (package), value = 4 (com.hello), type=0x03000008 (string), data=0
start_elem_data += struct.pack('<IIIIII',
    0xFFFFFFFF,         # namespace
    3,                  # name (string idx)
    4,                  # value (string idx)
    0x03000008,         # typed value type (ATTR_TYPE_STRING | ATTR_TYPE_INT)
    0x00000000,         # data
    0x00000000,
)

# End element: </manifest>
end_elem = struct.pack('<HHIIII',
    0x0103, 20, 20+0,
    0,                  # lineNumber
    0xFFFFFFFF,         # comment
    2)                  # element name (string idx)

axml = string_pool + ns_start + start_elem_data + end_elem + ns_end

# =========================================================================
# Build the APK (ZIP file)
# =========================================================================
with zipfile.ZipFile(OUTPUT, 'w', zipfile.ZIP_DEFLATED) as zf:
    zf.writestr('AndroidManifest.xml', axml)
    zf.writestr('classes.dex', dex_bytes)

print(f'APK generated at: {OUTPUT}')
print(f'  size: {os.path.getsize(OUTPUT)} bytes')
" "$OUTPUT"
