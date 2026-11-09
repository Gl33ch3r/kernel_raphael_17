#!/usr/bin/env bash
# All-in-one Raphael branch 17 build: Boolx Clang 22, NetHunter, 88x2bu,
# KernelSU-Next legacy, EA8076 60/75/90 Hz, external DTC and boot/DTBO packaging.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

show_help() {
    cat <<'EOF'
Usage: ./build.sh [--ksu] [--nethunter] [make targets/options ...]

Defaults: raphael_defconfig, out/, all + Image.gz, Clang 22, built-in 88x2bu.
KernelSU-Next and NetHunter are disabled unless their flags are supplied.
Options:
  --ksu          Download/integrate KernelSU-Next legacy with manual hooks
  --nethunter    Enable the NetHunter kernel configuration profile
  --bootimg-only Package an existing compiled kernel using STOCK_BOOT_IMG
  --dtbo-only    Package an existing Raphael overlay using STOCK_DTBO_IMG
  --rom-dtbo-patch Apply the verified, ROM-specific 75/90 Hz DTBO patch
  --wifi-diagnose Collect adapter diagnostics through adb
  --help, -h     Show this help
Feature flags can be combined and may appear before or after make targets.
They cannot be used with --bootimg-only, --dtbo-only or --wifi-diagnose.
Environment:
  TOOLCHAIN  LLVM 22 installation directory (default: ./toolchain/clang22)
  OUT_DIR    Build directory (default: out, relative to the source tree)
  DEFCONFIG  Configuration in arch/arm64/configs (default: raphael_defconfig)
  JOBS       Parallel jobs (default: 4)
  LLVM_IAS   Use LLVM assembler: 1 (default); 0 requires GNU cross-binutils
  DTC_EXT    External dtc executable (default: dtc from PATH)
  STOCK_BOOT_IMG  Working boot.img from the same ROM; enables boot.img packaging
  STOCK_DTBO_IMG  Working dtbo.img from the same ROM; enables DTBO packaging
  DTBO_INDEX     Entry index to replace in that template (or comma-separated indices)

Examples:
  ./build.sh
  ./build.sh --ksu
  ./build.sh --nethunter
  ./build.sh --ksu --nethunter
  TOOLCHAIN=/opt/clang-22 JOBS=8 ./build.sh
  ./build.sh menuconfig
  ./build.sh --wifi-diagnose
  ./build.sh Image.gz dtbs
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh --bootimg-only
  STOCK_DTBO_IMG=/path/to/working/dtbo.img DTBO_INDEX=0 ./build.sh --dtbo-only
  STOCK_DTBO_IMG=/path/to/original/dtbo.img ./build.sh --dtbo-only --rom-dtbo-patch

Missing toolchains are downloaded from the Boolx-22 GitHub release.
The pinned 88x2bu driver is downloaded and enabled for Archer T3U Plus (2357:0138).
With --ksu, official KernelSU-Next legacy is pinned for this 4.14 kernel.
All source/configuration fixes and boot.img packaging are embedded in this file;
copy only build.sh into the root of a complete branch 17 checkout to use it.
With --nethunter, enable chroot IPC, USB gadgets/serial, USB Bluetooth, mac80211,
and packet filtering. The Kali rootfs and Android apps are installed separately.
Enabled NetHunter settings are recorded in out/nethunter-config.txt.
Repeat the desired flags on every build; changing flags restores pre-feature
settings and preserves unrelated configuration edits. Old configurations are
backed up when migrating from the previous always-enabled script.
Display modes: stock 60 Hz plus experimental 75/90 Hz from Bool-X's pinned
16-HyperMiui-erofs source. 75 Hz is preferred; the stock 60 Hz mode remains available. That source
does not implement 120 Hz. Higher rates require device testing and a matching
rebuilt DTBO; repacking boot.img alone preserves the stock display device tree.
Requires a Linux x86_64 host.
Debian/Ubuntu host dependencies:
  build-essential bc bison flex libssl-dev libelf-dev zlib1g-dev
  python3 perl pkg-config cpio gzip lz4 curl tar zstd device-tree-compiler

Outputs: out/arch/arm64/boot/Image, Image.gz, device trees under boot/dts/,
         out/vmlinux, out/System.map, and modules when enabled.
Set STOCK_BOOT_IMG, or place stock_boot.img beside this script, to create out/boot.img.
Use a template from the same Raphael ROM. Its ramdisk and device trees are
preserved. magiskboot is downloaded automatically; MAGISKBOOT can override it.
ROM-specific image signing is separate.
DTBO packaging preserves the template's other entries and metadata. Select the
Raphael entry indices appropriate for your ROM; images are never flashed here.
--rom-dtbo-patch only accepts the verified LineageOS 17 DTBO from this setup.
It produces a fixed experimental image for entry 11, not the current build's
overlay. Keep the original; phone behavior and parent AVB acceptance are untested.
EOF
}

WITH_KSU=0
WITH_NETHUNTER=0
WITH_ROM_DTBO_PATCH=0
MODE=build
make_options=()
while (( $# )); do
    case "$1" in
        --ksu) WITH_KSU=1 ;;
        --nethunter) WITH_NETHUNTER=1 ;;
        --rom-dtbo-patch) WITH_ROM_DTBO_PATCH=1 ;;
        --help|-h) show_help; exit 0 ;;
        --bootimg-only|--dtbo-only|--wifi-diagnose)
            [[ $MODE == build || $MODE == "${1#--}" ]] || die 'Choose only one build mode.'
            MODE=${1#--}
            ;;
        --) shift; make_options+=("$@"); break ;;
        *) make_options+=("$1") ;;
    esac
    shift
done
set -- "${make_options[@]}"
if [[ $MODE != build ]]; then
    (( WITH_KSU == 0 && WITH_NETHUNTER == 0 )) ||
        die '--ksu and --nethunter require a build; they cannot change an already compiled kernel or run diagnostics.'
    (( $# == 0 )) || die "--$MODE does not accept make targets/options."
fi
if (( WITH_ROM_DTBO_PATCH )); then
    [[ $MODE == build || $MODE == dtbo-only ]] ||
        die '--rom-dtbo-patch can only be used with a build or --dtbo-only.'
    [[ -n ${STOCK_DTBO_IMG:-} ]] ||
        die 'Set STOCK_DTBO_IMG to the original, verified LineageOS 17 DTBO image.'
    [[ -z ${DTBO_INDEX:-} || $DTBO_INDEX == 11 ]] ||
        die '--rom-dtbo-patch supports only the verified DTBO entry 11.'
    DTBO_INDEX=11
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$ROOT"
wifi_diagnose() {
    command -v adb >/dev/null 2>&1 || die 'Install adb on the host and enable USB debugging on the phone.'
    local log="$ROOT/out/t3u-plus-diagnostics.txt"
    mkdir -p -- "$(dirname -- "$log")"
    adb get-state >/dev/null || die 'No phone connected through adb.'
    {
        adb shell '
            echo "=== Running kernel ==="
            uname -a
            echo "=== Built-in driver and USB registration ==="
            ls -ld /sys/module/88x2bu /sys/bus/usb/drivers/rtl88x2bu 2>&1
            echo "=== USB devices and interface bindings ==="
            for d in /sys/bus/usb/devices/*; do
                if [ -r "$d/idVendor" ]; then
                    printf "%s %s:%s\n" "$d" "$(cat "$d/idVendor")" "$(cat "$d/idProduct")"
                fi
                if [ -L "$d/driver" ]; then
                    printf "%s driver=" "$d"
                    readlink "$d/driver"
                fi
            done
            echo "=== Network interfaces ==="
            ip link
            echo "=== Kernel configuration when available ==="
            if [ -r /proc/config.gz ]; then
                gzip -dc /proc/config.gz | grep -E "CONFIG_(RTL8822BU|KSU|KPROBES|USB_DWC3|CFG80211)="
            fi
        '
        printf '\n=== USB/Wi-Fi probe messages (root may be required) ===\n'
        adb shell 'su -c dmesg' 2>&1 |
            grep -iE 'rtw|rtl|88x2|8822|8812|usb|cfg80211|wiphy|firmware|denied|not found' |
            tail -n 120 || true
    } | tee "$log"
    printf '\nDiagnostic report saved to: %s\n' "$log"
}

if [[ $MODE == wifi-diagnose ]]; then
    wifi_diagnose
    exit 0
fi

TOOLCHAIN=${TOOLCHAIN:-"$ROOT/toolchain/clang22"}
[[ $TOOLCHAIN = /* ]] || TOOLCHAIN="$ROOT/$TOOLCHAIN"
TOOLCHAIN=${TOOLCHAIN%/}
[[ -f Makefile && -d arch/arm64 ]] || die 'Run from a complete kernel checkout.'

command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
OUT_DIR=${OUT_DIR:-"$ROOT/out"}
[[ $OUT_DIR = /* ]] || OUT_DIR="$ROOT/$OUT_DIR"
mkdir -p -- "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)
[[ $OUT_DIR != "$ROOT" ]] || die 'OUT_DIR must differ from the source directory.'

# A template beside the script enables packaging on a default build.
if [[ $MODE != dtbo-only && -z ${STOCK_BOOT_IMG:-} && -s $ROOT/stock_boot.img ]] &&
   (( $# == 0 )); then
    STOCK_BOOT_IMG="$ROOT/stock_boot.img"
fi

BOOTIMG_ONLY=0
if [[ $MODE == bootimg-only ]]; then
    BOOTIMG_ONLY=1
    (( $# == 0 )) || die '--bootimg-only does not accept make targets.'
    [[ -n ${STOCK_BOOT_IMG:-} ]] || die 'Set STOCK_BOOT_IMG to a working boot.img from the same ROM.'
fi
if [[ $MODE != dtbo-only && -n ${STOCK_BOOT_IMG:-} ]]; then
    [[ -s $STOCK_BOOT_IMG ]] || die "Working boot image not found: $STOCK_BOOT_IMG"
    (( $# == 0 )) || die 'Use STOCK_BOOT_IMG with the default build (no make targets).'
    STOCK_BOOT_IMG=$(realpath -- "$STOCK_BOOT_IMG")
    python3 - "$STOCK_BOOT_IMG" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    if f.read(8) != b'ANDROID!':
        sys.exit('Error: STOCK_BOOT_IMG must be an Android boot.img.')
PY
fi

if [[ $MODE == dtbo-only && -z ${STOCK_DTBO_IMG:-} ]]; then
    die 'Set STOCK_DTBO_IMG to a working dtbo.img from the same Raphael ROM.'
fi
if [[ -n ${STOCK_DTBO_IMG:-} ]]; then
    [[ -s $STOCK_DTBO_IMG ]] || die "Working DTBO image not found: $STOCK_DTBO_IMG"
    [[ ${DTBO_INDEX:-} =~ ^[0-9]+(,[0-9]+)*$ ]] ||
        die 'Set DTBO_INDEX to the Raphael entry index, or comma-separated indices, in STOCK_DTBO_IMG.'
    STOCK_DTBO_IMG=$(realpath -- "$STOCK_DTBO_IMG")
    if (( WITH_ROM_DTBO_PATCH )); then
        python3 - "$STOCK_DTBO_IMG" <<'PY'
import hashlib, sys
with open(sys.argv[1], 'rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else None
    if digest is None:
        source.seek(0)
        hasher = hashlib.sha256()
        for chunk in iter(lambda: source.read(1048576), b''):
            hasher.update(chunk)
        digest = hasher.hexdigest()
if digest != '2a7fedf9e370b421227879ae1ca035b30028bbdbf7f7265b553770d3c60a9674':
    sys.exit('Error: --rom-dtbo-patch only supports the exact verified original DTBO image.')
PY
    fi
    python3 - "$STOCK_DTBO_IMG" "$DTBO_INDEX" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    raw = f.read(32)
if len(raw) != 32:
    sys.exit('Error: truncated Android DTBO table header.')
magic, total, header, entry, count, offset, page, version = struct.unpack('>8I', raw)
if magic != 0xd7b7ab1e or version not in (0, 1):
    sys.exit('Error: STOCK_DTBO_IMG must be an Android DTBO table image (v0/v1).')
if any(int(index) >= count for index in sys.argv[2].split(',')):
    sys.exit(f'Error: DTBO_INDEX must select existing entries 0 through {count - 1}.')
PY
fi

pack_verified_rom_dtbo() {
    command -v zstd >/dev/null 2>&1 || die '--rom-dtbo-patch requires zstd.'
    python3 - "$STOCK_DTBO_IMG" "$OUT_DIR/dtbo.img" <<'PYROMDTBO'
import base64, hashlib, lzma, os, pathlib, subprocess, sys, tempfile

original, output = map(pathlib.Path, sys.argv[1:])
input_hash = '2a7fedf9e370b421227879ae1ca035b30028bbdbf7f7265b553770d3c60a9674'
output_hash = '9f4b9690d3e7c9f484aab4e23c9bc4df8a7a8ae47f57e2c876c7277f35ce5349'
def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()
if original.resolve() == output.resolve() or (output.exists() and os.path.samefile(original, output)):
    sys.exit('Error: DTBO output must differ from the original image.')
if sha256(original) != input_hash:
    sys.exit('Error: original DTBO changed or does not match the verified ROM image.')

# Fixed binary delta for the verified LineageOS 17 Raphael DTBO, entry 11.
encoded = b"""
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
tEaSAAHCF/EjAACLqWRJscRn+wIAAAAABFla
"""
with tempfile.TemporaryDirectory(prefix='.rom-dtbo-', dir=output.parent) as work:
    patch = pathlib.Path(work) / 'patch.zst'
    result = pathlib.Path(work) / 'dtbo.img'
    try:
        patch.write_bytes(lzma.decompress(base64.b64decode(encoded, validate=False)))
        subprocess.run(['zstd', '-q', '-d', '--patch-from=' + str(original),
                        str(patch), '-o', str(result)], check=True)
    except (lzma.LZMAError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'Error: cannot reconstruct the verified ROM DTBO: {exc}')
    if sha256(result) != output_hash:
        sys.exit('Error: reconstructed ROM DTBO failed its SHA-256 check.')
    os.replace(result, output)
print(f'Verified ROM-specific DTBO image created: {output}')
print('This fixed patch does not use the current build overlay; keep the original for recovery.')
print('Panel behavior and installed parent AVB acceptance require device testing.')
PYROMDTBO
}

pack_dtbo_image() (
    command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
    [[ -n ${STOCK_DTBO_IMG:-} ]] || die 'Set STOCK_DTBO_IMG to a matching unsigned Android DTBO image.'
    [[ -n ${DTBO_INDEX:-} ]] || die 'Set DTBO_INDEX to the matching Raphael entry index (or comma-separated indices).'
    if (( WITH_ROM_DTBO_PATCH )); then
        pack_verified_rom_dtbo
        return
    fi
    python3 - "$STOCK_DTBO_IMG" "$DTBO_INDEX" \
        "$OUT_DIR/arch/arm64/boot/dts/qcom/raphael-sm8150-overlay.dtbo" \
        "$OUT_DIR/dtbo.img" <<'PYDTBO'
"""Replace explicitly selected Android DTBO table entries; never flash a device."""
from pathlib import Path
import gzip
import os
import re
import struct
import sys
import tempfile
import zlib

DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_MAGIC = 0xD00DFEED


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_fdt(data, label):
    require(len(data) >= 40, f'{label}: truncated FDT header')
    magic, size, tree, strings, reservations, version, compatible, _, string_size, tree_size = struct.unpack_from('>10I', data)
    require(magic == FDT_MAGIC and size == len(data), f'{label}: expected one exact FDT blob')
    require(version >= 17 and compatible <= 17, f'{label}: unsupported FDT version')
    require(tree >= 40 and tree % 4 == 0 and tree_size % 4 == 0 and tree + tree_size <= size, f'{label}: invalid FDT structure bounds')
    require(strings >= 40 and strings + string_size <= size, f'{label}: invalid FDT strings bounds')
    require(reservations >= 40 and reservations % 8 == 0, f'{label}: invalid FDT reservation map')
    end_reservations = reservations
    while True:
        require(end_reservations + 16 <= size, f'{label}: unterminated FDT reservation map')
        address, length = struct.unpack_from('>QQ', data, end_reservations)
        end_reservations += 16
        if address == 0 and length == 0:
            break
    ranges = sorted([(0, 40), (reservations, end_reservations), (tree, tree + tree_size), (strings, strings + string_size)])
    for left, right in zip(ranges, ranges[1:]):
        require(left[1] <= right[0], f'{label}: overlapping FDT sections')
    position, limit, depth, roots, ended = tree, tree + tree_size, 0, 0, False
    names = data[strings:strings + string_size]
    while position + 4 <= limit:
        token, = struct.unpack_from('>I', data, position)
        position += 4
        if token == 1:  # FDT_BEGIN_NODE
            end = data.find(b'\0', position, limit)
            require(end >= 0, f'{label}: unterminated FDT node name')
            if depth == 0:
                roots += 1
                require(roots == 1 and end == position, f'{label}: invalid FDT root')
            depth += 1
            position = (end + 4) & ~3
        elif token == 2:  # FDT_END_NODE
            require(depth > 0, f'{label}: unbalanced FDT nodes')
            depth -= 1
        elif token == 3:  # FDT_PROP
            require(depth > 0 and position + 8 <= limit, f'{label}: invalid FDT property')
            length, name = struct.unpack_from('>II', data, position)
            position += 8
            require(name < len(names) and names.find(b'\0', name) >= 0, f'{label}: invalid FDT property name')
            require(position + length <= limit, f'{label}: truncated FDT property')
            position = (position + length + 3) & ~3
        elif token == 4:  # FDT_NOP
            pass
        elif token == 9:  # FDT_END
            require(depth == 0 and roots == 1 and not any(data[position:limit]), f'{label}: invalid FDT end')
            ended = True
            break
        else:
            raise ValueError(f'{label}: unknown FDT structure token {token}')
    require(ended, f'{label}: missing FDT end token')


def decode(payload, compression, label):
    if compression == 0:
        result = payload
    else:
        # AOSP v1: 1=zlib, 2=gzip; the low four flag bits hold the method.
        require(compression in (1, 2), f'{label}: unsupported compression {compression}')
        inflater = zlib.decompressobj(15 if compression == 1 else 31)
        result = inflater.decompress(payload) + inflater.flush()
        require(inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail, f'{label}: invalid compressed FDT stream')
    validate_fdt(result, label)
    return result


def encode(payload, compression):
    if compression == 1:
        return zlib.compress(payload, 9)
    if compression == 2:
        return gzip.compress(payload, compresslevel=9, mtime=0)
    return payload


def repack_bytes(image, replacement, selection):
    require(len(image) >= 32, 'truncated Android DTBO header')
    require(image[-64:-60] != b'AVBf', 'AVB-signed DTBO templates need re-signing; use an unsigned template and handle ROM signing separately')
    magic, total, header_size, entry_size, count, entries_at, page_size, version = struct.unpack_from('>8I', image)
    require(magic == DT_TABLE_MAGIC, 'STOCK_DTBO_IMG is not an Android DTBO table image')
    require(version in (0, 1), f'unsupported Android DTBO table version {version}')
    require(32 <= header_size <= entries_at and entry_size >= 32 and count > 0, 'invalid DTBO table header/entry dimensions')
    end_entries = entries_at + count * entry_size
    require(end_entries <= total <= len(image), 'DTBO table or total_size exceeds the template bounds')
    require(selection and all(0 <= index < count for index in selection), f'DTBO_INDEX must select entries between 0 and {count - 1}')
    validate_fdt(replacement, 'compiled Raphael overlay')
    entries, ranges = [], set()
    for index in range(count):
        at = entries_at + index * entry_size
        values = struct.unpack_from('>8I', image, at)
        length, offset = values[:2]
        require(length > 0 and end_entries <= offset <= total and length <= total - offset, f'DTBO entry {index}: invalid payload bounds')
        method = (values[4] & 15) if version == 1 else 0
        payload = image[offset:offset + length]
        decode(payload, method, f'DTBO entry {index}')
        entries.append((at, length, offset, method, payload))
        ranges.add((offset, offset + length))
    ordered = sorted(ranges)
    for left, right in zip(ordered, ordered[1:]):
        require(left[1] <= right[0], 'DTBO payloads partially overlap; exact shared payloads are allowed')
        require(not any(image[left[1]:right[0]]), 'unsupported nonzero data between DTBO payloads')
    require(not any(image[ordered[-1][1]:total]) and not any(image[total:]), 'unsupported nonzero data after DTBO payloads')
    # Both compact AOSP images and page-aligned vendor images are valid.
    aligned = page_size > 0 and page_size & (page_size - 1) == 0 and all(start % page_size == 0 for start, _ in ordered)
    result = bytearray(image[:ordered[0][0]])
    placed = {}
    for index, (at, length, offset, method, payload) in enumerate(entries):
        selected = index in selection
        key = (offset, length, selected)
        if key not in placed:
            if aligned:
                result.extend(b'\0' * (-len(result) % page_size))
            if selected:
                payload = encode(replacement, method)
            placed[key] = (len(payload), len(result))
            result.extend(payload)
        length, offset = placed[key]
        require(length <= 0xFFFFFFFF and offset <= 0xFFFFFFFF, 'rebuilt DTBO exceeds the table format limit')
        struct.pack_into('>II', result, at, length, offset)
    if aligned and total % page_size == 0:
        result.extend(b'\0' * (-len(result) % page_size))
    require(len(result) <= 0xFFFFFFFF, 'rebuilt DTBO exceeds the table format limit')
    struct.pack_into('>I', result, 4, len(result))
    if len(image) > total:
        require(len(result) <= len(image), 'rebuilt DTBO does not fit the template padded image size')
        result.extend(b'\0' * (len(image) - len(result)))
    return bytes(result)


def main(arguments):
    require(len(arguments) == 4, 'usage: dtbo_repack.py STOCK_DTBO_IMG DTBO_INDEX COMPILED_OVERLAY OUTPUT')
    stock, indices, raw, destination = arguments
    require(indices and all(re.fullmatch(r'[0-9]+', token.strip()) for token in indices.split(',')), 'DTBO_INDEX must be an explicit index or comma-separated indices, such as 0 or 0,1')
    selected = [int(token.strip()) for token in indices.split(',')]
    require(len(selected) == len(set(selected)), 'DTBO_INDEX contains duplicate indices')
    stock, raw, destination = map(Path, (stock, raw, destination))
    require(stock.is_file() and raw.is_file(), 'missing stock DTBO image or compiled Raphael overlay')
    require(not destination.is_dir(), 'DTBO output must be a filename, not a directory')
    for source in (stock, raw):
        require(destination.resolve() != source.resolve() and not (destination.exists() and os.path.samefile(destination, source)), 'DTBO output must differ from both inputs')
    result = repack_bytes(stock.read_bytes(), raw.read_bytes(), set(selected))
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.dtbo-', delete=False) as output:
            temporary = Path(output.name)
            output.write(result)
        temporary.replace(destination)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    print(f'DTBO image created: {destination} (replaced entries {",".join(map(str, selected))})')
    print('DTBO signing/AVB verification, if required by the ROM, is separate.')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, struct.error, zlib.error) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
PYDTBO
)

make_boot_image() (
    command -v python3 >/dev/null 2>&1 || die 'python3 is required.'

    local STOCK=$STOCK_BOOT_IMG
    local KERNEL="$OUT_DIR/arch/arm64/boot/Image"
    local OUTPUT="$OUT_DIR/boot.img"
    local WORK
    [[ -s $STOCK ]] || die "Missing working boot image: $STOCK"
    [[ -s $KERNEL ]] || die "Missing compiled kernel: $KERNEL"
    STOCK=$(realpath -- "$STOCK")
    KERNEL=$(realpath -- "$KERNEL")
    mkdir -p -- "$(dirname -- "$OUTPUT")"
    OUTPUT=$(realpath -m -- "$OUTPUT")
    [[ $OUTPUT != "$STOCK" && $OUTPUT != "$KERNEL" ]] || die 'Output must differ from both inputs.'
    [[ ! -d $OUTPUT ]] || die 'Output must be a filename, not a directory.'

    python3 - "$STOCK" "$KERNEL" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    if f.read(8) != b'ANDROID!':
        sys.exit('Error: template must be an Android boot.img.')
with open(sys.argv[2], 'rb') as f:
    header = f.read(64)
    if header[56:60] != b'ARM\x64':
        sys.exit('Error: use the raw ARM64 Image, not Image.gz or boot.img.')
PY

    WORK=$(mktemp -d "$(dirname -- "$OUTPUT")/.bootimg.XXXXXX")
    trap 'rm -rf -- "$WORK"' EXIT

    if [[ -n ${MAGISKBOOT:-} ]]; then
        MAGISKBOOT=$(command -v -- "$MAGISKBOOT") || die 'MAGISKBOOT executable not found.'
    elif [[ -x $ROOT/toolchain/magiskboot ]]; then
        MAGISKBOOT=$ROOT/toolchain/magiskboot
    elif command -v magiskboot >/dev/null 2>&1; then
        MAGISKBOOT=$(command -v magiskboot)
    else
        [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Automatic tool download requires Linux x86_64.'
        for tool in curl sha256sum; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing dependency: $tool"
        done
        printf 'Downloading the official Magisk boot-image tool...\n'
        curl --fail --location --retry 3 --connect-timeout 30 \
            https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk \
            -o "$WORK/Magisk.apk"
        printf '%s  %s\n' \
            89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7 \
            "$WORK/Magisk.apk" | sha256sum --check --status || die 'Magisk APK checksum mismatch.'
        python3 - "$WORK/Magisk.apk" "$WORK/magiskboot" <<'PY'
import pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as apk:
    binary = pathlib.Path(sys.argv[2])
    binary.write_bytes(apk.read('lib/x86_64/libmagiskboot.so'))
    binary.chmod(0o755)
PY
        mkdir -p -- "$ROOT/toolchain"
        mv -- "$WORK/magiskboot" "$ROOT/toolchain/magiskboot"
        MAGISKBOOT=$ROOT/toolchain/magiskboot
    fi
    MAGISKBOOT=$(realpath -- "$MAGISKBOOT")
    [[ -x $MAGISKBOOT ]] || die 'magiskboot must be executable.'

    mkdir -- "$WORK/unpacked"
    (
        cd -- "$WORK/unpacked"
        "$MAGISKBOOT" unpack -h "$STOCK"
        [[ -s kernel ]] || die 'Template has no kernel.'
        cp -- "$KERNEL" kernel
        "$MAGISKBOOT" repack "$STOCK" "$WORK/boot.img"
    )
    [[ -s $WORK/boot.img ]] || die 'Repacking did not produce boot.img.'
    mv -f -- "$WORK/boot.img" "$OUTPUT"
    printf '\nBoot image created: %s\n' "$OUTPUT"
)



if (( BOOTIMG_ONLY )); then
    make_boot_image
    exit 0
fi
if [[ $MODE == dtbo-only ]]; then
    pack_dtbo_image
    exit 0
fi

# The bundled DTC 1.4.4 cannot parse Raphael's external-node overlays.
DTC_EXT=${DTC_EXT:-$(command -v dtc || true)}
[[ -n $DTC_EXT ]] || die 'Install device-tree-compiler or set DTC_EXT=/path/to/modern/dtc.'
DTC_EXT=$(command -v -- "$DTC_EXT") || die 'DTC_EXT executable not found.'
DTC_EXT=$(realpath -- "$DTC_EXT")
printf '/dts-v1/; /plugin/; &external { status = "okay"; };\n' |
    "$DTC_EXT" -@ -I dts -O dtb -o /dev/null 2>/dev/null ||
    die 'DTC_EXT cannot parse external-node overlays; install a newer device-tree-compiler.'

download_toolchain() (
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Boolx Clang requires a Linux x86_64 host.'
    for tool in curl tar zstd sha256sum mktemp; do
        command -v "$tool" >/dev/null 2>&1 || die "Downloading requires $tool."
    done
    local url=https://github.com/onettboots/boolx-clang-build/releases/download/Boolx-22/boolx-clang22.tar.zst
    local checksum=5a5778d43b6f1f1531e8939213746b2b0b10d1445c3e0db84f5c24f29ce0a131
    local destination=$TOOLCHAIN staging
    [[ ! -e $destination ]] || die "Incomplete toolchain at $destination; move it aside and retry."
    mkdir -p -- "$(dirname -- "$destination")"
    staging=$(mktemp -d "${destination}.download.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    printf 'Downloading Boolx Clang 22 to %s...\n' "$destination"
    if ! curl --fail --location --retry 3 --connect-timeout 30 \
        "$url" -o "$staging/toolchain.tar.zst"; then
        die 'Boolx Clang download failed.'
    fi
    printf '%s  %s\n' "$checksum" "$staging/toolchain.tar.zst" |
        sha256sum --check --status || die 'Toolchain checksum verification failed.'
    mkdir -- "$staging/unpacked"
    # The release archive contains a top-level boolx-clang/ directory.
    if ! tar --zstd -xf "$staging/toolchain.tar.zst" \
        --strip-components=1 -C "$staging/unpacked"; then
        die 'Could not extract Boolx Clang.'
    fi
    [[ -x $staging/unpacked/bin/clang ]] || die 'Archive does not contain bin/clang.'
    mv -- "$staging/unpacked" "$destination"
)

if [[ ! -x $TOOLCHAIN/bin/clang && ! -x $TOOLCHAIN/clang ]]; then
    download_toolchain
fi

[[ -d $TOOLCHAIN/bin ]] && TOOLCHAIN=$TOOLCHAIN/bin
[[ -d $TOOLCHAIN ]] || die "Toolchain directory not found: $TOOLCHAIN"
TOOLCHAIN=$(cd -- "$TOOLCHAIN" && pwd -P)
export PATH="$TOOLCHAIN:$PATH"
for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip llvm-dis; do
    [[ -x $TOOLCHAIN/$tool ]] || die "Missing $TOOLCHAIN/$tool; use a complete LLVM 22 toolchain."
    version=$("$TOOLCHAIN/$tool" --version)
    [[ $version =~ version[[:space:]]+22\. || $version =~ LLD[[:space:]]+22\. ]] ||
        die "$tool must be version 22: ${version%%$'\n'*}"
done
for tool in make gcc g++ bc bison flex python3 perl pkg-config gzip; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing host dependency: $tool (see ./build.sh --help)."
done

setup_raphael_display() {
    # Port the published Bool-X 75/90 Hz modes, preserving each stock 60 Hz node.
    python3 - "$ROOT" "$OUT_DIR" <<'PYDISPLAY'
from pathlib import Path
import hashlib, json, os, re, subprocess, sys

root, output = map(Path, sys.argv[1:3])
revision = 'c19919d14a1d5adb8ad46994d9f592b9ebcd83dd'
upstream = 'https://raw.githubusercontent.com/onettboots/bool-x_xiaomi_raphael'
base = Path('arch/arm64/boot/dts/qcom')
cache = root / 'toolchain/raphael-display' / revision
files = json.loads(r'{"dsi-panel-ss-fhd-ea8076-cmd.dtsi":"a439279c6e09f6fb9a6a96a7e8a0e0e369a8c7fd569e39eff1e7d862e98f9d24","dsi-panel-ss-fhd-ea8076-global-cmd.dtsi":"f79308d4689680beb5251785961abed087b9803c366a64f3a2f6494e655b41dd","dsi-panel-samsung-fhd-ea8076-f1-cmd.dtsi":"6de244122327b1dd88b614211c954cbaef911bb5d7749b4072c0d6da60d03276","dsi-panel-samsung-fhd-ea8076-f1mp-cmd.dtsi":"5be52029f8dd5e3caf320069cc6b4bfda94332df06e17a6641d589375706e273","dsi-panel-samsung-fhd-ea8076-f1p2-cmd.dtsi":"8387a8a602287876e4c557d6bab8c914af0aadb44615dafefc1476635363e58f","dsi-panel-samsung-fhd-ea8076-f1p2-2-cmd.dtsi":"abf1ca3a6f2f2dba290da319f704dea73ed370e999ec79015ee7a89e4f5dabf8","sm8150-sde-display.dtsi":"27c8ea39b4af6c2d84cb0ebb1ecc3ec96d0b57ca6513cc95bbbd9709b5afe9ef"}')
native = json.loads(r'{"dsi-panel-ss-fhd-ea8076-cmd.dtsi":{"label":"dsi_ss_fhd_ea8076_cmd","timing0_sha256":"ee3887f4c95caa4642c8a9a8d1d66d6d4f83f1b4a1fdcfeb9dfcf948f69ddbcc","parent_timing0_sha256":"b09e617b217729713f828c7d6c38b9444207f4f319348c1638c1457ee65af47b"},"dsi-panel-ss-fhd-ea8076-global-cmd.dtsi":{"label":"dsi_ss_fhd_ea8076_global_cmd","timing0_sha256":"4a1bcba901f1b796060d43946456029c3e8d5f2e04c0c55cdaa1be87e4aed143","parent_timing0_sha256":"95e5ac597d76bfbb9b9a82b9ee6483c86bb7dbcdf5b94b9e6050f239e876703c"},"dsi-panel-samsung-fhd-ea8076-f1-cmd.dtsi":{"label":"dsi_samsung_fhd_ea8076_f1_cmd","timing0_sha256":"dd4a72246beb0088da5ddc22eb7f95e8c9ca075d84a4fef1b25ff8ab7e5113ed","parent_timing0_sha256":"17486cafe9543927d38de93c0a4682744781e7d5fd3fd8791c491aff35e83879"},"dsi-panel-samsung-fhd-ea8076-f1mp-cmd.dtsi":{"label":"dsi_samsung_fhd_ea8076_f1mp_cmd","timing0_sha256":"f3733aad45fa88d2d18a6df95811ba46ab75a3f32173269c177ed5f09b258450","parent_timing0_sha256":"17486cafe9543927d38de93c0a4682744781e7d5fd3fd8791c491aff35e83879"},"dsi-panel-samsung-fhd-ea8076-f1p2-cmd.dtsi":{"label":"dsi_samsung_fhd_ea8076_f1p2_cmd","timing0_sha256":"3fc1f7e6da5380d016f4a9281da9b1647714fd6b53c5f2ae11f04bab032008b5","parent_timing0_sha256":"69f58cec15d677f7b57ed09ba59794defa7f3c5806cd245ff76658dee9435b9c"},"dsi-panel-samsung-fhd-ea8076-f1p2-2-cmd.dtsi":{"label":"dsi_samsung_fhd_ea8076_f1p2_2_cmd","timing0_sha256":"c1ed7e6c4d1044545f5d1c1c5f75a371813f3821290a96fb5f6278638c5253f7","parent_timing0_sha256":"17486cafe9543927d38de93c0a4682744781e7d5fd3fd8791c491aff35e83879"}}')

def fail(message):
    sys.exit('Error: display setup: ' + message)

def node(text, pattern):
    matches = list(re.finditer(pattern, text, re.M))
    if len(matches) != 1:
        fail(f'expected exactly one node matching {pattern!r}')
    match = matches[0]
    opening = text.index('{', match.start())
    depth = 0
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[{}]', text[opening:], re.S):
        value = token.group()
        if value == '{':
            depth += 1
        elif value == '}':
            depth -= 1
            if depth == 0:
                end = opening + token.end()
                while end < len(text) and text[end] in '; \t':
                    end += 1
                if end < len(text) and text[end] == '\n':
                    end += 1
                return match.start(), end, text[match.start():end]
    fail('unbalanced node braces')

def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()

def properties(text):
    # Split only top-level DTS statements, keeping original command data.
    opening = text.index('{')
    depth, start, result = 1, opening + 1, {}
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[{};]', text[opening + 1:], re.S):
        value = token.group()
        if value == '{':
            depth += 1
        elif value == '}':
            depth -= 1
        elif value == ';' and depth == 1:
            end = opening + 1 + token.end()
            statement = text[start:end]
            uncommented = re.sub(r'/\*.*?\*/|//[^\n]*', '', statement, flags=re.S)
            match = re.match(r'\s*(qcom,[A-Za-z0-9_,.-]+)(?:\s|=|;)', uncommented)
            if match:
                result[match[1]] = statement
            start = end
    return result

sources = {}
cache.mkdir(parents=True, exist_ok=True)
for name, expected in files.items():
    path = cache / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        temporary = cache / (name + f'.download-{os.getpid()}')
        url = f'{upstream}/{revision}/{base.as_posix()}/{name}'
        print(f'Downloading pinned Bool-X display source: {name}', flush=True)
        try:
            subprocess.run(['curl', '--fail', '--location', '--retry', '3',
                            '--connect-timeout', '30', '--max-time', '120',
                            url, '-o', str(temporary)], check=True)
            data = temporary.read_bytes()
            if hashlib.sha256(data).hexdigest() != expected:
                fail(f'checksum mismatch for {name}')
            temporary.replace(path)
        finally:
            if temporary.exists():
                temporary.unlink()
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        fail(f'cached checksum mismatch for {name}')
    sources[name] = data.decode()

# Resolve all source edits first. Unknown local modes/timings abort before writing.
central_path = root / base / 'sm8150-sde-display.dtsi'
central_original = central_path.read_text()
central = central_original
changes = {}
marker = '/* Bool-X 75/90 Hz modes; Copyright (C) 2021 XiaoMi, Inc.; GPL-2.0. */'
retained = {}
for name, expected in native.items():
    path = root / base / name
    original = path.read_text()
    native60 = node(original, r'^\t{3}timing@0\s*\{')[2]
    if digest(native60) != expected['timing0_sha256']:
        fail(f'{name}: stock 60 Hz timing differs from branch 17')
    if 'qcom,mdss-dsi-panel-type = "dsi_cmd_mode";' not in original:
        fail(f'{name}: expected a command-mode panel')
    for lane in range(4):
        if f'qcom,mdss-dsi-lane-{lane}-state;' not in original:
            fail(f'{name}: expected four data lanes')
    if 'qcom,mdss-dsi-bpp = <24>;' not in original:
        fail(f'{name}: expected 24 bpp')
    stock_properties = properties(native60)
    modes = []
    for index, rate, clock, transfer in ((1, 75, 1375000000, 11027),
                                       (3, 90, 1650000000, 9189)):
        mode = node(sources[name], rf'^\t{{3}}timing@{index}\s*\{{')[2]
        required = (f'qcom,mdss-dsi-panel-framerate = <{rate}>;',
                    f'qcom,mdss-dsi-panel-clockrate = <{clock}>;',
                    'qcom,mdss-dsi-on-command = [',
                    'qcom,mdss-dsi-off-command = [')
        if not all(value in mode for value in required):
            fail(f'{name}: pinned {rate} Hz mode has unexpected contents')
        # Same non-DSC four-lane transfer budget as the source driver's formula.
        minimum_bitclock = 1080 * 2340 * rate * 24 // 4
        if (1000000 // rate) * minimum_bitclock // clock != transfer:
            fail(f'{name}: inconsistent {rate} Hz transfer budget')
        if 'qcom,mdss-mdp-transfer-time-us' in mode:
            fail(f'{name}: pinned mode already has a transfer budget')
        # Keep branch-17 feature commands absent from the newer MIUI tables.
        # Existing upstream DDIC programming is never overwritten.
        missing = sorted(set(stock_properties) - set(properties(mode)))
        retained[name] = missing
        if missing:
            closing = mode.rfind('}')
            line_start = mode.rfind('\n', 0, closing) + 1
            mode = (mode[:line_start] + ''.join(stock_properties[p] for p in missing)
                    + '\n' + mode[line_start:])
        opening = mode.index('{') + 1
        extra = (f'\n\t\t\t\tqcom,mdss-mdp-transfer-time-us = <{transfer}>;'
                 '\n\t\t\t\tqcom,mdss-dsi-transfer-time-pclk;')
        modes.append(mode[:opening] + extra + mode[opening:])
    suffix = '\t\t};\n\t};\n};\n'
    addition = '\t\t\t' + marker + '\n' + ''.join(modes)
    mode_ids = re.findall(r'^\t{3}timing@(\d+)\s*\{', original, re.M)
    if marker in original:
        if mode_ids != ['0', '1', '3'] or original.count(addition + suffix) != 1:
            fail(f'{name}: installed display modes were modified')
        updated = original
    else:
        if mode_ids != ['0'] or original.count(suffix) != 1:
            fail(f'{name}: unexpected existing display modes or layout')
        updated = original.replace(suffix, addition + suffix, 1)
    preference = 'qcom,mdss-dsi-preferred-refresh-rate = <75>;'
    panel_type = '\t\tqcom,mdss-dsi-panel-type = "dsi_cmd_mode";'
    if preference not in updated:
        if 'qcom,mdss-dsi-preferred-refresh-rate' in updated or updated.count(panel_type) != 1:
            fail(f'{name}: unexpected preferred refresh rate or panel layout')
        updated = updated.replace(panel_type, panel_type + '\n\t\t' + preference, 1)
    if node(updated, r'^\t{3}timing@0\s*\{')[2] != native60:
        fail(f'{name}: stock timing preservation failed')
    changes[path] = (original, updated)

    label = expected['label']
    start, end, parent = node(central, rf'^&{label}\s*\{{')
    original_parent60 = node(parent, r'^\t{2}timing@0\s*\{')[2]
    if digest(original_parent60) != expected['parent_timing0_sha256']:
        fail(f'{label}: stock PHY settings differ from branch 17')
    upstream_parent = node(sources['sm8150-sde-display.dtsi'], rf'^&{label}\s*\{{')[2]
    phy_modes = ''.join(node(upstream_parent, rf'^\t{{2}}timing@{i}\s*\{{')[2]
                        for i in (1, 3))
    parent_suffix = '\t};\n};\n'
    ids = re.findall(r'^\t{2}timing@(\d+)\s*\{', parent, re.M)
    if ids == ['0'] and parent.count(parent_suffix) == 1:
        updated_parent = parent.replace(parent_suffix, phy_modes + parent_suffix, 1)
    elif ids == ['0', '1', '3'] and parent.count(phy_modes + parent_suffix) == 1:
        updated_parent = parent
    else:
        fail(f'{label}: existing high-rate PHY settings differ')
    central = central[:start] + updated_parent + central[end:]
changes[central_path] = (central_original, central)

# The parent script embeds the reviewed driver edits here before writing changes.
driver_edits = json.loads(r'''{"drivers/gpu/drm/msm/dsi-staging/dsi_panel.c":[["\ttiming = &mode->timing;\n\n\tif (panel_mode == DSI_OP_CMD_MODE) {\n","\ttiming = &mode->timing;\n\n\t/* Opt-in timings derive the command-mode pixel clock from the transfer\n\t * budget directly. Dividing by transfer time before multiplication would\n\t * truncate to a whole Hz and undershoot the matching DSI link clock.\n\t * Existing timings keep the original calculation below.\n\t */\n\tif (utils->read_bool(utils->data,\n\t\t\t\"qcom,mdss-dsi-transfer-time-pclk\")) {\n\t\tif (panel_mode != DSI_OP_CMD_MODE || timing->dsc_enabled ||\n\t\t    !timing->refresh_rate || !timing->clk_rate_hz ||\n\t\t    !priv_info->mdp_transfer_time_us ||\n\t\t    priv_info->mdp_transfer_time_us >=\n\t\t\tTICKS_IN_MICRO_SECOND / timing->refresh_rate) {\n\t\t\tpr_err(\"invalid clock-derived command-mode transfer budget\\n\");\n\t\t\treturn -EINVAL;\n\t\t}\n\t\tpixel_clk_khz = (u64)DSI_H_ACTIVE_DSC(timing) *\n\t\t\ttiming->v_active * 1000;\n\t\tdo_div(pixel_clk_khz, priv_info->mdp_transfer_time_us);\n\t\tmode->pixel_clk_khz = pixel_clk_khz;\n\t\treturn 0;\n\t}\n\n\tif (panel_mode == DSI_OP_CMD_MODE) {\n"]],"drivers/gpu/drm/msm/dsi-staging/dsi_drm.c":[["\t\t/* No DMS/VRR when drm pipeline is changing */\n\t\tif (!drm_mode_equal(&cur_mode, adjusted_mode) &&\n","\t\t/* Without panel timing-switch commands, use a complete modeset so\n\t\t * the destination mode's full on/off command sequences are sent.\n\t\t * No DMS/VRR when the DRM pipeline is changing.\n\t\t */\n\t\tif (display->panel->dms_mode != DSI_DMS_MODE_DISABLED &&\n\t\t\t!drm_mode_equal(&cur_mode, adjusted_mode) &&\n"],["static void dsi_drm_update_dtd(struct edid *edid,\n\t\tstruct dsi_display_mode *modes, u32 modes_count)\n","static void dsi_drm_update_dtd(struct edid *edid,\n\t\tstruct dsi_display_mode *modes, u32 modes_count,\n\t\tu32 preferred_index, bool nominal_preferred)\n"],["\t\tstruct dsi_display_mode *mode = &modes[i];\n\t\tstruct dsi_mode_info *timing = &mode->timing;\n","\t\tu32 mode_index = i == 0 ? preferred_index :\n\t\t\t(i <= preferred_index ? i - 1 : i);\n\t\tstruct dsi_display_mode *mode = &modes[mode_index];\n\t\tstruct dsi_mode_info *timing = &mode->timing;\n"],["\t\tdtd->pixel_clock = mode->pixel_clk_khz / 10;\n","\t\t/* A command-mode transfer clock is not its nominal scan clock. */\n\t\tif (i == 0 && nominal_preferred)\n\t\t\tdtd->pixel_clock = div_u64((u64)(timing->h_active + h_blank) *\n\t\t\t\t(timing->v_active + v_blank) * timing->refresh_rate +\n\t\t\t\t5000, 10000);\n\t\telse\n\t\t\tdtd->pixel_clock = mode->pixel_clk_khz / 10;\n"],["\tu32 count = 0, edid_size;\n\tstruct dsi_display_mode *modes = NULL;\n","\tu32 count = 0, edid_size, preferred_index = 0, preferred_rate = 0;\n\tbool nominal_preferred = false;\n\tstruct dsi_display_mode *modes = NULL;\n"],["\tfor (i = 0; i < count; i++) {\n\t\tstruct drm_display_mode *m;\n","\t/* Keep source mode order and bootloader timing indices unchanged. */\n\tif (display->panel &&\n\t    !display->panel->utils.read_u32(display->panel->utils.data,\n\t\t\t\"qcom,mdss-dsi-preferred-refresh-rate\",\n\t\t\t&preferred_rate)) {\n\t\tfor (i = 0; i < count; i++) {\n\t\t\tif (modes[i].timing.refresh_rate == preferred_rate) {\n\t\t\t\tpreferred_index = i;\n\t\t\t\tnominal_preferred = true;\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}\n\t}\n\n\tfor (i = 0; i < count; i++) {\n\t\tstruct drm_display_mode *m;\n"],["\t\t/* set the first mode in list as preferred */\n\t\tif (i == 0)\n","\t\t/* Prefer the requested rate, or the first mode if unspecified. */\n\t\tif (i == preferred_index)\n"],["\tdsi_drm_update_dtd(&edid, modes, count);\n","\tdsi_drm_update_dtd(&edid, modes, count, preferred_index, nominal_preferred);\n"]],"Documentation/devicetree/bindings/drm/msm/mdss-dsi-panel.txt":[["- qcom,mdss-dsi-on-command-state:","- qcom,mdss-dsi-transfer-time-pclk: Boolean on a command-mode timing node.\n\t\t\t\t\tCalculate pixel clock directly from active pixels and\n\t\t\t\t\tqcom,mdss-mdp-transfer-time-us, avoiding whole-Hz\n\t\t\t\t\ttruncation. Requires an explicit nonzero panel clock,\n\t\t\t\t\ta positive transfer time shorter than one frame,\n\t\t\t\t\tand an uncompressed command-mode timing.\n\t\t\t\t\tAbsent: retain the existing pixel-clock calculation.\n- qcom,mdss-dsi-on-command-state:"],["- qcom,mdss-dsi-transfer-time-pclk: Boolean on a command-mode timing node.\n","- qcom,mdss-dsi-preferred-refresh-rate: Preferred display mode refresh rate, in Hz.\n\t\t\t\t\tIf unavailable, the first timing remains preferred.\n- qcom,mdss-dsi-transfer-time-pclk: Boolean on a command-mode timing node.\n"]],"drivers/gpu/drm/msm/sde/sde_encoder.c":[["void sde_encoder_kickoff(struct drm_encoder *drm_enc, bool is_error)\n{\n\tstruct sde_encoder_virt *sde_enc;\n","void sde_encoder_kickoff(struct drm_encoder *drm_enc, bool is_error)\n{\n\tstatic bool first_primary_dsi_kickoff = true;\n\tstruct sde_encoder_virt *sde_enc;\n"],["\t/* allow phys encs to handle any post-kickoff business */\n\tfor (i = 0; i < sde_enc->num_phys_encs; i++) {\n\t\tphys = sde_enc->phys_encs[i];\n\t\tif (phys && phys->ops.handle_post_kickoff)\n\t\t\tphys->ops.handle_post_kickoff(phys);\n\t}\n\n\tif (sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n","\t/* allow phys encs to handle any post-kickoff business */\n\tfor (i = 0; i < sde_enc->num_phys_encs; i++) {\n\t\tphys = sde_enc->phys_encs[i];\n\t\tif (phys && phys->ops.handle_post_kickoff)\n\t\t\tphys->ops.handle_post_kickoff(phys);\n\t}\n\n\t/* The bootloader initializes the panel at 60 Hz. If userspace selects a\n\t * different mode for the first continuous-splash frame, request one\n\t * existing ESD-recovery cycle to send that mode's complete on sequence.\n\t * Consume the flag only for a valid primary DSI kickoff; a normal 60 Hz\n\t * boot does not reset, and DisplayPort/secondary kickoffs cannot claim it.\n\t */\n\tif (!is_error && sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n\t\t\tsde_enc->disp_info.is_primary && sde_enc->crtc &&\n\t\t\tsde_enc->cur_master && sde_enc->cur_master->connector &&\n\t\t\tcmpxchg(&first_primary_dsi_kickoff, true, false) &&\n\t\t\tsde_enc->crtc->mode.vrefresh != 60) {\n\t\tstruct sde_connector *conn = container_of(\n\t\t\tsde_enc->cur_master->connector, struct sde_connector, base);\n\t\tstruct drm_event event = {\n\t\t\t.type = DRM_EVENT_PANEL_DEAD,\n\t\t\t.length = sizeof(bool),\n\t\t};\n\n\t\tif (!conn->panel_dead) {\n\t\t\tconn->panel_dead = true;\n\t\t\tmsm_mode_object_event_notify(&conn->base.base,\n\t\t\t\tconn->base.dev, &event, (u8 *)&conn->panel_dead);\n\t\t}\n\t}\n\n\tif (sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n"],["\tdrm_set_preferred_mode(conn, drm_mode->hdisplay, drm_mode->vdisplay);\n","\t/* Keep an explicit 75 Hz DSI preference instead of marking all modes\n\t * with the same resolution preferred during continuous splash.\n\t */\n\tif (sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n\t    sde_enc->disp_info.is_primary) {\n\t\tstruct drm_display_mode *candidate;\n\t\tbool has_preferred_75 = false;\n\n\t\tlist_for_each_entry(candidate, &conn->probed_modes, head) {\n\t\t\tif (candidate->vrefresh == 75 &&\n\t\t\t    (candidate->type & DRM_MODE_TYPE_PREFERRED)) {\n\t\t\t\thas_preferred_75 = true;\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}\n\t\tif (!has_preferred_75)\n\t\t\tdrm_set_preferred_mode(conn, drm_mode->hdisplay,\n\t\t\t\t\tdrm_mode->vdisplay);\n\t} else {\n\t\tdrm_set_preferred_mode(conn, drm_mode->hdisplay, drm_mode->vdisplay);\n\t}\n"]]}''')
for name, replacements in driver_edits.items():
    path = root / name
    is_binding_doc = name == 'Documentation/devicetree/bindings/drm/msm/mdss-dsi-panel.txt'
    if is_binding_doc and not path.is_file():
        print(f'Display binding documentation not found; leaving it unchanged: {name}')
        continue
    original = path.read_text()
    updated = original
    for old, new in replacements:
        if new in updated:
            continue
        if updated.count(old) != 1:
            if is_binding_doc:
                print(f'Display binding documentation differs; leaving it unchanged: {name}')
                updated = original
                break
            fail(f'{name}: cannot apply reviewed display-driver edit')
        updated = updated.replace(old, new, 1)
    changes[path] = (original, updated)


for path, (original, updated) in changes.items():
    if original != updated:
        path.write_text(updated)
output.mkdir(parents=True, exist_ok=True)
report = output / 'display-modes.txt'
report.write_text(
    'Raphael EA8076 display source modes: 60, 75, 90 Hz\n'
    '75 Hz is the preferred mode; native 60 Hz timing and PHY settings remain available.\n'
    f'Bool-X source revision: {revision}\n'
    '75/90 Hz use published DDIC/clock/PHY data plus explicit transfer budgets.\n'
    '120 Hz is not implemented by this source and has not been added.\n'
    'This report verifies source setup, not panel refresh or stability on a phone.\n'
    'Deployment requires the matching rebuilt kernel and Raphael DTBO.\n')
with report.open('a') as stream:
    for name, options in retained.items():
        stream.write(f'{name}: retained stock-only commands: {", ".join(options)}\n')
print('Raphael display source modes prepared: 60/75/90 Hz (75 Hz preferred).')
print(f'Display source report: {report}')
PYDISPLAY
}

setup_raphael_display

setup_rtl88x2bu() (
    local driver="$ROOT/drivers/net/wireless/realtek/rtl88x2bu"
    local revision=465ae7cb522a382adc85ea5c31f228af8d172148
    local checksum=2fb1915e3711912101cd1b8924fdec944900fcebaec45d62624e11b63b92a76d
    local staging
    if [[ ! -f $driver/Makefile ]]; then
        [[ ! -e $driver ]] || die "Incomplete driver directory: $driver"
        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 || die "Driver setup requires $tool."
        done
        staging=$(mktemp -d "$ROOT/.rtl88x2bu.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT
        printf 'Downloading RTL8812BU/RTL8822BU driver for Archer T3U Plus...\n'
        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/RinCat/RTL88x2BU-Linux-Driver/tar.gz/$revision" \
            -o "$staging/driver.tar.gz"
        printf '%s  %s\n' "$checksum" "$staging/driver.tar.gz" |
            sha256sum --check --status || die 'Driver archive checksum mismatch.'
        mkdir -- "$staging/source"
        tar -xzf "$staging/driver.tar.gz" --strip-components=1 -C "$staging/source"
        mkdir -p -- "$(dirname -- "$driver")"
        mv -- "$staging/source" "$driver"
    fi
    python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
driver = root / 'drivers/net/wireless/realtek/rtl88x2bu'

# Keep these edits idempotent and refuse unexpected driver source changes.
def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        sys.exit(f'Error: unexpected source contents in {path}; check the pinned driver version.')
    path.write_text(text.replace(old, new, 1))

replace_once(driver / 'Makefile',
    'CONFIG_PLATFORM_I386_PC = y', 'CONFIG_PLATFORM_I386_PC = n')
replace_once(driver / 'Makefile',
    'CONFIG_RTW_LOG_LEVEL = 3', 'CONFIG_RTW_LOG_LEVEL = 4')
replace_once(driver / 'Makefile',
    'ccflags-y += $(USER_EXTRA_CFLAGS)\n',
    'ccflags-y += $(USER_EXTRA_CFLAGS)\n'
    "# Built-in ARM64 kernel integration; use the parent kernel's architecture/tools.\n"
    'ccflags-y += -DCONFIG_LITTLE_ENDIAN\n'
    'ccflags-y += -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT\n')

# This small Kconfig belongs to the pinned imported driver.
(driver / 'Kconfig').write_text('''config RTL8822BU
\ttristate "Realtek RTL8812BU/RTL8822BU USB WiFi"
\tdepends on USB && CFG80211
\tselect CFG80211_WEXT
\tselect WEXT_PRIV
\thelp
\t  Support Realtek RTL8812BU and RTL8822BU USB wireless adapters,
\t  including TP-Link Archer T3U Plus (USB ID 2357:0138).
''')
parent = driver.parent
path = parent / 'Kconfig'
text = path.read_text()
include = 'source "drivers/net/wireless/realtek/rtl88x2bu/Kconfig"'
if include not in text:
    marker = 'endif # WLAN_VENDOR_REALTEK'
    if marker not in text:
        sys.exit('Error: unexpected Realtek Kconfig layout.')
    path.write_text(text.replace(marker, include + '\n\n' + marker))
path = parent / 'Makefile'
text = path.read_text()
if 'obj-$(CONFIG_RTL8822BU)' not in text:
    path.write_text(text.rstrip() + '\nobj-$(CONFIG_RTL8822BU) += rtl88x2bu/\n')
path = root / 'arch/arm64/configs/raphael_defconfig'
text = path.read_text()
for option in ('CFG80211_WEXT', 'WLAN_VENDOR_REALTEK', 'RTL8822BU'):
    pattern = rf'^(?:CONFIG_{option}=.*|# CONFIG_{option} is not set)$'
    line = f'CONFIG_{option}=y'
    if re.search(pattern, text, re.M):
        text = re.sub(pattern, line, text, flags=re.M)
    else:
        text = text.rstrip() + '\n' + line + '\n'
path.write_text(text)

# Consume all llvm-nm output to avoid LLVM 22 broken-pipe messages.
path = root / 'scripts/Makefile.build'
text = path.read_text()
path.write_text(text.replace('| grep -q __ksymtab;', '| grep __ksymtab >/dev/null;'))
(driver / 'RAPHAEL_UPSTREAM').write_text(
    'https://github.com/RinCat/RTL88x2BU-Linux-Driver\n'
    '465ae7cb522a382adc85ea5c31f228af8d172148\n')
PY
)

setup_rtl88x2bu

setup_kernelsu_next() (
    local source="$ROOT/KernelSU-Next"
    local revision=b933b1f728116a456fbebf27b6a8772a640cdf23
    local checksum=e68647c65d416245e2e6ca1c86b84ffc4bb5736a8947ce73946902ae9b8586c6
    local staging backup
    if [[ ! -f $source/RAPHAEL_UPSTREAM ]] ||
       ! grep -qx "$revision" "$source/RAPHAEL_UPSTREAM"; then
        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 || die "KernelSU-Next setup requires $tool."
        done
        staging=$(mktemp -d "$ROOT/.ksunext.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT
        printf 'Downloading official KernelSU-Next legacy for Linux 4.14...\n'
        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/KernelSU-Next/KernelSU-Next/tar.gz/$revision" \
            -o "$staging/source.tar.gz"
        printf '%s  %s\n' "$checksum" "$staging/source.tar.gz" |
            sha256sum --check --status || die 'KernelSU-Next legacy source checksum mismatch.'
        mkdir -- "$staging/source"
        tar -xzf "$staging/source.tar.gz" --strip-components=1 -C "$staging/source"
        if [[ -e $source ]]; then
            backup="$ROOT/KernelSU-Next.backup-$(date -u +%Y%m%dT%H%M%S)-$$"
            mv -- "$source" "$backup"
            printf 'Previous source preserved at %s\n' "$backup"
        fi
        mv -- "$staging/source" "$source"
    fi
    python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, re, sys
root = Path(sys.argv[1])
# Manual hooks and any 4.14 compatibility edits are pinned to this source tree.
replacements = json.loads(r'''{
    "drivers/input/input.c": [
        [
            "#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n",
            "#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n"
        ],
        [
            "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition = input_get_disposition(dev, type, code, &value);\n\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n",
            "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\tdisposition = input_get_disposition(dev, type, code, &value);\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n"
        ]
    ],
    "fs/exec.c": [
        [
            " */\n\n#include <linux/slab.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n",
            " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n"
        ],
        [
            "\tstruct files_struct *displaced;\n\tint retval;\n\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n",
            "\tstruct files_struct *displaced;\n\tint retval;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t/* execve_file() may provide a file without a filename. */\n\tif (filename && !IS_ERR(filename))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n"
        ]
    ],
    "fs/open.c": [
        [
            " */\n\n#include <linux/string.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n",
            " */\n\n#include <linux/string.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n"
        ],
        [
            "\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n",
            "\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n"
        ]
    ],
    "fs/stat.c": [
        [
            " *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n",
            " *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n"
        ],
        [
            "\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n",
            "\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n"
        ],
        [
            "\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n",
            "\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n"
        ],
        [
            "\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n",
            "\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n"
        ]
    ],
    "fs/read_write.c": [
        [
            " */\n\n#include <linux/slab.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n",
            " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n"
        ],
        [
            "\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f = fdget_pos(fd);\n\tssize_t ret = -EBADF;\n\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n",
            "\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f;\n\tssize_t ret = -EBADF;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd);\n#endif\n\tf = fdget_pos(fd);\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n"
        ]
    ],
    "kernel/reboot.c": [
        [
            "#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n",
            "#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n"
        ],
        [
            "\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n",
            "\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n"
        ]
    ],
    "fs/namespace.c": [
        [
            "\n#endif\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n",
            "\n#endif\n\nstatic int can_umount(const struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))\n\t\t return -EINVAL;\n\t if (!may_mount())\n\t\t return -EPERM;\n\t if (path->dentry != path->mnt->mnt_root)\n\t\t return -EINVAL;\n\t if (!check_mnt(mnt))\n\t\t return -EINVAL;\n\t if (mnt->mnt.mnt_flags & MNT_LOCKED)\n\t\t return -EINVAL;\n\t if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))\n\t\t return -EPERM;\n\t return 0;\n }\n\nint path_umount(struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t int ret;\n\t ret = can_umount(path, flags);\n\t if (!ret)\n\t\t ret = do_umount(mnt, flags);\n\t dput(path->dentry);\n\t mntput_no_expire(mnt);\n\t return ret;\n }\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n"
        ]
    ],
    "fs/internal.h": [
        [
            "extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n",
            "extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\nint path_umount(struct path *path, int flags);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n"
        ]
    ],
    "include/linux/seccomp.h": [
        [
            "#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n",
            "#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <linux/atomic.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n"
        ],
        [
            " */\nstruct seccomp {\n\tint mode;\n\tstruct seccomp_filter *filter;\n};\n\n",
            " */\nstruct seccomp {\n\tint mode;\n\tatomic_t filter_count;\n\tstruct seccomp_filter *filter;\n};\n\n"
        ]
    ],
    "KernelSU-Next/kernel/Kbuild": [
        [
            "# If there is no .git directory, use default version\n$(warning \"KSU_GIT_VERSION not defined! It is better to make KernelSU-Next a git repository!\")\nKSU_VERSION_FALLBACK := 1\n$(info -- KernelSU-Next version fallback: $(KSU_VERSION_FALLBACK))\nKSU_VERSION := $(KSU_VERSION_FALLBACK)\n",
            "# An archive can supply an explicit version without Git metadata.\nifndef KSU_VERSION_OVERRIDE\n$(warning \"KSU_GIT_VERSION not defined! It is better to make KernelSU-Next a git repository!\")\nKSU_VERSION_FALLBACK := 1\n$(info -- KernelSU-Next version fallback: $(KSU_VERSION_FALLBACK))\nKSU_VERSION := $(KSU_VERSION_FALLBACK)\nendif\n"
        ],
        [
            "$(warning \"KSU_VERSION_TAG not defined! It is better to make KernelSU-Next a git submodule!\")\nKSU_VERSION_TAG_FALLBACK := v0.0.1\nKSU_VERSION_TAG=$(KSU_VERSION_TAG_FALLBACK)\n",
            "ifndef KSU_VERSION_TAG_OVERRIDE\n$(warning \"KSU_VERSION_TAG not defined! It is better to make KernelSU-Next a git submodule!\")\nKSU_VERSION_TAG_FALLBACK := v0.0.1\nKSU_VERSION_TAG=$(KSU_VERSION_TAG_FALLBACK)\nendif\n"
        ],
        [
            "ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n",
            "ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Detect Android/vendor kernels that backported __poll_t before 4.16.\nifeq ($(shell grep -Eq \"typedef.*__poll_t\" $(srctree)/include/uapi/linux/types.h $(srctree)/include/linux/types.h; echo $$?),0)\nccflags-y += -DKSU_HAS_POLL_T\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n"
        ]
    ],
    "KernelSU-Next/kernel/infra/event_queue.h": [
        [
            "#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0)\ntypedef unsigned int __poll_t;\n#endif\n\n",
            "#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0) && !defined(KSU_HAS_POLL_T)\ntypedef unsigned int __poll_t;\n#endif\n\n"
        ]
    ],
    "KernelSU-Next/kernel/feature/sucompat.c": [
        [
            "\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\tconst char *const *sucompat_argv = (const char *const *)__never_use_argv;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n",
            "\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n"
        ],
        [
            "\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, sucompat_argv, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n",
            "\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\t/* argv is a struct user_arg_ptr, not an array of kernel strings. */\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, NULL, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n"
        ]
    ],
    "include/linux/ksu_manual_hooks.h": [
        [
            "",
            "/* SPDX-License-Identifier: GPL-2.0 */\n#ifndef _LINUX_KSU_MANUAL_HOOKS_H\n#define _LINUX_KSU_MANUAL_HOOKS_H\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n#include <linux/compiler.h>\n#include <linux/types.h>\n\nstruct filename;\nstruct stat;\nstruct stat64;\nextern bool ksu_su_compat_enabled;\nextern bool ksu_init_rc_hook;\nextern bool ksu_input_hook;\n\nint ksu_handle_execveat(int *fd, struct filename **filename, void *argv,\n\t\t       void *envp, int *flags);\nint ksu_handle_faccessat(int *dfd, const char __user **filename, int *mode,\n\t\t       int *flags);\nint ksu_handle_stat(int *dfd, const char __user **filename, int *flags);\nvoid ksu_handle_sys_read(unsigned int fd);\nvoid ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf);\nvoid ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf);\nint ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,\n\t\t\t\t int *value);\nint ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n\t\t\t void __user **arg);\n#endif\n\n#endif /* _LINUX_KSU_MANUAL_HOOKS_H */\n"
        ]
    ],
    "KernelSU-Next/kernel/supercall/dispatch.c": [
        [
            "static int do_get_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n    uid_t uid;\n    struct app_profile *profile;\n    int ret = 0;\n\n    if (copy_from_user(&uid, (char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile.curr_uid),\n                       sizeof(uid_t))) {\n        pr_err(\"get_app_profile: copy_from_user failed\\n\");\n        return -EFAULT;\n    }\n\n    rcu_read_lock();\n    profile = ksu_get_app_profile(uid);\n    rcu_read_unlock();\n    if (!profile) {\n        ret = -ENOENT;\n    } else {\n        if (copy_to_user((char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile), profile,\n                         sizeof(struct app_profile))) {\n            pr_err(\"get_app_profile: copy_to_user failed\\n\");\n            ret = -EFAULT;\n        }\n        ksu_put_app_profile(profile);\n    }\n    return ret;\n}\n\nstatic int do_set_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n\n    struct ksu_set_app_profile_cmd cmd;\n    int ret;\n\n\tif (copy_from_user(&cmd, arg, sizeof(cmd))) {\n\t\tpr_err(\"set_app_profile: copy_from_user failed\\n\");\n\t\treturn -EFAULT;\n\t}\n\n    ret = ksu_set_app_profile(&cmd.profile);\n    if (!ret) {\n        ksu_persistent_allow_list();\n#ifdef KSU_KPROBES_HOOK\n        ksu_mark_running_process();\n#endif\n    }\n    return ret;\n}\n\n",
            "/* Manager v3.2 uses profile format 3, the same ABI prefix without flags.\n * Do not copy a v4-sized object to or from that smaller userspace buffer.\n */\n#define KSU_APP_PROFILE_V3_SIZE offsetof(struct app_profile, rp_config.profile.flags)\n\nstatic int do_get_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n    uid_t uid;\n    __u32 requested_version;\n    struct app_profile *profile;\n    int ret = 0;\n\n    if (copy_from_user(&requested_version, (char __user *)arg +\n                       offsetof(struct ksu_get_app_profile_cmd, profile.version),\n                       sizeof(requested_version)) ||\n        copy_from_user(&uid, (char __user *)arg +\n                       offsetof(struct ksu_get_app_profile_cmd, profile.curr_uid),\n                       sizeof(uid))) {\n        pr_err(\"get_app_profile: copy_from_user failed\\n\");\n        return -EFAULT;\n    }\n\n    rcu_read_lock();\n    profile = ksu_get_app_profile(uid);\n    rcu_read_unlock();\n    if (!profile) {\n        ret = -ENOENT;\n    } else {\n        if (requested_version == 3) {\n            struct app_profile legacy = *profile;\n\n            legacy.version = 3;\n            if (copy_to_user((char __user *)arg +\n                             offsetof(struct ksu_get_app_profile_cmd, profile),\n                             &legacy, KSU_APP_PROFILE_V3_SIZE))\n                ret = -EFAULT;\n        } else if (copy_to_user((char __user *)arg +\n                                offsetof(struct ksu_get_app_profile_cmd, profile),\n                                profile, sizeof(struct app_profile))) {\n            ret = -EFAULT;\n        }\n        if (ret)\n            pr_err(\"get_app_profile: copy_to_user failed\\n\");\n        ksu_put_app_profile(profile);\n    }\n    return ret;\n}\n\nstatic int do_set_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n    struct ksu_set_app_profile_cmd cmd = {};\n    __u32 requested_version;\n    size_t copy_size;\n    int ret;\n\n    if (copy_from_user(&requested_version, (char __user *)arg +\n                       offsetof(struct ksu_set_app_profile_cmd, profile.version),\n                       sizeof(requested_version))) {\n        pr_err(\"set_app_profile: copy_from_user version failed\\n\");\n        return -EFAULT;\n    }\n    copy_size = requested_version == 3 ? KSU_APP_PROFILE_V3_SIZE : sizeof(cmd);\n    if (copy_from_user(&cmd, arg, copy_size)) {\n        pr_err(\"set_app_profile: copy_from_user failed\\n\");\n        return -EFAULT;\n    }\n    if (cmd.profile.version != requested_version)\n        return -EINVAL;\n    if (requested_version == 3) {\n        cmd.profile.version = KSU_APP_PROFILE_VER;\n        /* Match the kernel's existing v3 on-disk migration semantics. */\n        if (cmd.profile.allow_su)\n            cmd.profile.rp_config.profile.flags = FLAG_KSU_NO_NEW_PRIVS;\n    }\n\n    ret = ksu_set_app_profile(&cmd.profile);\n    if (!ret) {\n        ksu_persistent_allow_list();\n#ifdef KSU_KPROBES_HOOK\n        ksu_mark_running_process();\n#endif\n    }\n    return ret;\n}\n\n"
        ]
    ]
}''')
for name, changes in replacements.items():
    path = root / name
    text = path.read_text() if path.exists() else ''
    original = text
    for old, new in changes:
        if new in text:
            continue
        if old == '' and text == '':
            text = new
        elif old and text.count(old) == 1:
            text = text.replace(old, new, 1)
        else:
            sys.exit(f'Error: cannot apply KernelSU-Next integration to {name}; source tree differs.')
    if text != original:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

link = root / 'drivers/kernelsu'
if link.is_symlink():
    resolved = link.resolve()
    if resolved == (root / 'KernelSU/kernel').resolve():
        link.unlink()
        link.symlink_to('../KernelSU-Next/kernel', target_is_directory=True)
    elif resolved != (root / 'KernelSU-Next/kernel').resolve():
        sys.exit('Error: another KernelSU integration already occupies drivers/kernelsu.')
elif link.exists():
    sys.exit('Error: drivers/kernelsu already exists; refusing to replace it.')
else:
    link.symlink_to('../KernelSU-Next/kernel', target_is_directory=True)
path = root / 'drivers/Makefile'
text = path.read_text()
if 'obj-$(CONFIG_KSU)' not in text:
    # Match the tested tree's built-in initialization order.
    marker = re.search(r'^obj-y[ \t]+\+=[ \t]+bus/\n', text, re.M)
    if not marker:
        sys.exit('Error: unexpected drivers/Makefile layout.')
    at = marker.end()
    path.write_text(text[:at] + 'obj-$(CONFIG_KSU)\t\t+= kernelsu/\n' + text[at:])
path = root / 'drivers/Kconfig'
text = path.read_text()
include = 'source "drivers/kernelsu/Kconfig"'
if include not in text:
    at = text.rfind('endmenu')
    if at < 0:
        sys.exit('Error: unexpected drivers/Kconfig layout.')
    path.write_text(text[:at] + include + '\n\n' + text[at:])
(root / 'KernelSU-Next/RAPHAEL_UPSTREAM').write_text(
    'https://github.com/KernelSU-Next/KernelSU-Next/tree/legacy\n'
    'b933b1f728116a456fbebf27b6a8772a640cdf23\n'
    'Built-in manual hooks for Raphael Linux 4.14; reported KSU version 33318.\n')
PY
)

if (( WITH_KSU )); then
    setup_kernelsu_next
fi


DEFCONFIG=${DEFCONFIG:-raphael_defconfig}
[[ -f arch/arm64/configs/$DEFCONFIG ]] || die "Unknown configuration: $DEFCONFIG"
JOBS=${JOBS:-4}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer.'
LLVM_IAS=${LLVM_IAS:-1}
[[ $LLVM_IAS == 0 || $LLVM_IAS == 1 ]] || die 'LLVM_IAS must be 0 or 1.'

# This 4.14 tree accepts LLVM=1, not modern LLVM=-22 suffix selection.
# PATH also selects unversioned LLVM_AR/LLVM_NM used internally for LTO.
args=(O="$OUT_DIR" ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS="$LLVM_IAS"
      DTC_EXT="$DTC_EXT"
      CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-
      CC="$TOOLCHAIN/clang" LD="$TOOLCHAIN/ld.lld"
      HOSTCC=gcc HOSTCXX=g++ PYTHON=python3)
if (( WITH_KSU )); then
    args+=(KSU_VERSION_OVERRIDE=33318 KSU_VERSION_TAG_OVERRIDE=v3.4.0-legacy-b933b1f)
fi
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-$(id -un)}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-$(hostname)}
compiler_version=$("$TOOLCHAIN/clang" --version)
printf 'Compiler: %s\nConfig: %s\nOutput: %s\nJobs: %s\n' \
    "${compiler_version%%$'\n'*}" "$DEFCONFIG" "$OUT_DIR" "$JOBS"

# NetHunter kernel profile for this 4.14 tree. The vendor 88x2bu driver uses
# cfg80211 directly; enabling mac80211 does not change that driver's TX path.
# Keep the Android module ABI settings, release string and SELinux policy unchanged.
nethunter_options=(
    # Kali chroot, IPC and normal Linux userspace interfaces.
    SYSVIPC POSIX_MQUEUE NAMESPACES UTS_NS IPC_NS PID_NS NET_NS
    FHANDLE UNIX98_PTYS PROC_FS SYSFS TMPFS TMPFS_POSIX_ACL TMPFS_XATTR
    BLK_DEV_LOOP IKCONFIG IKCONFIG_PROC MODULES MODULE_UNLOAD
    # Packet capture, tunnels, forwarding and the existing Android iptables ABI.
    NET UNIX PACKET INET IPV6 NETDEVICES TUN VETH BRIDGE BRIDGE_NETFILTER
    NETFILTER NETFILTER_ADVANCED NETFILTER_NETLINK
    NETFILTER_NETLINK_QUEUE NETFILTER_NETLINK_LOG
    NF_CONNTRACK NF_CONNTRACK_IPV4 NF_CONNTRACK_IPV6 NF_NAT NF_NAT_IPV4
    NETFILTER_XTABLES NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MATCH_STATE
    NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_STRING
    NETFILTER_XT_TARGET_NFQUEUE NETFILTER_XT_TARGET_NFLOG
    NETFILTER_XT_TARGET_REDIRECT NETFILTER_XT_TARGET_TPROXY
    IP_NF_IPTABLES IP_NF_FILTER IP_NF_MANGLE IP_NF_RAW IP_NF_NAT
    IP_NF_TARGET_MASQUERADE IP_NF_TARGET_REDIRECT
    IP6_NF_IPTABLES IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_RAW
    IP_SET IP_SET_HASH_IP IP_SET_HASH_NET IP_SET_HASH_IPPORT
    IP_SET_LIST_SET NETFILTER_XT_SET
    # USB host peripherals and external Bluetooth; drivers are built in.
    USB USB_XHCI_HCD USB_DWC3 USB_DWC3_DUAL_ROLE USB_ACM USB_MON
    USB_SERIAL USB_SERIAL_FTDI_SIO USB_SERIAL_CP210X
    USB_SERIAL_PL2303 USB_SERIAL_CH341
    USB_USBNET USB_NET_CDCETHER USB_NET_RNDIS_HOST USB_RTL8150 USB_RTL8152
    BT BT_BREDR BT_RFCOMM BT_RFCOMM_TTY
    BT_HCIBTUSB BT_HCIBTUSB_BCM BT_HCIBTUSB_RTL
    CFG80211 CFG80211_WEXT MAC80211 MAC80211_MESH
    WLAN WLAN_VENDOR_REALTEK RTL8822BU
    # Modern configfs gadgets already implement HID; no legacy HID patch needed.
    USB_GADGET CONFIGFS_FS USB_CONFIGFS USB_CONFIGFS_F_FS
    USB_CONFIGFS_SERIAL USB_CONFIGFS_ACM USB_CONFIGFS_OBEX
    USB_CONFIGFS_NCM USB_CONFIGFS_ECM USB_CONFIGFS_ECM_SUBSET
    USB_CONFIGFS_RNDIS USB_CONFIGFS_EEM USB_CONFIGFS_MASS_STORAGE
    USB_CONFIGFS_F_HID
)
apply_nethunter_config() {
    local config=$1 option
    local changes=()
    for option in "${nethunter_options[@]}"; do
        changes+=(-e "$option")
    done
    "$ROOT/scripts/config" --file "$config" "${changes[@]}"
}
verify_nethunter_config() {
    local option missing=0 report="$OUT_DIR/nethunter-config.txt"
    {
        printf 'NetHunter kernel configuration for Raphael (Linux 4.14)\n'
        printf 'Compiler: %s\n\n' "${compiler_version%%$'\n'*}"
        for option in "${nethunter_options[@]}"; do
            if grep -Fqx "CONFIG_${option}=y" "$OUT_DIR/.config"; then
                printf 'CONFIG_%s=y\n' "$option"
            else
                printf 'MISSING: CONFIG_%s=y\n' "$option"
                printf 'NetHunter: CONFIG_%s did not resolve to y.\n' "$option" >&2
                missing=1
            fi
        done
        printf '\nKali rootfs/apps, Android USB gadget setup and firmware are separate.\n'
        printf 'Phone boot, USB peripherals and Wi-Fi monitor/injection need device testing.\n'
    } > "$report"
    (( missing == 0 )) || die "NetHunter configuration is incomplete; see $report"
    printf 'NetHunter kernel profile verified: %s\n' "$report"
}

migrate_legacy_defconfig() {
    # Earlier versions wrote optional features into the source defconfig.
    # Undo only those recognized edits, retaining the independent Wi-Fi driver.
    python3 - "$ROOT" "$OUT_DIR" "${nethunter_options[@]}" <<'PY'
from pathlib import Path
import datetime, json, os, re, shutil, sys
root, output = map(Path, sys.argv[1:3])
nh = set(sys.argv[3:])
path = root / 'arch/arm64/configs/raphael_defconfig'
text = path.read_text()
lines = text.splitlines()
def key(line):
    m = re.match(r'(?:CONFIG_([A-Z0-9_]+)=|# CONFIG_([A-Z0-9_]+) is not set$)', line)
    return (m[1] or m[2]) if m else None
values = {key(line): line for line in lines if key(line)}
stock = json.loads(r'''{"FHANDLE":"# CONFIG_FHANDLE is not set","IKCONFIG":"CONFIG_IKCONFIG=y","IKCONFIG_PROC":"CONFIG_IKCONFIG_PROC=y","NAMESPACES":"CONFIG_NAMESPACES=y","PID_NS":"# CONFIG_PID_NS is not set","MODULES":"CONFIG_MODULES=y","MODULE_UNLOAD":"CONFIG_MODULE_UNLOAD=y","NET":"CONFIG_NET=y","PACKET":"CONFIG_PACKET=y","UNIX":"CONFIG_UNIX=y","INET":"CONFIG_INET=y","NETFILTER":"CONFIG_NETFILTER=y","BRIDGE_NETFILTER":"# CONFIG_BRIDGE_NETFILTER is not set","NF_CONNTRACK":"CONFIG_NF_CONNTRACK=y","NETFILTER_XT_TARGET_NFLOG":"CONFIG_NETFILTER_XT_TARGET_NFLOG=y","NETFILTER_XT_TARGET_NFQUEUE":"CONFIG_NETFILTER_XT_TARGET_NFQUEUE=y","NETFILTER_XT_TARGET_TPROXY":"CONFIG_NETFILTER_XT_TARGET_TPROXY=y","NETFILTER_XT_MATCH_COMMENT":"CONFIG_NETFILTER_XT_MATCH_COMMENT=y","NETFILTER_XT_MATCH_CONNTRACK":"CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y","NETFILTER_XT_MATCH_STATE":"CONFIG_NETFILTER_XT_MATCH_STATE=y","NETFILTER_XT_MATCH_STRING":"CONFIG_NETFILTER_XT_MATCH_STRING=y","NF_CONNTRACK_IPV4":"CONFIG_NF_CONNTRACK_IPV4=y","IP_NF_IPTABLES":"CONFIG_IP_NF_IPTABLES=y","IP_NF_FILTER":"CONFIG_IP_NF_FILTER=y","IP_NF_NAT":"CONFIG_IP_NF_NAT=y","IP_NF_TARGET_MASQUERADE":"CONFIG_IP_NF_TARGET_MASQUERADE=y","IP_NF_TARGET_REDIRECT":"CONFIG_IP_NF_TARGET_REDIRECT=y","IP_NF_MANGLE":"CONFIG_IP_NF_MANGLE=y","IP_NF_RAW":"CONFIG_IP_NF_RAW=y","NF_CONNTRACK_IPV6":"CONFIG_NF_CONNTRACK_IPV6=y","IP6_NF_IPTABLES":"CONFIG_IP6_NF_IPTABLES=y","IP6_NF_FILTER":"CONFIG_IP6_NF_FILTER=y","IP6_NF_MANGLE":"CONFIG_IP6_NF_MANGLE=y","IP6_NF_RAW":"CONFIG_IP6_NF_RAW=y","BRIDGE":"CONFIG_BRIDGE=y","BT":"CONFIG_BT=y","CFG80211":"CONFIG_CFG80211=y","BLK_DEV_LOOP":"CONFIG_BLK_DEV_LOOP=y","NETDEVICES":"CONFIG_NETDEVICES=y","TUN":"CONFIG_TUN=y","VETH":"CONFIG_VETH=y","USB_RTL8152":"CONFIG_USB_RTL8152=y","USB_USBNET":"CONFIG_USB_USBNET=y","USB_XHCI_HCD":"CONFIG_USB_XHCI_HCD=y","USB_DWC3":"CONFIG_USB_DWC3=y","USB_GADGET":"CONFIG_USB_GADGET=y","USB_CONFIGFS":"CONFIG_USB_CONFIGFS=y","USB_CONFIGFS_NCM":"CONFIG_USB_CONFIGFS_NCM=y","USB_CONFIGFS_RNDIS":"CONFIG_USB_CONFIGFS_RNDIS=y","USB_CONFIGFS_MASS_STORAGE":"CONFIG_USB_CONFIGFS_MASS_STORAGE=y","USB_CONFIGFS_F_FS":"CONFIG_USB_CONFIGFS_F_FS=y","USB_CONFIGFS_F_HID":"CONFIG_USB_CONFIGFS_F_HID=y","TMPFS_POSIX_ACL":"CONFIG_TMPFS_POSIX_ACL=y","STATIC_USERMODEHELPER":"CONFIG_STATIC_USERMODEHELPER=y","STATIC_USERMODEHELPER_PATH":"CONFIG_STATIC_USERMODEHELPER_PATH=\"\""}''')
owned = set()
expected = {}
if all(values.get(k) == f'CONFIG_{k}=y' for k in nh):
    owned |= nh - {'CFG80211_WEXT', 'WLAN_VENDOR_REALTEK', 'RTL8822BU'}
    expected.update({k: f'CONFIG_{k}=y' for k in owned})
if values.get('KSU_MANUAL_HOOK') == 'CONFIG_KSU_MANUAL_HOOK=y':
    enabled = {'KSU', 'KSU_MANUAL_HOOK', 'KPROBES', 'KRETPROBES', 'KPROBE_EVENTS'}
    disabled = {'KSU_DEBUG', 'KSU_KPROBES_HOOK', 'KSU_SYSCALL_TABLE_HOOK', 'STATIC_USERMODEHELPER'}
    owned |= enabled | disabled
    expected.update({k: f'CONFIG_{k}=y' for k in enabled})
    expected.update({k: f'# CONFIG_{k} is not set' for k in disabled})
    # The earlier integration removed this stock path together with its enable.
    if 'STATIC_USERMODEHELPER_PATH' not in values:
        lines.append(stock['STATIC_USERMODEHELPER_PATH'])
result = []
for line in lines:
    k = key(line)
    if k in owned and line == expected[k]:
        if k in stock:
            result.append(stock[k])
    else:
        result.append(line)
updated = '\n'.join(result) + '\n'
if updated != text:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')
    backup = output / f'raphael_defconfig.before-optional-{stamp}-{os.getpid()}'
    shutil.copy2(path, backup)
    path.write_text(updated)
    print(f'Migrated legacy optional-feature defconfig; backup: {backup}')
PY
}

prepare_feature_config() {
    # Save pre-feature settings so switching flags in one OUT_DIR is reversible.
    python3 - "$OUT_DIR" "$DEFCONFIG" "$WITH_KSU" "$WITH_NETHUNTER" \
        "${nethunter_options[@]}" <<'PY'
from pathlib import Path
import datetime, json, os, re, shutil, sys
output = Path(sys.argv[1])
defconfig = sys.argv[2]
requested = {'ksu': bool(int(sys.argv[3])), 'nethunter': bool(int(sys.argv[4]))}
groups = {
    'ksu': set(('KSU KSU_MANUAL_HOOK KSU_DEBUG KSU_DISABLE_POLICY KSU_DISABLE_MANAGER KSU_KPROBES_HOOK '
                'KSU_SYSCALL_TABLE_HOOK KPROBES KRETPROBES KPROBE_EVENTS '
                'STATIC_USERMODEHELPER STATIC_USERMODEHELPER_PATH').split()),
    'nethunter': set(sys.argv[5:]),
}
def key(line):
    m = re.match(r'(?:CONFIG_([A-Z0-9_]+)=|# CONFIG_([A-Z0-9_]+) is not set$)', line)
    return (m[1] or m[2]) if m else None
def values(lines):
    return {key(line): line for line in lines if key(line)}
config = output / '.config'
base = values((output / '.raphael-base.config').read_text().splitlines())
lines = config.read_text().splitlines()
current = values(lines)
state_path = output / '.raphael-features.json'
state = json.loads(state_path.read_text()) if state_path.exists() else None
if state and state.get('defconfig') != defconfig:
    sys.exit('Error: DEFCONFIG changed; select a new OUT_DIR to preserve your configuration.')
previous = state['features'] if state else {
    'ksu': current.get('KSU') in ('CONFIG_KSU=y', 'CONFIG_KSU=m'),
    'nethunter': (output / 'nethunter-config.txt').exists() or all(
        current.get(k) == f'CONFIG_{k}=y' for k in groups['nethunter']),
}
before = state['before'] if state else {k: current.get(k) for g in groups.values() for k in g}
if not state:
    # Existing always-enabled builds have no trustworthy pre-feature snapshot.
    for name, options in groups.items():
        if previous[name]:
            before.update({k: base.get(k) for k in options})
restore = {k for name, options in groups.items() if previous[name] for k in options}
if restore:
    lines = [line for line in lines if key(line) not in restore]
    lines.extend(before[k] for k in sorted(restore) if before.get(k) is not None)
restored = values(lines)
before = {k: restored.get(k) for g in groups.values() for k in g}
if not state or previous != requested:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')
    backup = output / f'.config.before-features-{stamp}-{os.getpid()}'
    shutil.copy2(config, backup)
    print(f'Configuration before feature selection saved to: {backup}')
config.write_text('\n'.join(lines) + '\n')
state = {'defconfig': defconfig, 'features': requested, 'before': before}
temporary = state_path.with_suffix('.tmp')
temporary.write_text(json.dumps(state, indent=2) + '\n')
temporary.replace(state_path)
PY
}

migrate_legacy_defconfig
# Resolve the unmodified optional-feature baseline without replacing .config.
make "${args[@]}" KCONFIG_CONFIG="$OUT_DIR/.raphael-base.config" "$DEFCONFIG"
if [[ ! -f $OUT_DIR/.config ]]; then
    cp -- "$OUT_DIR/.raphael-base.config" "$OUT_DIR/.config"
fi
prepare_feature_config
# Enable the USB driver in existing build directories as well as new configs.
"$ROOT/scripts/config" --file "$OUT_DIR/.config" \
    -e WLAN -e WLAN_VENDOR_REALTEK -e CFG80211 -e CFG80211_WEXT -e RTL8822BU
if (( WITH_KSU )); then
    "$ROOT/scripts/config" --file "$OUT_DIR/.config" \
        -e KSU -e KSU_MANUAL_HOOK -e KPROBES -e KRETPROBES -e KPROBE_EVENTS \
        -d KSU_KPROBES_HOOK -d KSU_SYSCALL_TABLE_HOOK -d KSU_DEBUG \
        -d KSU_DISABLE_POLICY -d KSU_DISABLE_MANAGER -d STATIC_USERMODEHELPER
else
    "$ROOT/scripts/config" --file "$OUT_DIR/.config" -d KSU -d KSU_MANUAL_HOOK
fi
if (( WITH_NETHUNTER )); then
    apply_nethunter_config "$OUT_DIR/.config"
else
    rm -f -- "$OUT_DIR/nethunter-config.txt"
fi
if (( WITH_KSU && WITH_NETHUNTER )); then
    localversion='-G0N-Nethunter-KSU-🇵🇭'
elif (( WITH_KSU )); then
    localversion='-G0N-KSU-🇵🇭'
else
    localversion='-G0N-🇵🇭'
fi
"$ROOT/scripts/config" --file "$OUT_DIR/.config" --set-str LOCALVERSION "$localversion"
make "${args[@]}" olddefconfig
grep -Fxq "CONFIG_LOCALVERSION=\"$localversion\"" "$OUT_DIR/.config" ||
    die 'CONFIG_LOCALVERSION could not be set.'
if (( WITH_NETHUNTER )); then
    verify_nethunter_config
fi
grep -qx 'CONFIG_RTL8822BU=y' "$OUT_DIR/.config" ||
    die 'RTL8822BU could not be enabled; check USB and cfg80211 configuration.'
if (( WITH_KSU )); then
    for option in KSU KSU_MANUAL_HOOK KPROBES KRETPROBES KPROBE_EVENTS; do
        grep -qx "CONFIG_${option}=y" "$OUT_DIR/.config" || die "$option could not be enabled."
    done
    for option in KSU_DISABLE_POLICY KSU_DISABLE_MANAGER; do
        if grep -Eq "^CONFIG_${option}=(y|m)$" "$OUT_DIR/.config"; then
            die "$option must be disabled for Manager app profiles to work."
        fi
    done
    # Required for the embedded KernelSU-Next pre-init runner.
    make "${args[@]}" headers_install
    # KernelSU includes generated SELinux headers even for a standalone target.
    # Build the SELinux directory first so its Kbuild rule generates them.
    make "${args[@]}" security/selinux/
    printf 'KernelSU-Next: enabled (--ksu)\n'
else
    if grep -Eq '^CONFIG_KSU=(y|m)$' "$OUT_DIR/.config"; then
        die 'KernelSU remained enabled without --ksu.'
    fi
    printf 'KernelSU-Next: disabled (use --ksu to enable)\n'
fi
if (( WITH_NETHUNTER )); then
    printf 'NetHunter profile: enabled (--nethunter)\n'
else
    printf 'NetHunter profile: disabled (use --nethunter to enable)\n'
fi


if (( $# )); then
    make -j"$JOBS" "${args[@]}" "$@"
else
    make -j"$JOBS" "${args[@]}" all Image.gz
fi
printf '\nMake completed successfully. Artifacts are under %s\n' "$OUT_DIR"
if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    printf '\nPackaging boot.img using template: %s\n' "$STOCK_BOOT_IMG"
    make_boot_image
else
    printf '\nboot.img was not created because STOCK_BOOT_IMG was not supplied.\n'
    printf 'To package the compiled kernel, run:\n'
    printf '  STOCK_BOOT_IMG=/absolute/path/to/working/boot.img ./build.sh --bootimg-only\n'
fi
if [[ -n ${STOCK_DTBO_IMG:-} ]]; then
    pack_dtbo_image
else
    printf '\nDisplay device tree: %s/arch/arm64/boot/dts/qcom/raphael-sm8150-overlay.dtbo\n' "$OUT_DIR"
    printf 'To package a matching dtbo.img, supply STOCK_DTBO_IMG and DTBO_INDEX.\n'
fi
