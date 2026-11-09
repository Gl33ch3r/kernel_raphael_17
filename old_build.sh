#!/usr/bin/env bash
# VoltageOS kernel_xiaomi_raphael branch 17.
set -Eeuo pipefail

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ ${1:-} == --help ]]; then
    cat <<'EOF'
Usage:
  ./build.sh
  ./build.sh dtbs
  ./build.sh menuconfig
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh --bootimg-only

Defaults:
  Toolchain: toolchain/clang22
  Config:    raphael_defconfig
  Output:    out/
  Jobs:      4

Included:
  Boolx Clang 22 automatic download
  External DTC overlay compatibility fix
  Built-in RTL8812BU/RTL8822BU driver, including T3U Plus 2357:0138
  Built-in KernelSU-Next legacy with manual hooks for kernel 4.14
  Optional boot.img packaging

Environment:
  TOOLCHAIN       Override LLVM 22 directory
  OUT_DIR         Override output directory
  DEFCONFIG       Override kernel configuration
  JOBS            Override parallel jobs
  DTC_EXT         External device-tree compiler
  STOCK_BOOT_IMG  Working boot image from the same Raphael ROM
  MAGISKBOOT      Optional existing magiskboot executable

A stock_boot.img beside this script enables packaging on default builds.
ROM-specific image signing is separate.

Dependencies:
  sudo apt-get install build-essential bc bison flex libssl-dev \
    libelf-dev zlib1g-dev python3 perl pkg-config cpio gzip lz4 \
    curl tar zstd device-tree-compiler
EOF
    exit 0
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$ROOT"

[[ -f Makefile && -d arch/arm64 ]] ||
    die 'Place build.sh in the kernel repository root.'

command -v python3 >/dev/null 2>&1 ||
    die 'python3 is required.'

TOOLCHAIN=${TOOLCHAIN:-"$ROOT/toolchain/clang22"}
[[ $TOOLCHAIN = /* ]] || TOOLCHAIN="$ROOT/$TOOLCHAIN"
TOOLCHAIN=${TOOLCHAIN%/}

OUT_DIR=${OUT_DIR:-"$ROOT/out"}
[[ $OUT_DIR = /* ]] || OUT_DIR="$ROOT/$OUT_DIR"
mkdir -p -- "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

[[ $OUT_DIR != "$ROOT" ]] ||
    die 'OUT_DIR must differ from the source directory.'

if [[ -z ${STOCK_BOOT_IMG:-} && -s $ROOT/stock_boot.img ]] &&
   [[ $# == 0 || ${1:-} == --bootimg-only ]]; then
    STOCK_BOOT_IMG="$ROOT/stock_boot.img"
fi

BOOTIMG_ONLY=0
if [[ ${1:-} == --bootimg-only ]]; then
    BOOTIMG_ONLY=1
    shift
    (( $# == 0 )) ||
        die '--bootimg-only does not accept make targets.'
    [[ -n ${STOCK_BOOT_IMG:-} ]] ||
        die 'Supply stock_boot.img or set STOCK_BOOT_IMG.'
fi

if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    [[ -s $STOCK_BOOT_IMG ]] ||
        die "Working boot image not found: $STOCK_BOOT_IMG"

    (( $# == 0 )) ||
        die 'Use STOCK_BOOT_IMG with the default build, without make targets.'

    STOCK_BOOT_IMG=$(realpath -- "$STOCK_BOOT_IMG")

    python3 - "$STOCK_BOOT_IMG" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    if f.read(8) != b"ANDROID!":
        sys.exit("Error: STOCK_BOOT_IMG must be an Android boot.img.")
PY
fi

make_boot_image() (
    local STOCK=$STOCK_BOOT_IMG
    local KERNEL="$OUT_DIR/arch/arm64/boot/Image"
    local OUTPUT="$OUT_DIR/boot.img"
    local WORK

    [[ -s $STOCK ]] || die "Missing working boot image: $STOCK"
    [[ -s $KERNEL ]] || die "Missing compiled kernel: $KERNEL"

    STOCK=$(realpath -- "$STOCK")
    KERNEL=$(realpath -- "$KERNEL")
    OUTPUT=$(realpath -m -- "$OUTPUT")

    [[ $OUTPUT != "$STOCK" && $OUTPUT != "$KERNEL" ]] ||
        die 'Output must differ from both inputs.'
    [[ ! -d $OUTPUT ]] ||
        die 'Output must be a filename.'

    python3 - "$KERNEL" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    header = f.read(64)
    if header[56:60] != b"ARM\x64":
        sys.exit("Error: use the raw ARM64 Image, not Image.gz.")
PY

    WORK=$(mktemp -d "$OUT_DIR/.bootimg.XXXXXX")
    trap 'rm -rf -- "$WORK"' EXIT

    if [[ -n ${MAGISKBOOT:-} ]]; then
        MAGISKBOOT=$(command -v -- "$MAGISKBOOT") ||
            die 'MAGISKBOOT executable not found.'
    elif [[ -x $ROOT/toolchain/magiskboot ]]; then
        MAGISKBOOT="$ROOT/toolchain/magiskboot"
    elif command -v magiskboot >/dev/null 2>&1; then
        MAGISKBOOT=$(command -v magiskboot)
    else
        [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
            die 'Automatic tool download requires Linux x86_64.'

        for tool in curl sha256sum; do
            command -v "$tool" >/dev/null 2>&1 ||
                die "Missing dependency: $tool"
        done

        printf 'Downloading the official Magisk boot-image tool...\n'

        curl --fail --location --retry 3 --connect-timeout 30 \
            https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk \
            -o "$WORK/Magisk.apk"

        printf '%s  %s\n' \
            89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7 \
            "$WORK/Magisk.apk" |
            sha256sum --check --status ||
            die 'Magisk APK checksum mismatch.'

        # Extract only magiskboot; this does not install Magisk.
        python3 - "$WORK/Magisk.apk" "$WORK/magiskboot" <<'PY'
import pathlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as apk:
    binary = pathlib.Path(sys.argv[2])
    binary.write_bytes(apk.read("lib/x86_64/libmagiskboot.so"))
    binary.chmod(0o755)
PY

        mkdir -p -- "$ROOT/toolchain"
        mv -- "$WORK/magiskboot" "$ROOT/toolchain/magiskboot"
        MAGISKBOOT="$ROOT/toolchain/magiskboot"
    fi

    MAGISKBOOT=$(realpath -- "$MAGISKBOOT")
    [[ -x $MAGISKBOOT ]] ||
        die 'magiskboot must be executable.'

    mkdir -- "$WORK/unpacked"

    (
        cd -- "$WORK/unpacked"
        "$MAGISKBOOT" unpack -h "$STOCK"
        [[ -s kernel ]] || die 'Template has no kernel.'
        cp -- "$KERNEL" kernel
        "$MAGISKBOOT" repack "$STOCK" "$WORK/boot.img"
    )

    [[ -s $WORK/boot.img ]] ||
        die 'Repacking did not produce boot.img.'

    mv -f -- "$WORK/boot.img" "$OUTPUT"
    printf '\nBoot image created: %s\n' "$OUTPUT"
)

if (( BOOTIMG_ONLY )); then
    make_boot_image
    exit 0
fi

# The bundled DTC 1.4.4 cannot parse Raphael's overlay syntax.
DTC_EXT=${DTC_EXT:-$(command -v dtc || true)}
[[ -n $DTC_EXT ]] ||
    die 'Install device-tree-compiler or set DTC_EXT=/path/to/modern/dtc.'

DTC_EXT=$(command -v -- "$DTC_EXT") ||
    die 'DTC_EXT executable not found.'
DTC_EXT=$(realpath -- "$DTC_EXT")

printf '/dts-v1/; /plugin/; &external { status = "okay"; };\n' |
    "$DTC_EXT" -@ -I dts -O dtb -o /dev/null 2>/dev/null ||
    die 'Install a newer device-tree-compiler with overlay support.'

download_toolchain() (
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Boolx Clang requires Linux x86_64.'

    for tool in curl tar zstd sha256sum mktemp; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "Missing download dependency: $tool"
    done

    local url=https://github.com/onettboots/boolx-clang-build/releases/download/Boolx-22/boolx-clang22.tar.zst
    local checksum=5a5778d43b6f1f1531e8939213746b2b0b10d1445c3e0db84f5c24f29ce0a131
    local staging

    [[ ! -e $TOOLCHAIN ]] ||
        die "Incomplete toolchain at $TOOLCHAIN; move it aside and retry."

    mkdir -p -- "$(dirname -- "$TOOLCHAIN")"
    staging=$(mktemp -d "${TOOLCHAIN}.download.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT

    printf 'Downloading Boolx Clang 22...\n'

    curl --fail --location --retry 3 --connect-timeout 30 \
        "$url" -o "$staging/toolchain.tar.zst"

    printf '%s  %s\n' "$checksum" "$staging/toolchain.tar.zst" |
        sha256sum --check --status ||
        die 'Toolchain checksum verification failed.'

    mkdir -- "$staging/unpacked"
    tar --zstd -xf "$staging/toolchain.tar.zst" \
        --strip-components=1 -C "$staging/unpacked"

    [[ -x $staging/unpacked/bin/clang ]] ||
        die 'Archive does not contain bin/clang.'

    mv -- "$staging/unpacked" "$TOOLCHAIN"
)

if [[ ! -x $TOOLCHAIN/bin/clang && ! -x $TOOLCHAIN/clang ]]; then
    download_toolchain
fi

if [[ -d $TOOLCHAIN/bin ]]; then
    TOOLCHAIN="$TOOLCHAIN/bin"
fi

TOOLCHAIN=$(cd -- "$TOOLCHAIN" && pwd -P)
export PATH="$TOOLCHAIN:$PATH"

for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy \
            llvm-objdump llvm-readelf llvm-strip llvm-dis; do
    [[ -x $TOOLCHAIN/$tool ]] ||
        die "Missing toolchain executable: $TOOLCHAIN/$tool"

    version=$("$TOOLCHAIN/$tool" --version)
    [[ $version =~ version[[:space:]]+22\. ||
       $version =~ LLD[[:space:]]+22\. ]] ||
        die "$tool must be version 22: ${version%%$'\n'*}"
done

for tool in make gcc g++ bc bison flex python3 perl pkg-config gzip; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Missing dependency: $tool (see ./build.sh --help)."
done

setup_rtl88x2bu() (
    local driver="$ROOT/drivers/net/wireless/realtek/rtl88x2bu"
    local revision=465ae7cb522a382adc85ea5c31f228af8d172148
    local checksum=2fb1915e3711912101cd1b8924fdec944900fcebaec45d62624e11b63b92a76d
    local staging

    if [[ ! -f $driver/Makefile ]]; then
        [[ ! -e $driver ]] ||
            die "Incomplete driver directory: $driver"

        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 ||
                die "Driver setup requires $tool."
        done

        staging=$(mktemp -d "$ROOT/.rtl88x2bu.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT

        printf 'Downloading the RTL8812BU/RTL8822BU driver...\n'

        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/RinCat/RTL88x2BU-Linux-Driver/tar.gz/$revision" \
            -o "$staging/driver.tar.gz"

        printf '%s  %s\n' "$checksum" "$staging/driver.tar.gz" |
            sha256sum --check --status ||
            die 'Driver archive checksum mismatch.'

        mkdir -- "$staging/source"
        tar -xzf "$staging/driver.tar.gz" \
            --strip-components=1 -C "$staging/source"

        mkdir -p -- "$(dirname -- "$driver")"
        mv -- "$staging/source" "$driver"
    fi

    python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
driver = root / "drivers/net/wireless/realtek/rtl88x2bu"

def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        sys.exit(f"Error: unexpected source contents in {path}.")
    path.write_text(text.replace(old, new, 1))

replace_once(
    driver / "Makefile",
    "CONFIG_PLATFORM_I386_PC = y",
    "CONFIG_PLATFORM_I386_PC = n",
)

replace_once(
    driver / "Makefile",
    "ccflags-y += $(USER_EXTRA_CFLAGS)\n",
    "ccflags-y += $(USER_EXTRA_CFLAGS)\n"
    "# Built-in ARM64 kernel integration; use the parent kernel's architecture/tools.\n"
    "ccflags-y += -DCONFIG_LITTLE_ENDIAN\n"
    "ccflags-y += -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT\n",
)

(driver / "Kconfig").write_text(
    'config RTL8822BU\n'
    '\ttristate "Realtek RTL8812BU/RTL8822BU USB WiFi"\n'
    '\tdepends on USB && CFG80211\n'
    '\tselect CFG80211_WEXT\n'
    '\tselect WEXT_PRIV\n'
    '\thelp\n'
    '\t  Support Realtek RTL8812BU and RTL8822BU USB wireless adapters,\n'
    '\t  including TP-Link Archer T3U Plus (USB ID 2357:0138).\n'
)

parent = driver.parent
path = parent / "Kconfig"
text = path.read_text()
include = 'source "drivers/net/wireless/realtek/rtl88x2bu/Kconfig"'
if include not in text:
    marker = "endif # WLAN_VENDOR_REALTEK"
    if marker not in text:
        sys.exit("Error: unexpected Realtek Kconfig layout.")
    path.write_text(text.replace(marker, include + "\n\n" + marker))

path = parent / "Makefile"
text = path.read_text()
if "obj-$(CONFIG_RTL8822BU)" not in text:
    path.write_text(
        text.rstrip() + "\nobj-$(CONFIG_RTL8822BU) += rtl88x2bu/\n"
    )

path = root / "arch/arm64/configs/raphael_defconfig"
text = path.read_text()
for option in ("CFG80211_WEXT", "WLAN_VENDOR_REALTEK", "RTL8822BU"):
    pattern = rf"^(?:CONFIG_{option}=.*|# CONFIG_{option} is not set)$"
    line = f"CONFIG_{option}=y"
    if re.search(pattern, text, re.M):
        text = re.sub(pattern, line, text, flags=re.M)
    else:
        text = text.rstrip() + "\n" + line + "\n"
path.write_text(text)

# Consume all llvm-nm output to avoid LLVM 22 broken-pipe messages.
path = root / "scripts/Makefile.build"
text = path.read_text()
path.write_text(
    text.replace("| grep -q __ksymtab;", "| grep __ksymtab >/dev/null;")
)

(driver / "RAPHAEL_UPSTREAM").write_text(
    "https://github.com/RinCat/RTL88x2BU-Linux-Driver\n"
    "465ae7cb522a382adc85ea5c31f228af8d172148\n"
)
PY
)

setup_rtl88x2bu

setup_kernelsu_next() (
    local source="$ROOT/KernelSU-Next"
    local revision=b933b1f728116a456fbebf27b6a8772a640cdf23
    local checksum=e68647c65d416245e2e6ca1c86b84ffc4bb5736a8947ce73946902ae9b8586c6
    local staging

    if [[ ! -f $source/kernel/Kconfig ]]; then
        [[ ! -e $source ]] ||
            die "Incomplete KernelSU-Next directory: $source"

        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 ||
                die "KernelSU-Next setup requires $tool."
        done

        staging=$(mktemp -d "$ROOT/.ksunext.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT

        printf 'Downloading KernelSU-Next legacy for kernel 4.14...\n'

        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/KernelSU-Next/KernelSU-Next/tar.gz/$revision" \
            -o "$staging/source.tar.gz"

        printf '%s  %s\n' "$checksum" "$staging/source.tar.gz" |
            sha256sum --check --status ||
            die 'KernelSU-Next archive checksum mismatch.'

        mkdir -- "$staging/source"
        tar -xzf "$staging/source.tar.gz" \
            --strip-components=1 -C "$staging/source"
        mv -- "$staging/source" "$source"
    fi

    python3 - "$ROOT" <<'PY'
from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1])

# Verified manual hooks and compatibility patches for branch 17.
# JSON strings preserve the exact source whitespace.
replacements = json.loads(r'''{
    "KernelSU-Next/kernel/Kbuild": [["ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n", "ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Detect Android/vendor kernels that backported __poll_t before 4.16.\nifeq ($(shell grep -Eq \"typedef.*__poll_t\" $(srctree)/include/uapi/linux/types.h $(srctree)/include/linux/types.h; echo $$?),0)\nccflags-y += -DKSU_HAS_POLL_T\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n"]],
    "KernelSU-Next/kernel/feature/sucompat.c": [["\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\tconst char *const *sucompat_argv = (const char *const *)__never_use_argv;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n", "\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n"], ["\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, sucompat_argv, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n", "\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\t/* argv is a struct user_arg_ptr, not an array of kernel strings. */\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, NULL, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n"]],
    "KernelSU-Next/kernel/infra/event_queue.h": [["#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0)\ntypedef unsigned int __poll_t;\n#endif\n\n", "#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0) && !defined(KSU_HAS_POLL_T)\ntypedef unsigned int __poll_t;\n#endif\n\n"]],
    "drivers/input/input.c": [["#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n", "#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n"], ["static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition = input_get_disposition(dev, type, code, &value);\n\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n", "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\tdisposition = input_get_disposition(dev, type, code, &value);\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n"]],
    "fs/exec.c": [[" */\n\n#include <linux/slab.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n", " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n"], ["\tstruct files_struct *displaced;\n\tint retval;\n\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n", "\tstruct files_struct *displaced;\n\tint retval;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t/* execve_file() may provide a file without a filename. */\n\tif (filename && !IS_ERR(filename))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n"]],
    "fs/internal.h": [["extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n", "extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\nint path_umount(struct path *path, int flags);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n"]],
    "fs/namespace.c": [["\n#endif\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n", "\n#endif\n\nstatic int can_umount(const struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))\n\t\t return -EINVAL;\n\t if (!may_mount())\n\t\t return -EPERM;\n\t if (path->dentry != path->mnt->mnt_root)\n\t\t return -EINVAL;\n\t if (!check_mnt(mnt))\n\t\t return -EINVAL;\n\t if (mnt->mnt.mnt_flags & MNT_LOCKED)\n\t\t return -EINVAL;\n\t if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))\n\t\t return -EPERM;\n\t return 0;\n }\n\nint path_umount(struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t int ret;\n\t ret = can_umount(path, flags);\n\t if (!ret)\n\t\t ret = do_umount(mnt, flags);\n\t dput(path->dentry);\n\t mntput_no_expire(mnt);\n\t return ret;\n }\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n"]],
    "fs/open.c": [[" */\n\n#include <linux/string.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n", " */\n\n#include <linux/string.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n"], ["\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n", "\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n"]],
    "fs/read_write.c": [[" */\n\n#include <linux/slab.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n", " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n"], ["\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f = fdget_pos(fd);\n\tssize_t ret = -EBADF;\n\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n", "\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f;\n\tssize_t ret = -EBADF;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd);\n#endif\n\tf = fdget_pos(fd);\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n"]],
    "fs/stat.c": [[" *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n", " *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n"], ["\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n", "\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n"], ["\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n", "\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n"], ["\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n", "\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n"]],
    "include/linux/ksu_manual_hooks.h": [["", "/* SPDX-License-Identifier: GPL-2.0 */\n#ifndef _LINUX_KSU_MANUAL_HOOKS_H\n#define _LINUX_KSU_MANUAL_HOOKS_H\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n#include <linux/compiler.h>\n#include <linux/types.h>\n\nstruct filename;\nstruct stat;\nstruct stat64;\nextern bool ksu_su_compat_enabled;\nextern bool ksu_init_rc_hook;\nextern bool ksu_input_hook;\n\nint ksu_handle_execveat(int *fd, struct filename **filename, void *argv,\n\t\t       void *envp, int *flags);\nint ksu_handle_faccessat(int *dfd, const char __user **filename, int *mode,\n\t\t       int *flags);\nint ksu_handle_stat(int *dfd, const char __user **filename, int *flags);\nvoid ksu_handle_sys_read(unsigned int fd);\nvoid ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf);\nvoid ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf);\nint ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,\n\t\t\t\t int *value);\nint ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n\t\t\t void __user **arg);\n#endif\n\n#endif /* _LINUX_KSU_MANUAL_HOOKS_H */\n"]],
    "include/linux/seccomp.h": [["#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n", "#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <linux/atomic.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n"], [" */\nstruct seccomp {\n\tint mode;\n\tstruct seccomp_filter *filter;\n};\n\n", " */\nstruct seccomp {\n\tint mode;\n\tatomic_t filter_count;\n\tstruct seccomp_filter *filter;\n};\n\n"]],
    "kernel/reboot.c": [["#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n", "#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n"], ["\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n", "\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n"]]
}''')

for name, changes in replacements.items():
    path = root / name
    text = path.read_text() if path.exists() else ""
    original = text

    for old, new in changes:
        if new in text:
            continue
        if old == "" and text == "":
            text = new
        elif old and text.count(old) == 1:
            text = text.replace(old, new, 1)
        else:
            sys.exit(
                f"Error: cannot apply KernelSU-Next integration to {name}; "
                "source tree differs."
            )

    if text != original:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

link = root / "drivers/kernelsu"
target = root / "KernelSU-Next/kernel"
if link.is_symlink():
    if link.resolve() != target.resolve():
        sys.exit("Error: another KernelSU integration occupies drivers/kernelsu.")
elif link.exists():
    sys.exit("Error: drivers/kernelsu already exists.")
else:
    link.symlink_to("../KernelSU-Next/kernel", target_is_directory=True)

path = root / "drivers/Makefile"
text = path.read_text()
if "obj-$(CONFIG_KSU)" not in text:
    path.write_text(text.rstrip() + "\nobj-$(CONFIG_KSU) += kernelsu/\n")

path = root / "drivers/Kconfig"
text = path.read_text()
include = 'source "drivers/kernelsu/Kconfig"'
if include not in text:
    at = text.rfind("endmenu")
    if at < 0:
        sys.exit("Error: unexpected drivers/Kconfig layout.")
    path.write_text(text[:at] + include + "\n\n" + text[at:])

path = root / "arch/arm64/configs/raphael_defconfig"
text = path.read_text()
for option, enabled in [
    ("KSU", True),
    ("KSU_MANUAL_HOOK", True),
    ("KSU_DEBUG", False),
    ("STATIC_USERMODEHELPER", False),
]:
    pattern = rf"^(?:CONFIG_{option}=.*|# CONFIG_{option} is not set)$"
    line = f"CONFIG_{option}=y" if enabled else f"# CONFIG_{option} is not set"
    if re.search(pattern, text, re.M):
        text = re.sub(pattern, line, text, flags=re.M)
    else:
        text = text.rstrip() + "\n" + line + "\n"

text = re.sub(
    r"^CONFIG_STATIC_USERMODEHELPER_PATH=.*\n?", "", text, flags=re.M
)
path.write_text(text)

(root / "KernelSU-Next/RAPHAEL_UPSTREAM").write_text(
    "https://github.com/KernelSU-Next/KernelSU-Next/tree/legacy\n"
    "b933b1f728116a456fbebf27b6a8772a640cdf23\n"
    "Built-in manual hooks for Raphael Linux 4.14; KSU version 33318.\n"
)
PY
)

setup_kernelsu_next

DEFCONFIG=${DEFCONFIG:-raphael_defconfig}
[[ -f arch/arm64/configs/$DEFCONFIG ]] ||
    die "Unknown configuration: $DEFCONFIG"

JOBS=${JOBS:-4}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] ||
    die 'JOBS must be a positive integer.'

LLVM_IAS=${LLVM_IAS:-1}
[[ $LLVM_IAS == 0 || $LLVM_IAS == 1 ]] ||
    die 'LLVM_IAS must be 0 or 1.'

args=(
    O="$OUT_DIR"
    ARCH=arm64
    SUBARCH=arm64
    LLVM=1
    LLVM_IAS="$LLVM_IAS"
    DTC_EXT="$DTC_EXT"
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CC="$TOOLCHAIN/clang"
    LD="$TOOLCHAIN/ld.lld"
    HOSTCC=gcc
    HOSTCXX=g++
    PYTHON=python3
    KSU_VERSION_OVERRIDE=33318
    KSU_VERSION_TAG_OVERRIDE=v3.4.0-legacy-b933b1f
)

export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-$(id -un)}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-$(hostname)}

compiler_version=$("$TOOLCHAIN/clang" --version)
printf 'Compiler: %s\nDTC: %s\nConfig: %s\nOutput: %s\nJobs: %s\n' \
    "${compiler_version%%$'\n'*}" "$DTC_EXT" \
    "$DEFCONFIG" "$OUT_DIR" "$JOBS"

if [[ ! -f $OUT_DIR/.config ]]; then
    make "${args[@]}" "$DEFCONFIG"
fi

# Update configurations from previous builds too.
"$ROOT/scripts/config" --file "$OUT_DIR/.config" \
    -e WLAN \
    -e WLAN_VENDOR_REALTEK \
    -e CFG80211 \
    -e CFG80211_WEXT \
    -e RTL8822BU

"$ROOT/scripts/config" --file "$OUT_DIR/.config" \
    -e KSU \
    -e KSU_MANUAL_HOOK \
    -d KSU_KPROBES_HOOK \
    -d KSU_SYSCALL_TABLE_HOOK \
    -d KSU_DEBUG \
    -d STATIC_USERMODEHELPER

make "${args[@]}" olddefconfig

for option in RTL8822BU KSU KSU_MANUAL_HOOK; do
    grep -qx "CONFIG_${option}=y" "$OUT_DIR/.config" ||
        die "$option could not be enabled."
done

# Required to build KernelSU-Next's embedded pre-init helper.
make "${args[@]}" headers_install

if (( $# )); then
    make -j"$JOBS" "${args[@]}" "$@"
else
    make -j"$JOBS" "${args[@]}" all Image.gz
fi

printf '\nKernel build completed: %s\n' "$OUT_DIR"

if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    printf '\nPackaging boot.img using: %s\n' "$STOCK_BOOT_IMG"
    make_boot_image
else
    printf '\nboot.img was not created because no template was supplied.\n'
    printf 'Place stock_boot.img beside build.sh, then run:\n'
    printf '  ./build.sh --bootimg-only\n'
fi
