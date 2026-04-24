#!/bin/bash
#
# build-images.sh — Build Alpine Linux VM images for NullClaw VZ backend
#
# Prerequisites:
#   - macOS ARM64 (Apple Silicon)
#   - Docker (OrbStack or Docker Desktop)
#   - curl
#
# Usage:
#   ./vm/build-images.sh          # builds if images do not exist
#   ./vm/build-images.sh --force  # rebuild from scratch
#
# Produces:
#   vm/rootfs.img       — 512MB ext4, Alpine 3.21 + Python 3.12
#   vm/vmlinuz-virt     — Alpine virt kernel (ARM64)
#   vm/initramfs-virt   — Alpine virt initramfs
#
# The VM uses direct kernel boot (VZLinuxBootLoader) — no ESP or
# boot manager needed. Kernel + initrd + rootfs are all that is required.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ALPINE_VERSION="3.21.3"
ALPINE_ARCH="aarch64"
ALPINE_MINOR="3.21"
ISO_NAME="alpine-virt-${ALPINE_VERSION}-${ALPINE_ARCH}.iso"
ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR}/releases/${ALPINE_ARCH}/${ISO_NAME}"

ROOTFS_SIZE_MB=512
ESP_SIZE_MB=64

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
log()  { echo -e "${BLUE}[vm]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
err()  { echo -e "${RED}[err]${NC} $*" >&2; }

# ── Preflight ──────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
    err "docker not found. Install OrbStack or Docker Desktop."
    exit 1
fi
if ! docker info &>/dev/null 2>&1; then
    echo -e "${BLUE}[vm]${NC} Docker not running, starting OrbStack..."
    open -a OrbStack 2>/dev/null || true
    sleep 5
    if ! docker info &>/dev/null 2>&1; then
        err "Docker still not running."
        exit 1
    fi
fi

FORCE=""
[ "${1:-}" = "--force" ] && FORCE="--force"

# ── Download Alpine ISO ───────────────────────────────────────

if [ -f "${ISO_NAME}" ]; then
    ok "ISO exists: ${ISO_NAME}"
else
    log "Downloading Alpine virt ISO..."
    curl -fSL -o "${ISO_NAME}" "${ISO_URL}"
    ok "Downloaded ${ISO_NAME} ($(du -h "${ISO_NAME}" | cut -f1))"
fi

# ── Extract boot files from ISO ───────────────────────────────

if [ -f "vmlinuz-virt" ] && [ -f "initramfs-virt" ] && [ -f "modloop-virt" ] && [ -f "BOOTAA64.EFI" ] && [ -z "${FORCE}" ]; then
    ok "Boot files already extracted"
else
    log "Extracting boot files from ISO..."
    rm -f vmlinuz-virt initramfs-virt modloop-virt BOOTAA64.EFI
    docker run --rm \
        -v "${SCRIPT_DIR}:/work" \
        alpine \
        sh -c '
            mkdir -p /iso && cd /iso
            apk add --no-cache p7zip > /dev/null 2>&1
            7z x /work/'"${ISO_NAME}"' boot/vmlinuz-virt boot/initramfs-virt boot/modloop-virt efi/boot/bootaa64.efi > /dev/null
            cp /iso/boot/vmlinuz-virt /work/vmlinuz-virt
            cp /iso/boot/initramfs-virt /work/initramfs-virt
            cp /iso/boot/modloop-virt /work/modloop-virt
            cp /iso/efi/boot/bootaa64.efi /work/BOOTAA64.EFI
        '
    ok "Extracted boot files (vmlinuz-virt, initramfs-virt, modloop-virt, BOOTAA64.EFI)"
fi

# ── Build rootfs ──────────────────────────────────────────────
#
# Uses Alpine 3.21.3 container (matching target version) with e2fsprogs
# to create the ext4 image. mkfs.ext4 -d <dir> populates the filesystem
# directly from the staging directory — no loop devices needed.

if [ -f "rootfs.img" ] && [ -z "${FORCE}" ]; then
    ok "rootfs.img exists ($(du -h rootfs.img | cut -f1))"
else
    log "Building rootfs.img (${ROOTFS_SIZE_MB}MB ext4, Alpine + Python 3.12)..."
    rm -f rootfs.img

    docker run --rm \
        -v "${SCRIPT_DIR}:/work" \
        --platform linux/arm64 \
        alpine:"${ALPINE_VERSION}" \
        sh -c '
            set -e

            # Stage in /tmp (tmpfs) to avoid Docker volume xattr issues
            ROOTFS=/tmp/rootfs_staging
            rm -rf "${ROOTFS}"
            mkdir -p "${ROOTFS}"

            # Install e2fsprogs for mkfs.ext4 -d
            apk add --no-cache e2fsprogs > /dev/null 2>&1

            # Write matching repositories for this Alpine version
            mkdir -p "${ROOTFS}/etc/apk"
            echo "https://dl-cdn.alpinelinux.org/alpine/v'"${ALPINE_MINOR}"'/main" > "${ROOTFS}/etc/apk/repositories"
            echo "https://dl-cdn.alpinelinux.org/alpine/v'"${ALPINE_MINOR}"'/community" >> "${ROOTFS}/etc/apk/repositories"

            # Install Alpine base + Python 3.12 into staging
            apk --root "${ROOTFS}" --initdb \
                --allow-untrusted \
                --repositories-file /etc/apk/repositories \
                --arch aarch64 \
                add alpine-base python3 openrc

            # Configure inittab for hvc0 serial console
            cat > "${ROOTFS}/etc/inittab" << "INITTAB"
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::shutdown:/sbin/openrc shutdown
hvc0::respawn:/sbin/getty -L hvc0 115200 vt100
INITTAB

            # Set root password
            echo "root:root" | chroot "${ROOTFS}" chpasswd

            # Create mount point + tmp
            mkdir -p "${ROOTFS}/mnt/root"
            chmod 1777 "${ROOTFS}/tmp"

            # Remove suid binary that causes permission issues
            rm -f "${ROOTFS}/bin/bbsuid"

            # Summary
            echo "=== Python ==="
            chroot "${ROOTFS}" python3 --version 2>&1
            echo "=== Staging size ==="
            du -sh "${ROOTFS}"

            # Create ext4 image populated from staging directory
            dd if=/dev/zero of=/tmp/rootfs.img bs=1M count='"${ROOTFS_SIZE_MB}"' 2>/dev/null
            mkfs.ext4 -q -d "${ROOTFS}" /tmp/rootfs.img

            # Move image to Docker volume
            mv /tmp/rootfs.img /work/rootfs.img

            echo "=== Image created ==="
            du -sh /work/rootfs.img
        '
    ok "Built rootfs.img ($(du -h rootfs.img | cut -f1))"

    rm -rf rootfs_staging
fi

# ── Build ESP (EFI System Partition) ──────────────────────────
#
# FAT32 image with systemd-boot + kernel/initramfs.
# BOOTAA64.EFI is extracted from the Alpine ISO.

if [ -f "esp.img" ] && [ -z "${FORCE}" ]; then
    ok "esp.img exists ($(du -h esp.img | cut -f1))"
else
    log "Building esp.img (${ESP_SIZE_MB}MB FAT32)..."
    rm -f esp.img

    docker run --rm \
        -v "${SCRIPT_DIR}:/work" \
        alpine \
        sh -c '
            set -e
            apk add --no-cache mtools dosfstools > /dev/null 2>&1

            dd if=/dev/zero of=/work/esp.img bs=1M count='"${ESP_SIZE_MB}"' 2>/dev/null
            mkfs.vfat -F 32 /work/esp.img > /dev/null 2>&1

            mmd -i /work/esp.img ::EFI ::EFI/BOOT ::EFI/Linux ::loader ::loader/entries ::boot

            mcopy -i /work/esp.img /work/vmlinuz-virt ::EFI/Linux/linux.efi
            mcopy -i /work/esp.img /work/initramfs-virt ::EFI/Linux/initramfs
            mcopy -i /work/esp.img /work/modloop-virt ::boot/modloop-virt

            if [ -f /work/BOOTAA64.EFI ]; then
                mcopy -i /work/esp.img /work/BOOTAA64.EFI ::EFI/BOOT/BOOTAA64.EFI
            fi

            # GRUB config — Alpine ISO ships GRUB which looks for /boot/grub/grub.cfg
            cat > /tmp/grub.cfg << 'GRUBCFG'
set default=0
set timeout=0

menuentry "Alpine Virt" {
    linux /EFI/Linux/linux.efi console=hvc0 modules=loop,squashfs,sd-mod,usb-storage quiet
    initrd /EFI/Linux/initramfs
}
GRUBCFG
            mmd -i /work/esp.img ::boot ::boot/grub
            mcopy -i /work/esp.img /tmp/grub.cfg ::boot/grub/grub.cfg

            # Remove empty loader dirs (unused with GRUB)
            mdel -i /work/esp.img ::loader/loader.conf 2>/dev/null || true
            mdel -i /work/esp.img ::loader/entries/alpine.conf 2>/dev/null || true

            echo "=== ESP contents ==="
            mdir -i /work/esp.img -/ :: 2>/dev/null || true
        '
    ok "Built esp.img ($(du -h esp.img | cut -f1))"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  VM images ready!${NC}"
echo -e "${GREEN}  rootfs.img:     $(du -h rootfs.img | cut -f1)${NC}"
echo -e "${GREEN}  esp.img:        $(du -h esp.img | cut -f1)${NC}"
echo -e "${GREEN}  vmlinuz-virt:   $(du -h vmlinuz-virt | cut -f1)${NC}"
echo -e "${GREEN}  initramfs-virt: $(du -h initramfs-virt | cut -f1)${NC}"
echo -e "${GREEN}  BOOTAA64.EFI:  $(du -h BOOTAA64.EFI | cut -f1)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
