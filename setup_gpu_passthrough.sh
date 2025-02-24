#!/bin/bash

while true; do
    cat << EOF

Enter a number to choose an option:

    1. Check if VT-x/AMD-V and IOMMU are enabled.
    2. Enable GPU passthrough.
    3. Verify GPU passthrough.
    4. Compile VBIOS ROM
    5. Revert changes.
    6. Quit.
EOF

    read -p "Option: " option

    if [ $option -eq 1 ]; then
        virt_type=$(lscpu | grep -i virtualization)
        if [[ $virt_type == *'VT-x'* || $virt_type == *'AMD-V'* ]]; then
            echo "Virtualization is enabled."
        else
            echo "CPU virtualization is currently not enabled. Please check BIOS settings to see if the feature is enabled."
        fi

        if dmesg | grep -q "AMD-Vi: Interrupt remapping enabled" || dmesg | grep -q "DMAR-IR: Enabled IRQ remapping in x2apic mode"; then
            echo "IOMMU remapping is enabled."
        else
            echo "IOMMU remapping is currently not enabled. Please check BIOS settings to see if the feature is enabled."
        fi

    elif [ $option -eq 2 ]; then
        if lscpu | grep -q Intel; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/g' /etc/default/grub
        elif lscpu | grep -q AMD; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"/g' /etc/default/grub
        fi

        /usr/sbin/update-grub

        # Add required kernel Modules (once)
        sed -i '/^vfio/d' /etc/modules
        sed -i '/^vfio_iommu_type1/d' /etc/modules
        sed -i '/^vfio_pci/d' /etc/modules
        echo vfio >> /etc/modules
        echo vfio_iommu_type1 >> /etc/modules
        echo vfio_pci >> /etc/modules


        device_ids=$(lspci -nn | grep -Ei "vga|3d|audio" | grep -i -e 'nvidia' -e 'AMD/ATI' | sed -n 's/.*\[\([0-9a-fA-F:]*\)\].*/\1/p' | sed ':a;N;$!ba;s/\n/,/')
        if [ "$device_ids" ]; then
            echo "Found PCI IDs: $device_ids"
            echo
            lspci -nn | grep -Ei 'vga|3d|audio' | grep -i -e 'nvidia' -e 'AMD/ATI'

            sed -i "/^options vfio-pci ids=/d" /etc/modprobe.d/vfio.conf         # Delete any prior VFIO-PCI IDs
            echo "options vfio-pci ids=$device_ids" >> /etc/modprobe.d/vfio.conf

        fi

        nvidia=$(lspci -nn | grep -Ei "vga|3d|audio" | grep -i 'nvidia')
        if [ "$nvidia" ]; then
            sed -i '/softdep nouveau pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            sed -i '/softdep nvidia pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            sed -i '/softdep nvidiafb pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            sed -i '/softdep nvidia_drm pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            sed -i '/softdep drm pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            echo "softdep nouveau pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
            echo "softdep nvidia pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
            echo "softdep nvidiafb pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
            echo "softdep nvidia_drm pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
            echo "softdep drm pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
        fi

        ati=$(lspci -nn | grep -Ei "vga|3d|audio" | grep -i 'AMD/ATI')
        if [ "$ati" ]; then
            sed -i '/softdep radeon pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            sed -i '/softdep amdgpu pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            sed -i '/softdep snd_hda_intel pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
            echo "softdep radeon pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
            echo "softdep amdgpu pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
            echo "softdep snd_hda_intel pre: vfio-pci" >> /etc/modprobe.d/vfio.conf
        fi

        /usr/sbin/update-initramfs -u

        echo "Verify '/etc/modprobe.d/vfio.conf' looks okay, then reboot:"
        echo
        cat /etc/modprobe.d/vfio.conf


    elif [ $option -eq 3 ]; then
        if lspci -nnk 2>/dev/null | grep -A1 -e NVIDIA -e 'AMD/ATI' | grep -q vfio-pci; then
            echo "GPU passthrough successfully enabled:"
            echo
            lspci -nnk 2>/dev/null | grep -A1 -e NVIDIA -e 'AMD/ATI'
        else
            echo "ERROR: vfio driver is not bound to the GPU(s)."
            echo "Check that the following have 'softdep XXX pre: vfio-pci' entries in /etc/modprobe.d/vfio.conf (or reboot)."
            echo
            echo lspci -nnk 2>/dev/null | grep -A1 -e NVIDIA -e 'AMD/ATI'
        fi

    elif [ $option -eq 4 ]; then

cat << 'EOF' > vbios.c
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t ULONG;
typedef uint8_t UCHAR;
typedef uint16_t USHORT;

typedef struct {
    ULONG Signature;
    ULONG TableLength; // Length
    UCHAR Revision;
    UCHAR Checksum;
    UCHAR OemId[6];
    UCHAR OemTableId[8]; // UINT64  OemTableId;
    ULONG OemRevision;
    ULONG CreatorId;
    ULONG CreatorRevision;
} AMD_ACPI_DESCRIPTION_HEADER;

typedef struct {
    AMD_ACPI_DESCRIPTION_HEADER SHeader;
    UCHAR TableUUID[16]; // 0x24
    ULONG VBIOSImageOffset; // 0x34. Offset to the first GOP_VBIOS_CONTENT block from the beginning of the stucture.
    ULONG Lib1ImageOffset; // 0x38. Offset to the first GOP_LIB1_CONTENT block from the beginning of the stucture.
    ULONG Reserved[4]; // 0x3C
} UEFI_ACPI_VFCT;

typedef struct {
    ULONG PCIBus; // 0x4C
    ULONG PCIDevice; // 0x50
    ULONG PCIFunction; // 0x54
    USHORT VendorID; // 0x58
    USHORT DeviceID; // 0x5A
    USHORT SSVID; // 0x5C
    USHORT SSID; // 0x5E
    ULONG Revision; // 0x60
    ULONG ImageLength; // 0x64
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

        printf("dump vbios %x:%x to %s\n", vhdr->VendorID, vhdr->DeviceID, vbios_name);

        offset += sizeof(VFCT_IMAGE_HEADER);
        offset += vhdr->ImageLength;
    }

    return 0;
}
EOF
gcc vbios.c -o vbios
./vbios
rm vbios.c -f
mv vbios_*.bin /usr/share/kvm/vbios-custom.bin
echo " Use ',romfile=vbios-custom.bin' in your VM."
    elif [ $option -eq 5 ]; then
        sed -i 's/ iommu=pt//' /etc/default/grub
        sed -i 's/ intel_iommu=on//' /etc/default/grub
        sed -i 's/ amd_iommu=on//' /etc/default/grub

        /usr/sbin/update-grub

        sed -i '/vfio/d' /etc/modules
        sed -i '/vfio_iommu_type1/d' /etc/modules
        sed -i '/vfio_pci/d' /etc/modules

        # Clean up /etc/modprobe.d/vfio.conf
        sed -i "/^options vfio-pci ids=/d" /etc/modprobe.d/vfio.conf
        sed -i '/softdep nouveau pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep nvidia pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep nvidiafb pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep nvidia_drm pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep drm pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep radeon pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep amdgpu pre: vfio-pci/d' /etc/modprobe.d/vfio.conf
        sed -i '/softdep snd_hda_intel pre: vfio-pci/d' /etc/modprobe.d/vfio.conf

        /usr/sbin/update-initramfs -u

        echo "Please reboot to revert changes."

    elif [ $option -eq 6 ]; then
        break
    fi
done
