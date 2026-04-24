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

# ── Extract vsock modules from modloop ───────────────────────
#
# The Alpine virt kernel includes vsock as loadable modules in modloop.
# We extract them into the rootfs so they can be loaded at boot time
# for the vsock RPC exec bridge.

VSOCK_MOD_DIR="${SCRIPT_DIR}/vsock_modules"
if [ -d "${VSOCK_MOD_DIR}" ] && [ -z "${FORCE}" ]; then
    ok "vsock modules already extracted"
else
    log "Extracting vsock modules from modloop..."
    rm -rf "${VSOCK_MOD_DIR}"
    if command -v unsquashfs &>/dev/null; then
        unsquashfs -f -d "${VSOCK_MOD_DIR}" modloop-virt \
            modules/6.12.13-0-virt/kernel/net/vmw_vsock/vsock.ko \
            modules/6.12.13-0-virt/kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko \
            modules/6.12.13-0-virt/kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko
        # Clean up squashfs-root meta-dir
        rm -rf "${SCRIPT_DIR}/squashfs-root"
        ok "Extracted vsock modules ($(ls "${VSOCK_MOD_DIR}"/modules/*/kernel/net/vmw_vsock/*.ko 2>/dev/null | wc -l | tr -d ' ') files)"
    else
        err "unsquashfs not found. Install with: brew install squashfs"
        exit 1
    fi
fi

# ── Build vm-exec-daemon (static C binary) ───────────────────
#
# Compiles inside Alpine Docker (aarch64) to match VM architecture.
# Static linking means zero runtime dependencies.

DAEMON_SRC="${SCRIPT_DIR}/vm_exec_daemon.c"
DAEMON_BIN="${SCRIPT_DIR}/vm-exec-daemon"

if [ -f "${DAEMON_BIN}" ] && [ -z "${FORCE}" ]; then
    ok "vm-exec-daemon already compiled ($(du -h "${DAEMON_BIN}" | cut -f1))"
else
    log "Compiling vm-exec-daemon (static, aarch64)..."
    docker run --rm \
        -v "${SCRIPT_DIR}:/work" \
        --platform linux/arm64 \
        alpine:"${ALPINE_VERSION}" \
        sh -c '
            apk add --no-cache gcc musl-dev linux-headers > /dev/null 2>&1
            gcc -static -O2 -Wall -Wextra -o /work/vm-exec-daemon /work/vm_exec_daemon.c
        '
    # Verify it's a static aarch64 binary
    file "${DAEMON_BIN}" | grep -q "statically linked" || {
        err "vm-exec-daemon is not statically linked"
        exit 1
    }
    ok "Compiled vm-exec-daemon ($(du -h "${DAEMON_BIN}" | cut -f1))"
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

            # ── Install vsock kernel modules ──
            MOD_DEST="${ROOTFS}/lib/modules/6.12.13-0-virt/kernel"
            mkdir -p "${MOD_DEST}/net/vmw_vsock" "${MOD_DEST}/drivers/vhost"
            cp /work/vsock_modules/modules/6.12.13-0-virt/kernel/net/vmw_vsock/vsock.ko \
               "${MOD_DEST}/net/vmw_vsock/"
            cp /work/vsock_modules/modules/6.12.13-0-virt/kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko \
               "${MOD_DEST}/net/vmw_vsock/"
            cp /work/vsock_modules/modules/6.12.13-0-virt/kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko \
               "${MOD_DEST}/net/vmw_vsock/"
            # depmod needs the module tree layout
            mkdir -p "${ROOTFS}/lib/modules/6.12.13-0-virt"
            chroot "${ROOTFS}" depmod -a 6.12.13-0-virt 2>/dev/null || true

            # ── Install vm-exec-daemon ──
            cp /work/vm-exec-daemon "${ROOTFS}/usr/bin/vm-exec-daemon"
            chmod 755 "${ROOTFS}/usr/bin/vm-exec-daemon"

            # ── Add init script to load vsock + start daemon ──
            cat > "${ROOTFS}/etc/local.d/vsock.start" << "VSOCKINIT"
#!/bin/sh
# Load vsock kernel modules (order matters)
insmod /lib/modules/$(uname -r)/kernel/net/vmw_vsock/vsock.ko 2>/dev/null
insmod /lib/modules/$(uname -r)/kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko 2>/dev/null
insmod /lib/modules/$(uname -r)/kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko 2>/dev/null
# Start the exec daemon (listens on vsock port 1234)
/usr/bin/vm-exec-daemon &
echo "[vsock] exec daemon started on vsock://1234"
VSOCKINIT
            chmod 755 "${ROOTFS}/etc/local.d/vsock.start"

            # Enable local service (runs scripts in /etc/local.d/)
            chroot "${ROOTFS}" rc-update add local default 2>/dev/null || true

            # Summary
            echo "=== Python ==="
            chroot "${ROOTFS}" python3 --version 2>&1
            echo "=== vsock modules ==="
            ls -la "${ROOTFS}/lib/modules/6.12.13-0-virt/kernel/net/vmw_vsock/" 2>&1
            echo "=== vm-exec-daemon ==="
            ls -la "${ROOTFS}/usr/bin/vm-exec-daemon" 2>&1
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
            mmd -i /work/esp.img ::boot/grub 2>/dev/null || true
            mcopy -i /work/esp.img /tmp/grub.cfg ::boot/grub/grub.cfg
            # Verify grub.cfg was written
            if ! mcopy -i /work/esp.img ::boot/grub/grub.cfg /dev/null 2>/dev/null; then
                echo "FATAL: grub.cfg was not written to ESP!"
                exit 1
            fi

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
