#!/usr/bin/env bash
#
# make-win11-usb.sh
#
# Creates a bootable Windows 11 USB stick (UEFI/GPT + FAT32).
#
# Works around the FAT32 4 GiB file size limit by splitting install.wim
# into install.swm, install2.swm, ...
#
# Supports:
#   - Fedora / RHEL-like (dnf)
#   - Debian / Ubuntu (apt)
#   - install.wim
#   - install.esd (all editions inside are converted)
#   - /dev/sdX
#   - /dev/nvmeXnY
#   - /dev/mmcblkX
#
# Usage:
#   sudo ./make-win11-usb.sh <Windows.iso> </dev/sdX>
#
# Example:
#   sudo ./make-win11-usb.sh ./Win11_24H2_English_x64.iso /dev/sdc
#
# WARNING:
#   The target disk (the whole disk, not a partition) will be COMPLETELY ERASED.
#

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

ISO_SRC="${1:-}"
DEV="${2:-}"

ISO_MNT=""
USB_MNT=""
TMP_WIM=""

cleanup() {
    local rc=$?

    sync 2>/dev/null || true

    if [[ -n "${USB_MNT:-}" ]] && mountpoint -q "$USB_MNT" 2>/dev/null; then
        umount "$USB_MNT" 2>/dev/null || true
    fi

    if [[ -n "${ISO_MNT:-}" ]] && mountpoint -q "$ISO_MNT" 2>/dev/null; then
        umount "$ISO_MNT" 2>/dev/null || true
    fi

    if [[ -n "${TMP_WIM:-}" && -e "${TMP_WIM:-}" ]]; then
        rm -f "$TMP_WIM" 2>/dev/null || true
    fi

    if [[ -n "${USB_MNT:-}" ]]; then
        rmdir "$USB_MNT" 2>/dev/null || true
    fi

    if [[ -n "${ISO_MNT:-}" ]]; then
        rmdir "$ISO_MNT" 2>/dev/null || true
    fi

    exit "$rc"
}

trap cleanup EXIT INT TERM

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

# ============================================================
# ARGUMENTS
# ============================================================

if [[ $EUID -ne 0 ]]; then
    die "Run this script with sudo."
fi

if [[ $# -ne 2 ]]; then
    echo
    echo "Usage:"
    echo "  sudo $SCRIPT_NAME <source.iso> </dev/sdX>"
    echo
    echo "Example:"
    echo "  sudo $SCRIPT_NAME ./Win11.iso /dev/sdc"
    exit 1
fi

[[ -f "$ISO_SRC" ]] || die "ISO file not found: $ISO_SRC"
[[ -b "$DEV" ]] || die "$DEV is not a valid block device."

ISO_SRC="$(realpath "$ISO_SRC")"

# ============================================================
# DISTRO / PACKAGE MANAGER DETECTION
# ============================================================

info "Detecting package manager..."

PKG_MANAGER=""

if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
else
    die "Neither apt-get nor dnf found. Install manually: wimlib-imagex, rsync, parted, mkfs.vfat."
fi

echo "Package manager: $PKG_MANAGER"

# Package names differ between distros (e.g. wimlib-imagex ships in the
# "wimtools" package on Debian/Ubuntu, but in "wimlib-utils" on Fedora).
pkg_name_for() {
    local cmd="$1"
    case "$cmd" in
        wimlib-imagex)
            [[ "$PKG_MANAGER" == "apt" ]] && echo "wimtools" || echo "wimlib-utils"
            ;;
        mkfs.vfat)
            echo "dosfstools"
            ;;
        parted|partprobe)
            echo "parted"
            ;;
        rsync)
            echo "rsync"
            ;;
        wipefs|lsblk|mount|umount|findmnt|mountpoint)
            echo "util-linux"
            ;;
        *)
            echo "$cmd"
            ;;
    esac
}

# ============================================================
# DEPENDENCIES
# ============================================================

info "Checking dependencies..."

REQUIRED_CMDS=(wimlib-imagex rsync parted mkfs.vfat wipefs lsblk mount umount findmnt mountpoint)
MISSING_PACKAGES=()

for CMD in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        PKG="$(pkg_name_for "$CMD")"
        if [[ ! " ${MISSING_PACKAGES[*]:-} " =~ " ${PKG} " ]]; then
            MISSING_PACKAGES+=("$PKG")
        fi
    fi
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Missing packages:"
    printf '  - %s\n' "${MISSING_PACKAGES[@]}"
    echo

    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get update
        apt-get install -y "${MISSING_PACKAGES[@]}"
    else
        dnf install -y "${MISSING_PACKAGES[@]}"
    fi
fi

# partprobe and udevadm are helpful when present, but we don't block on them
HAVE_PARTPROBE=0
command -v partprobe >/dev/null 2>&1 && HAVE_PARTPROBE=1

HAVE_UDEVADM=0
command -v udevadm >/dev/null 2>&1 && HAVE_UDEVADM=1

# ============================================================
# TARGET DISK CHECK
# ============================================================

info "Checking target disk..."

DEV_TYPE="$(lsblk -dn -o TYPE "$DEV" 2>/dev/null || true)"

[[ "$DEV_TYPE" == "disk" ]] || \
    die "$DEV is not a whole disk. Use /dev/sdX, not /dev/sdX1."

TRAN="$(lsblk -dn -o TRAN "$DEV" 2>/dev/null || true)"
RM="$(lsblk -dn -o RM "$DEV" 2>/dev/null || true)"

echo
echo "Target device:"
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL,SERIAL,MOUNTPOINTS "$DEV"
echo

if [[ "$TRAN" != "usb" || "$RM" != "1" ]]; then

    echo "WARNING: $DEV is not automatically detected as a removable USB device."
    echo "TRAN='$TRAN' RM='$RM'"
    echo

    read -r -p \
        "If you are ABSOLUTELY sure, type EXACTLY 'YES' to continue: " \
        CONFIRM

    [[ "$CONFIRM" == "YES" ]] || die "Operation cancelled."
fi

echo
echo "============================================================"
echo " WARNING: THE DISK WILL BE COMPLETELY ERASED"
echo "============================================================"
echo
lsblk "$DEV"
echo

read -r -p \
    "Type EXACTLY 'YES' to erase $DEV and continue: " \
    CONFIRM

[[ "$CONFIRM" == "YES" ]] || die "Operation cancelled."

# ============================================================
# MOUNT ISO
# ============================================================

ISO_MNT="$(mktemp -d /tmp/win11-iso.XXXXXX)"
USB_MNT="$(mktemp -d /tmp/win11-usb.XXXXXX)"

info "Mounting the ISO..."

mount -o loop,ro "$ISO_SRC" "$ISO_MNT"

# ============================================================
# ISO VALIDATION
# ============================================================

info "Validating the Windows ISO..."

EFI_BOOT_SRC="$(find "$ISO_MNT" -maxdepth 3 -ipath '*/efi/boot/bootx64.efi' -print -quit)"

[[ -n "$EFI_BOOT_SRC" ]] || \
    die "The ISO does not contain efi/boot/bootx64.efi (not a valid UEFI ISO)."

WIM_FILE="$ISO_MNT/sources/install.wim"
ESD_FILE="$ISO_MNT/sources/install.esd"

if [[ -f "$WIM_FILE" ]]; then
    IMAGE_FILE="$WIM_FILE"
    IMAGE_TYPE="WIM"
    echo "Found: sources/install.wim"
elif [[ -f "$ESD_FILE" ]]; then
    IMAGE_FILE="$ESD_FILE"
    IMAGE_TYPE="ESD"
    echo "Found: sources/install.esd"
else
    die "The ISO contains neither sources/install.wim nor sources/install.esd."
fi

echo
echo "Image info:"
wimlib-imagex info "$IMAGE_FILE" || \
    die "install.wim/esd looks corrupt or incomplete (re-download the ISO)."

# ============================================================
# UNMOUNT USB
# ============================================================

info "Unmounting any existing partitions on $DEV..."

while read -r PART; do
    [[ -n "$PART" ]] || continue

    if findmnt -rn -S "$PART" >/dev/null 2>&1; then
        echo "  Unmounting: $PART"
        umount "$PART" || die "Could not unmount $PART."
    fi

done < <(lsblk -lnpo NAME "$DEV" | tail -n +2)

# ============================================================
# PARTITIONING
# ============================================================

info "Wiping the partition table..."

wipefs -af "$DEV"

info "Creating GPT + FAT32..."

parted -s "$DEV" \
    mklabel gpt \
    mkpart WIN11 fat32 1MiB 100% \
    set 1 esp on

[[ "$HAVE_PARTPROBE" -eq 1 ]] && partprobe "$DEV" || true
[[ "$HAVE_UDEVADM" -eq 1 ]] && udevadm settle || true

sleep 1

# ============================================================
# DETERMINE THE PARTITION NAME
# ============================================================

if [[ "$DEV" =~ (nvme|mmcblk) ]]; then
    PART="${DEV}p1"
else
    PART="${DEV}1"
fi

for _ in {1..10}; do
    [[ -b "$PART" ]] && break
    sleep 1
done

[[ -b "$PART" ]] || die "Partition did not show up: $PART"

echo "Partition: $PART"

# ============================================================
# FORMAT FAT32
# ============================================================

info "Formatting FAT32..."

mkfs.vfat -F 32 -n WIN11 "$PART"

# ============================================================
# MOUNT USB
# ============================================================

info "Mounting the USB stick..."

mount "$PART" "$USB_MNT"

# ============================================================
# COPY ISO FILES
# ============================================================

info "Copying Windows files..."

rsync -rvh --size-only \
    --exclude='sources/install.wim' \
    --exclude='sources/install.esd' \
    "$ISO_MNT/" \
    "$USB_MNT/"

# ============================================================
# INSTALL.WIM / INSTALL.ESD
# ============================================================

mkdir -p "$USB_MNT/sources"

if [[ "$IMAGE_TYPE" == "WIM" ]]; then

    info "Splitting install.wim into SWM files (under 4 GiB)..."

    wimlib-imagex split \
        "$WIM_FILE" \
        "$USB_MNT/sources/install.swm" \
        3800

else

    # wimlib-imagex split cannot work directly on the format/compression
    # used by Microsoft's ESD files (usually solid LZMS). The safe approach
    # is to export all editions into a non-solid WIM (LZX), then split the
    # resulting WIM.

    info "The ISO contains install.esd, converting..."

    # /tmp can be tmpfs (i.e. RAM/swap) on some systems; use /var/tmp,
    # which is almost always backed by disk.
    TMPDIR_FOR_WIM="/var/tmp"
    TMP_WIM="$(mktemp --tmpdir="$TMPDIR_FOR_WIM" win11-install.XXXXXX.wim)"

    IMAGE_COUNT="$(
        wimlib-imagex info "$ESD_FILE" |
        awk '/^Image Count:/ { print $3; exit }'
    )"

    [[ "$IMAGE_COUNT" =~ ^[0-9]+$ ]] || \
        die "Could not determine the number of images in install.esd."

    echo "Number of editions in ESD: $IMAGE_COUNT"

    AVAIL_KB="$(df -Pk "$TMPDIR_FOR_WIM" | awk 'NR==2 {print $4}')"

    echo "Free space available on $TMPDIR_FOR_WIM: ~$(( AVAIL_KB / 1024 / 1024 )) GB"

    (( AVAIL_KB > 0 )) || \
        die "No free space available on $TMPDIR_FOR_WIM."

    info "Converting all ESD editions to WIM LZX..."

    for ((IDX = 1; IDX <= IMAGE_COUNT; IDX++)); do
        echo "  Exporting image $IDX / $IMAGE_COUNT..."
        wimlib-imagex export \
            "$ESD_FILE" \
            "$IDX" \
            "$TMP_WIM" \
            --compress=LZX \
            --chunk-size=32K
    done

    info "Checking the resulting WIM..."
    wimlib-imagex info "$TMP_WIM"

    info "Splitting the resulting WIM into SWM files..."
    wimlib-imagex split \
        "$TMP_WIM" \
        "$USB_MNT/sources/install.swm" \
        3800
fi

# ============================================================
# FINAL CHECK
# ============================================================

info "Verifying the result..."

EFI_BOOT_DST="$(find "$USB_MNT" -maxdepth 3 -ipath '*/efi/boot/bootx64.efi' -print -quit)"

[[ -n "$EFI_BOOT_DST" ]] || die "efi/boot/bootx64.efi is missing from the USB stick."

SWM_COUNT="$(
    find "$USB_MNT/sources" -maxdepth 1 -type f -iname 'install*.swm' | wc -l
)"

[[ "$SWM_COUNT" -gt 0 ]] || die "No install*.swm files found on the USB stick."

echo
echo "SWM files:"
ls -lh "$USB_MNT/sources"/install*.swm

echo
echo "SWM file count: $SWM_COUNT"

info "Verifying SWM integrity..."

wimlib-imagex info "$USB_MNT/sources/install.swm" >/dev/null || \
    die "install.swm is invalid or corrupt."

wimlib-imagex verify "$USB_MNT/sources/install.swm" || \
    die "SWM integrity check failed (the split files may be corrupt)."

echo "SWM files are valid and verified."

# ============================================================
# DONE
# ============================================================

info "Syncing data to disk..."

sync

echo
echo "============================================================"
echo "              WINDOWS 11 USB READY"
echo "============================================================"
echo
echo "ISO:          $ISO_SRC"
echo "USB:          $DEV"
echo "Partition:    $PART"
echo "Filesystem:   FAT32 / GPT / UEFI (ESP)"
echo "Bootloader:   EFI/BOOT/BOOTX64.EFI"
echo "Image:        $IMAGE_TYPE -> install*.swm ($SWM_COUNT files)"
echo
echo "============================================================"
echo
echo "You can now remove the USB stick and boot from it."
echo "Recommended: in the boot menu (F12/F11/Esc), pick the UEFI entry for the USB stick."