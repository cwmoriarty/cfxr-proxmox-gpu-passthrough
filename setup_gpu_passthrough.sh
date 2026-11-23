#!/bin/bash
set -uo pipefail

# =============================================================================
# Proxmox GPU Passthrough Setup Script
# Automates IOMMU, VFIO, and GPU passthrough configuration on Proxmox VE.
# https://github.com/ColfaxResearch/cfxr-proxmox-gpu-passthrough
# =============================================================================

PATH="$PATH:/usr/sbin:/sbin"

VFIO_CONF="/etc/modprobe.d/vfio.conf"
GRUB_CONF="/etc/default/grub"
KERNEL_CMDLINE="/etc/kernel/cmdline"
MODULES_CONF="/etc/modules"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
header()  { echo -e "\n${CYAN}--- $* ---${NC}"; }

# --- Preflight checks ---
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root."
        exit 1
    fi
}

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command '$cmd' not found. Please install it."
            return 1
        fi
    done
}

confirm() {
    local msg="${1:-Continue?}"
    read -r -p "$(echo -e "${YELLOW}[?]${NC} ${msg} [y/N]: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

backup_file() {
    local f="$1"
    if [[ -f "$f" ]]; then
        local backup="${f}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$f" "$backup"
        info "Backed up $f -> $backup"
    fi
}

ensure_vfio_conf() {
    if [[ ! -f "$VFIO_CONF" ]]; then
        touch "$VFIO_CONF"
    fi
}

# --- Detect whether Proxmox uses systemd-boot (/etc/kernel/cmdline) or GRUB ---
is_systemd_boot() {
    [[ -f "$KERNEL_CMDLINE" ]] && command -v proxmox-boot-tool &>/dev/null && [[ -d /etc/kernel/pve-efiboot-uuids || -f /etc/kernel/proxmox-boot-uuids ]]
}

# --- Idempotent helpers for kernel cmdline iommu params ---
cmdline_add_param() {
    local param="$1"
    if is_systemd_boot; then
        if ! grep -qw "$param" "$KERNEL_CMDLINE"; then
            sed -i "1s/[[:space:]]*$/ ${param}/; 1s/^[[:space:]]*//" "$KERNEL_CMDLINE"
            info "Added '$param' to $KERNEL_CMDLINE."
        else
            warn "'$param' already present in $KERNEL_CMDLINE."
        fi
        return 0
    fi

    local line
    line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CONF" || true)
    if [[ -n "$line" ]]; then
        if ! echo "$line" | grep -qw "$param"; then
            # Append param inside quotes, avoiding a leading space if empty
            if echo "$line" | grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=""'; then
                sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${param}\"/" "$GRUB_CONF"
            else
                sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${param}\"/" "$GRUB_CONF"
            fi
            info "Added '$param' to GRUB cmdline."
        else
            warn "'$param' already present in GRUB cmdline."
        fi
    else
        error "GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB_CONF"
        return 1
    fi
}

cmdline_remove_param() {
    local param="$1"
    if is_systemd_boot; then
        if grep -qw "$param" "$KERNEL_CMDLINE"; then
            sed -i -E "s/(^|[[:space:]])${param}([[:space:]]|$)/\1/g; s/^[[:space:]]+//; s/[[:space:]]+$//" "$KERNEL_CMDLINE"
            info "Removed '$param' from $KERNEL_CMDLINE."
        fi
        return 0
    fi

    local line
    line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CONF" || true)
    if [[ -n "$line" ]] && echo "$line" | grep -qw "$param"; then
        sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/ { s/\"${param} /\"/; s/ ${param}\"/\"/; s/\"${param}\"/\"\"/; s/ ${param} / /g; }" "$GRUB_CONF"
        info "Removed '$param' from GRUB cmdline."
    fi
}

update_bootloader() {
    if is_systemd_boot; then
        info "Refreshing Proxmox boot tool..."
        proxmox-boot-tool refresh
    elif command -v update-grub &>/dev/null; then
        info "Updating GRUB..."
        update-grub
    else
        warn "Neither update-grub nor proxmox-boot-tool found; update bootloader manually."
    fi
}

# --- Idempotent helpers for /etc/modules ---
add_module() {
    local mod="$1"
    if ! grep -qx "$mod" "$MODULES_CONF"; then
        echo "$mod" >> "$MODULES_CONF"
    fi
}

remove_module() {
    local mod="$1"
    sed -i "/^${mod}$/d" "$MODULES_CONF"
}

# --- Idempotent helpers for softdep lines ---
add_softdep() {
    local driver="$1"
    local line="softdep ${driver} pre: vfio-pci"
    ensure_vfio_conf
    if ! grep -qxF "$line" "$VFIO_CONF"; then
        echo "$line" >> "$VFIO_CONF"
    fi
}

remove_softdep() {
    local driver="$1"
    if [[ -f "$VFIO_CONF" ]]; then
        sed -i "/^softdep ${driver} pre: vfio-pci$/d" "$VFIO_CONF"
    fi
}


# =============================================================================
# Option 1: Check VT-x/AMD-V and IOMMU
# =============================================================================
check_virtualization() {
    header "Checking CPU Virtualization & IOMMU"

    require_cmd lscpu dmesg || return

    local virt_type
    virt_type=$(lscpu | grep -i virtualization || true)

    if [[ "$virt_type" == *'VT-x'* ]]; then
        info "Intel VT-x virtualization is enabled."
    elif [[ "$virt_type" == *'AMD-V'* ]]; then
        info "AMD-V virtualization is enabled."
    else
        error "CPU virtualization is not enabled. Check BIOS/UEFI settings."
    fi

    # Check IOMMU - support multiple dmesg indicators
    if dmesg 2>/dev/null | grep -qE "DMAR-IR: Enabled IRQ remapping|AMD-Vi: Interrupt remapping enabled|IOMMU enabled|DMAR:.*IOMMU enabled"; then
        info "IOMMU/interrupt remapping is enabled."
    else
        warn "IOMMU remapping not detected in dmesg."
        warn "Check BIOS: enable VT-d (Intel) or AMD-Vi / IOMMU (AMD)."
        warn "If you just enabled it, you may need to reboot first."
    fi

    # Show IOMMU groups if available
    if [[ -d /sys/kernel/iommu_groups ]]; then
        local group_count
        group_count=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        if [[ "$group_count" -gt 0 ]]; then
            info "Found $group_count IOMMU groups."
        else
            warn "No IOMMU groups found. IOMMU may not be active."
        fi
    fi
}

# =============================================================================
# Option 2: Enable GPU Passthrough
# =============================================================================
enable_passthrough() {
    header "Enabling GPU Passthrough"

    require_root
    require_cmd lscpu lspci sed update-initramfs || return

    if ! confirm "This will modify bootloader, kernel modules, and modprobe configs. Continue?"; then
        warn "Aborted."
        return
    fi

    # --- Bootloader IOMMU params ---
    if is_systemd_boot; then
        backup_file "$KERNEL_CMDLINE"
    else
        backup_file "$GRUB_CONF"
    fi

    local cpu_info
    cpu_info=$(lscpu)
    if echo "$cpu_info" | grep -qi Intel; then
        cmdline_add_param "intel_iommu=on"
    elif echo "$cpu_info" | grep -qi AMD; then
        cmdline_add_param "amd_iommu=on"
    fi
    cmdline_add_param "iommu=pt"

    update_bootloader

    # --- Kernel modules ---
    backup_file "$MODULES_CONF"

    add_module "vfio"
    add_module "vfio_iommu_type1"
    add_module "vfio_pci"
    # vfio_virqfd is built-in on kernel >= 6.2, but needed as module on older kernels
    if [[ -f "/lib/modules/$(uname -r)/kernel/drivers/vfio/vfio_virqfd.ko" ]] || \
       [[ -f "/lib/modules/$(uname -r)/kernel/drivers/vfio/vfio_virqfd.ko.zst" ]]; then
        add_module "vfio_virqfd"
    fi
    info "VFIO kernel modules configured in $MODULES_CONF."

    # --- Detect GPU PCI IDs ---
    backup_file "$VFIO_CONF"
    ensure_vfio_conf

    local lspci_output
    lspci_output=$(lspci -nn)

    local gpu_lines
    gpu_lines=$(echo "$lspci_output" | grep -Ei "vga|3d|display|audio" | grep -i -e 'nvidia' -e 'AMD/ATI' || true)

    local device_ids
    device_ids=$(echo "$gpu_lines" \
        | sed -n 's/.*\[\([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\)\].*/\1/p' \
        | sort -u \
        | paste -sd ',' -)

    if [[ -n "$device_ids" ]]; then
        info "Found GPU PCI IDs: $device_ids"
        echo
        echo "$gpu_lines"
        echo

        # Set VFIO PCI IDs (idempotent)
        sed -i "/^options vfio-pci ids=/d" "$VFIO_CONF"
        echo "options vfio-pci ids=${device_ids}" >> "$VFIO_CONF"
    else
        warn "No NVIDIA or AMD/ATI GPUs detected."
        warn "You may need to manually add PCI IDs to $VFIO_CONF."
    fi

    # --- NVIDIA softdeps ---
    if echo "$gpu_lines" | grep -qi 'nvidia'; then
        info "NVIDIA GPU detected — adding driver softdeps."
        for drv in nouveau nvidia nvidiafb nvidia_drm drm; do
            remove_softdep "$drv"
            add_softdep "$drv"
        done
    fi

    # --- AMD/ATI softdeps ---
    if echo "$gpu_lines" | grep -qi 'AMD/ATI'; then
        info "AMD/ATI GPU detected — adding driver softdeps."
        for drv in radeon amdgpu snd_hda_intel; do
            remove_softdep "$drv"
            add_softdep "$drv"
        done
    fi

    # --- Update initramfs ---
    info "Updating initramfs..."
    update-initramfs -u

    echo
    info "Configuration complete. Review $VFIO_CONF:"
    echo
    cat "$VFIO_CONF"
    echo
    warn "A reboot is required for changes to take effect."
}


# =============================================================================
# Option 3: Verify GPU Passthrough
# =============================================================================
verify_passthrough() {
    header "Verifying GPU Passthrough"

    require_cmd lspci || return

    local gpu_bindings
    gpu_bindings=$(lspci -nnk 2>/dev/null | grep -A3 -Ei 'NVIDIA|AMD/ATI' || true)

    if [[ -z "$gpu_bindings" ]]; then
        warn "No NVIDIA or AMD/ATI GPUs found in lspci output."
        return
    fi

    if echo "$gpu_bindings" | grep -q 'vfio-pci'; then
        info "GPU passthrough is active — vfio-pci driver is bound:"
        echo
        echo "$gpu_bindings"
    else
        error "vfio-pci driver is NOT bound to the GPU(s)."
        echo
        echo "Current GPU driver bindings:"
        echo "$gpu_bindings"
        echo
        warn "Ensure softdep entries exist in $VFIO_CONF and reboot."
    fi
}

# =============================================================================
# Option 4: Compile VBIOS ROM (AMD GPUs via ACPI VFCT table)
# =============================================================================
compile_vbios() {
    header "Compiling VBIOS ROM from ACPI VFCT"

    require_root

    if ! require_cmd gcc; then
        error "gcc is required to compile the VBIOS extractor."
        warn "Install with: apt install build-essential"
        return
    fi

    if [[ ! -f /sys/firmware/acpi/tables/VFCT ]]; then
        error "/sys/firmware/acpi/tables/VFCT not found."
        warn "This is typically only available on AMD GPU systems."
        return
    fi

    if ! confirm "This will extract VBIOS ROM(s) from ACPI VFCT table. Continue?"; then
        warn "Aborted."
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d /tmp/vbios_extract.XXXXXX)

    cat << 'VBIOS_EOF' > "${tmpdir}/vbios.c"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t ULONG;
typedef uint8_t UCHAR;
typedef uint16_t USHORT;

typedef struct {
    ULONG Signature;
    ULONG TableLength;
    UCHAR Revision;
    UCHAR Checksum;
    UCHAR OemId[6];
    UCHAR OemTableId[8];
    ULONG OemRevision;
    ULONG CreatorId;
    ULONG CreatorRevision;
} AMD_ACPI_DESCRIPTION_HEADER;

typedef struct {
    AMD_ACPI_DESCRIPTION_HEADER SHeader;
    UCHAR TableUUID[16];
    ULONG VBIOSImageOffset;
    ULONG Lib1ImageOffset;
    ULONG Reserved[4];
} UEFI_ACPI_VFCT;

typedef struct {
    ULONG PCIBus;
    ULONG PCIDevice;
    ULONG PCIFunction;
    USHORT VendorID;
    USHORT DeviceID;
    USHORT SSVID;
    USHORT SSID;
    ULONG Revision;
    ULONG ImageLength;
} VFCT_IMAGE_HEADER;

typedef struct {
    VFCT_IMAGE_HEADER VbiosHeader;
    UCHAR VbiosContent[1];
} GOP_VBIOS_CONTENT;

int main(int argc, char** argv)
{
    FILE* fp_vfct;
    FILE* fp_vbios;
    UEFI_ACPI_VFCT* pvfct;
    char vbios_name[0x400];

    if (!(fp_vfct = fopen("/sys/firmware/acpi/tables/VFCT", "r"))) {
        perror(argv[0]);
        return -1;
    }
    if (!(pvfct = malloc(sizeof(UEFI_ACPI_VFCT)))) {
        perror(argv[0]);
        return -1;
    }
    if (sizeof(UEFI_ACPI_VFCT) != fread(pvfct, 1, sizeof(UEFI_ACPI_VFCT), fp_vfct)) {
        fprintf(stderr, "%s: failed to read VFCT header!\n", argv[0]);
        return -1;
    }

    ULONG offset = pvfct->VBIOSImageOffset;
    ULONG tbl_size = pvfct->SHeader.TableLength;

    if (!(pvfct = realloc(pvfct, tbl_size))) {
        perror(argv[0]);
        return -1;
    }
    if (tbl_size - sizeof(UEFI_ACPI_VFCT) != fread(pvfct + 1, 1, tbl_size - sizeof(UEFI_ACPI_VFCT), fp_vfct)) {
        fprintf(stderr, "%s: failed to read VFCT body!\n", argv[0]);
        return -1;
    }
    fclose(fp_vfct);

    while (offset < tbl_size) {
        GOP_VBIOS_CONTENT* vbios = (GOP_VBIOS_CONTENT*)((char*)pvfct + offset);
        VFCT_IMAGE_HEADER* vhdr = &vbios->VbiosHeader;

        if (!vhdr->ImageLength)
            break;

        snprintf(vbios_name, sizeof(vbios_name), "vbios_%x_%x.bin", vhdr->VendorID, vhdr->DeviceID);

        if (!(fp_vbios = fopen(vbios_name, "wb"))) {
            perror(argv[0]);
            return -1;
        }
        if (vhdr->ImageLength != fwrite(&vbios->VbiosContent, 1, vhdr->ImageLength, fp_vbios)) {
            fprintf(stderr, "%s: failed to dump vbios %x:%x\n", argv[0], vhdr->VendorID, vhdr->DeviceID);
            return -1;
        }
        fclose(fp_vbios);

        printf("Dumped vbios %x:%x -> %s\n", vhdr->VendorID, vhdr->DeviceID, vbios_name);

        offset += sizeof(VFCT_IMAGE_HEADER);
        offset += vhdr->ImageLength;
    }
    return 0;
}
VBIOS_EOF

    info "Compiling VBIOS extractor..."
    if ! gcc "${tmpdir}/vbios.c" -o "${tmpdir}/vbios"; then
        error "Compilation failed."
        rm -rf "$tmpdir"
        return
    fi

    info "Extracting VBIOS ROM(s)..."
    pushd "$tmpdir" > /dev/null
    if ! ./vbios; then
        error "VBIOS extraction failed."
        popd > /dev/null
        rm -rf "$tmpdir"
        return
    fi
    popd > /dev/null

    # Install each extracted VBIOS
    mkdir -p /usr/share/kvm
    local count=0
    for bin in "${tmpdir}"/vbios_*.bin; do
        [[ -f "$bin" ]] || continue
        local basename
        basename=$(basename "$bin")
        local dest="/usr/share/kvm/${basename}"
        backup_file "$dest"
        cp "$bin" "$dest"
        info "Installed: $dest"
        count=$((count + 1))
    done

    rm -rf "$tmpdir"

    if [[ $count -eq 0 ]]; then
        warn "No VBIOS images were extracted."
    else
        info "$count VBIOS ROM(s) installed to /usr/share/kvm/"
        echo
        echo "  Use in VM config:  -device vfio-pci,...,romfile=/usr/share/kvm/<filename>"
        echo "  Or in Proxmox GUI: Hardware -> PCI Device -> ROM-Bar + ROM file"
    fi
}


# =============================================================================
# Option 5: Revert Changes
# =============================================================================
revert_changes() {
    header "Reverting GPU Passthrough Configuration"

    require_root
    require_cmd sed update-initramfs || return

    if ! confirm "This will revert bootloader, kernel modules, and modprobe configs. Continue?"; then
        warn "Aborted."
        return
    fi

    # --- Revert bootloader cmdline params ---
    if is_systemd_boot; then
        backup_file "$KERNEL_CMDLINE"
    else
        backup_file "$GRUB_CONF"
    fi
    cmdline_remove_param "iommu=pt"
    cmdline_remove_param "intel_iommu=on"
    cmdline_remove_param "amd_iommu=on"

    update_bootloader

    # --- Revert kernel modules ---
    backup_file "$MODULES_CONF"
    remove_module "vfio"
    remove_module "vfio_iommu_type1"
    remove_module "vfio_pci"
    remove_module "vfio_virqfd"
    info "Removed VFIO modules from $MODULES_CONF."

    # --- Revert /etc/modprobe.d/vfio.conf ---
    if [[ -f "$VFIO_CONF" ]]; then
        backup_file "$VFIO_CONF"

        # Remove PCI IDs line
        sed -i "/^options vfio-pci ids=/d" "$VFIO_CONF"

        # Remove softdeps
        for drv in nouveau nvidia nvidiafb nvidia_drm drm radeon amdgpu snd_hda_intel; do
            remove_softdep "$drv"
        done

        if [[ ! -s "$VFIO_CONF" ]] || ! grep -qvE '^[[:space:]]*(#|$)' "$VFIO_CONF"; then
            info "No remaining custom rules in $VFIO_CONF."
        fi
        info "Cleaned up $VFIO_CONF."
    fi

    # --- Update initramfs ---
    info "Updating initramfs..."
    update-initramfs -u

    echo
    info "Revert complete."
    warn "Please reboot for changes to take effect."
}

# =============================================================================
# Main Menu
# =============================================================================
show_menu() {
    cat << 'EOF'

Enter a number to choose an option:

    1. Check if VT-x/AMD-V and IOMMU are enabled.
    2. Enable GPU passthrough.
    3. Verify GPU passthrough.
    4. Compile VBIOS ROM
    5. Revert changes.
    6. Quit.
EOF
}

main() {
    while true; do
        show_menu
        if ! read -r -p "Option: " option; then
            echo
            info "Exiting."
            break
        fi

        case "$option" in
            1)
                check_virtualization
                ;;
            2)
                enable_passthrough
                ;;
            3)
                verify_passthrough
                ;;
            4)
                compile_vbios
                ;;
            5)
                revert_changes
                ;;
            6)
                info "Exiting."
                break
                ;;
            *)
                error "Invalid option '$option'. Please enter a number between 1 and 6."
                ;;
        esac
    done
}

main "$@"
