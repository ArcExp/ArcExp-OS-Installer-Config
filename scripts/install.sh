#!/usr/bin/env bash

declare -r workdir='/mnt'

# Function to display an error and exit
show_error() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

# Check if all required environment variables are set
if [ -z "${OSI_LOCALE+x}" ] || \
   [ -z "${OSI_DEVICE_PATH+x}" ] || \
   [ -z "${OSI_DEVICE_IS_PARTITION+x}" ] || \
   [ -z "${OSI_DEVICE_EFI_PARTITION+x}" ] || \
   [ -z "${OSI_USE_ENCRYPTION+x}" ] || \
   [ -z "${OSI_ENCRYPTION_PIN+x}" ]
then
    show_error "install.sh called without all environment variables set!"
fi

# Check if something is already mounted to $workdir
if mountpoint -q "$workdir"; then
    show_error "$workdir is already a mountpoint, unmount this directory and try again"
fi

# Determine the partition table type and boot partition number
partition_table=$(lsblk -no "PARTTYPENAME" "${OSI_DEVICE_PATH}")

if [[ $partition_table == "gpt" ]]; then
    declare -r boot_partition_number=2
elif [[ $partition_table == "dos" ]]; then
    declare -r boot_partition_number=1
else
    show_error "Unknown partition table type: $partition_table"
fi

# Write partition table to the disk
if [ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]; then
    # Disk-level partitioning
    sudo parted "${OSI_DEVICE_PATH}" mklabel "$partition_table" --script || show_error "Failed to create partition table on $OSI_DEVICE_PATH"

    # Create partitions
    create_partition() {
        sudo parted "$OSI_DEVICE_PATH" mkpart primary "$1" "$2" --script || show_error "Failed to create $1 partition on $OSI_DEVICE_PATH"
    }

    if [[ $partition_table == "dos" ]]; then
        create_partition fat32 1MiB 1GB
        sudo parted "$OSI_DEVICE_PATH" set $boot_partition_number boot on || show_error "Failed to set boot flag on /boot partition"
    else
        create_partition fat32 1MiB 513MiB
        sudo parted "$OSI_DEVICE_PATH" set $boot_partition_number esp on || show_error "Failed to set ESP flag on /boot/efi partition"
    fi
    create_partition btrfs 513MiB 100%
fi

# Check if encryption is requested, write filesystems accordingly
if [[ "$OSI_USE_ENCRYPTION" -eq 1 ]]; then
    # If user requested disk encryption
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | sudo cryptsetup -q luksFormat "${OSI_DEVICE_PATH}${boot_partition_number}" || show_error "Failed to format ${OSI_DEVICE_PATH}${boot_partition_number} with LUKS"
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | sudo cryptsetup open "${OSI_DEVICE_PATH}${boot_partition_number}" "$rootlabel" - || show_error "Failed to open ${OSI_DEVICE_PATH}${boot_partition_number} with LUKS"
        sudo mkfs.btrfs -f "/dev/mapper/$rootlabel" || show_error "Failed to create Btrfs filesystem on /dev/mapper/$rootlabel"
    else
        # If target is a partition
        sudo mkfs.btrfs -f "${OSI_DEVICE_PATH}${boot_partition_number}" || show_error "Failed to create Btrfs filesystem on ${OSI_DEVICE_PATH}${boot_partition_number}"
    fi
else
    # If no disk encryption requested
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        yes | sudo mkfs.btrfs -f "${OSI_DEVICE_PATH}${boot_partition_number}" || show_error "Failed to create Btrfs filesystem on ${OSI_DEVICE_PATH}${boot_partition_number}"
    else
        # If target is a partition
        yes | sudo mkfs.btrfs -f "${OSI_DEVICE_PATH}${boot_partition_number}" || show_error "Failed to create Btrfs filesystem on ${OSI_DEVICE_PATH}${boot_partition_number}"
    fi
fi

# Mount the root partition
sudo mkdir -p "$workdir" || show_error "Failed to create mount directory $workdir"
sudo mount "${OSI_DEVICE_PATH}${boot_partition_number}" "$workdir" || show_error "Failed to mount ${OSI_DEVICE_PATH}${boot_partition_number} to $workdir"

# Mount the EFI partition for UEFI systems
if [[ $partition_table == "gpt" ]]; then
    sudo mkdir -p "$workdir/boot/efi" || show_error "Failed to create directory $workdir/boot/efi"
    sudo mount "$OSI_DEVICE_EFI_PARTITION" "$workdir/boot/efi" || show_error "Failed to mount EFI partition to $workdir/boot/efi"
fi

# Install system packages
sudo pacstrap "$workdir" base base-devel linux-zen linux-zen-headers linux-firmware dkms

# Populate the Arch Linux keyring inside chroot
sudo arch-chroot "$workdir" pacman-key --init || show_error "Failed to initialize Arch Linux keyring"
sudo arch-chroot "$workdir" pacman-key --populate archlinux || show_error "Failed to populate Arch Linux keyring"

# Install desktop environment packages
sudo arch-chroot "$workdir" pacman -S --noconfirm firefox fsarchiver gdm gedit git gnome-backgrounds gnome-calculator gnome-console gnome-control-center gnome-disk-utility gnome-font-viewer gnome-logs gnome-photos gnome-screenshot gnome-settings-daemon gnome-shell gnome-software gnome-text-editor gnome-tweaks gnu-netcat gpart gpm gptfdisk nautilus neofetch networkmanager network-manager-applet power-profiles-daemon dbus ostree bubblewrap glib2 libarchive flatpak xdg-user-dirs-gtk || show_error "Failed to install desktop environment packages"

# Install grub packages including os-prober
sudo arch-chroot "$workdir" pacman -S --noconfirm grub efibootmgr os-prober || show_error "Failed to install GRUB, efibootmgr, or os-prober"

# Install GRUB based on firmware type (UEFI or BIOS)
if [ -d "$workdir/sys/firmware/efi" ]; then
    # For UEFI systems
    sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory="$workdir/boot/efi" --bootloader-id=GRUB || show_error "Failed to install GRUB for NVMe SSD on UEFI"
else
    # For BIOS systems
    sudo arch-chroot "$workdir" grub-install --target=i386-pc "$OSI_DEVICE_PATH" || show_error "Failed to install GRUB for NVMe SSD on BIOS"
fi

# Run os-prober to collect information about other installed operating systems
sudo arch-chroot "$workdir" os-prober || show_error "Failed to run os-prober"

# Generate the fstab file
sudo genfstab -U "$workdir" | sudo tee "$workdir/etc/fstab" || show_error "Failed to generate fstab file"

# Generate the GRUB configuration file
sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file"

exit 0
