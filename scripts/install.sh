#!/usr/bin/env bash

declare -r workdir='/mnt'

# Function to check if the device is an NVMe SSD
is_nvme_ssd() {
    local dev_name="${1##*/}"
    if [[ -L "/sys/block/$dev_name" ]]; then
        # Check if it's an NVMe device by checking the subsystem path
        local subsystem_path=$(readlink -f "/sys/block/$dev_name/device/subsystem")
        if [[ "$subsystem_path" == *"/nvme/"* ]]; then
            return 0
        fi
    fi
    return 1
}

# Check if all required environment variables are set
if [ -z "${OSI_LOCALE+x}" ] || \
   [ -z "${OSI_DEVICE_PATH+x}" ] || \
   [ -z "${OSI_DEVICE_IS_PARTITION+x}" ] || \
   [ -z "${OSI_DEVICE_EFI_PARTITION+x}" ] || \
   [ -z "${OSI_USE_ENCRYPTION+x}" ] || \
   [ -z "${OSI_ENCRYPTION_PIN+x}" ]
then
    printf 'install.sh called without all environment variables set!\n'
    exit 1
fi

# Check if something is already mounted to $workdir
if mountpoint -q "$workdir"; then
    printf '%s is already a mountpoint, unmount this directory and try again\n' "$workdir"
    exit 1
fi

# Determine the partition path and partition table type
if is_nvme_ssd "$OSI_DEVICE_PATH"; then
    # For NVMe SSD
    declare -r partition_path="${OSI_DEVICE_PATH}p"
    declare -r partition_table="gpt"
else
    # For other devices
    declare -r partition_path="${OSI_DEVICE_PATH}"
    if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
        declare -r partition_table="msdos"
    else
        declare -r partition_table="gpt"
    fi
fi

# Write partition table to the disk
if [ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]; then
    # Disk-level partitioning
    sudo parted "${OSI_DEVICE_PATH}" mklabel "$partition_table" --script

    if is_nvme_ssd "$OSI_DEVICE_PATH"; then
        # GPT partitioning for NVMe SSD
        create_partition() {
            sudo parted "$OSI_DEVICE_PATH" mkpart primary "$1" "$2" "$3" --script
        }

        create_partition fat32 1MiB 1GB
        sudo parted "$OSI_DEVICE_PATH" set 1 esp on
        sudo parted "$OSI_DEVICE_PATH" set 1 boot on
        create_partition btrfs 1GB 100%
    else
        # MBR partitioning for BIOS systems on physical hardware
        create_partition() {
            sudo parted "$OSI_DEVICE_PATH" mkpart primary "$1" "$2" 100% --script
            sudo parted "$OSI_DEVICE_PATH" set 1 boot on
        }

        if [[ "$partition_table" == "gpt" ]]; then
            create_partition btrfs 1MiB
        else
            create_partition btrfs 1MiB
        fi
    fi
fi

# Check if encryption is requested, write filesystems accordingly
if [[ "$OSI_USE_ENCRYPTION" -eq 1 ]]; then
    # If user requested disk encryption
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | sudo cryptsetup -q luksFormat "${partition_path}2"
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | sudo cryptsetup open "${partition_path}2" "$rootlabel" -
        sudo mkfs.btrfs -f "/dev/mapper/$rootlabel"
    else
        # If target is a partition
        sudo mkfs.btrfs -f "$partition_path"
    fi
else
    # If no disk encryption requested
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        yes | sudo mkfs.btrfs -f "$partition_path"
    else
        # If target is a partition
        yes | sudo mkfs.btrfs -f "$partition_path"
    fi
fi

# Mount the root partition
sudo mkdir -p "$workdir"
if is_nvme_ssd "$OSI_DEVICE_PATH"; then
    # For NVMe SSD
    if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
        # Non-EFI system
        sudo mount "${partition_path}2" "$workdir"
    else
        # EFI system
        sudo mount "${OSI_DEVICE_EFI_PARTITION}" "$workdir/boot/efi"
        sudo mount "${partition_path}3" "$workdir"
    fi
else
    # For other devices
    if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
        # Non-EFI system
        sudo mount "$partition_path" "$workdir"
    else
        # EFI system
        sudo mount "${OSI_DEVICE_EFI_PARTITION}" "$workdir/boot/efi"
        sudo mount "${partition_path}2" "$workdir"
    fi
fi

# Function to check if the device is an NVMe SSD
is_nvme_ssd() {
    local dev_name="${1##*/}"
    if [[ -L "/sys/block/$dev_name" ]]; then
        # Check if it's an NVMe device by checking the subsystem path
        local subsystem_path=$(readlink -f "/sys/block/$dev_name/device/subsystem")
        if [[ "$subsystem_path" == *"/nvme/"* ]]; then
            return 0
        fi
    fi
    return 1
}

# Install GRUB based on firmware type (BIOS or UEFI)
if [ -d "$workdir/sys/firmware/efi" ]; then
    # UEFI system
    sudo arch-chroot "$workdir" pacman -S --noconfirm grub efibootmgr os-prober

    if is_nvme_ssd "$OSI_DEVICE_PATH"; then
        # For NVMe SSD on UEFI
        sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    else
        # For other UEFI systems
        sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    fi
else
    # BIOS system
    sudo arch-chroot "$workdir" pacman -S --noconfirm grub os-prober

    if is_nvme_ssd "$OSI_DEVICE_PATH"; then
        # For NVMe SSD on BIOS
        sudo arch-chroot "$workdir" grub-install --target=i386-pc "$OSI_DEVICE_PATH"
    else
        # For other BIOS systems
        sudo arch-chroot "$workdir" grub-install --target=i386-pc "$OSI_DEVICE_PATH"
    fi
fi

# Generate the GRUB configuration file
sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg

# Generate the fstab file
sudo genfstab -U "$workdir" | sudo tee "$workdir/etc/fstab"

# Install system packages
sudo pacstrap "$workdir" base base-devel linux-zen linux-zen-headers linux-firmware dkms

# Populate the Arch Linux keyring inside chroot
sudo arch-chroot "$workdir" pacman-key --init
sudo arch-chroot "$workdir" pacman-key --populate archlinux

# Install desktop environment packages
sudo arch-chroot "$workdir" pacman -S --noconfirm firefox fsarchiver gdm gedit git gnome-backgrounds gnome-calculator gnome-console gnome-control-center gnome-disk-utility gnome-font-viewer gnome-logs gnome-photos gnome-screenshot gnome-settings-daemon gnome-shell gnome-software gnome-text-editor gnome-tweaks gnu-netcat gpart gpm gptfdisk nautilus neofetch networkmanager network-manager-applet power-profiles-daemon dbus ostree bubblewrap glib2 libarchive flatpak xdg-user-dirs-gtk

exit 0
