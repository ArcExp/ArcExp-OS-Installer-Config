#!/usr/bin/env bash

# Enable debugging and log the output to a file
LOG_FILE="/tmp/install_script_log.txt"
exec > >(tee -a "$LOG_FILE") 2>&1
set -x

declare -r workdir='/mnt'
declare -r rootlabel='ArcExp_root'

# Function to display an error and exit
show_error() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

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

# Function to create partitions using gdisk
create_partition() {
    local fstype=$1
    local start=$2
    local end=$3
    sudo gdisk "$OSI_DEVICE_PATH" <<EOF
n
$start
$end
$fstype
w
Y
EOF
}

# Function to display partition table information
display_partition_table_info() {
    echo "Partition Table Information for $OSI_DEVICE_PATH:"
    sudo gdisk -l "$OSI_DEVICE_PATH"
    echo
}

# Determine the partition table type
if is_nvme_ssd "$OSI_DEVICE_PATH"; then
    # For NVMe SSD
    declare -r partition_table="gpt"

    # Write partition table to the disk
    if [ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]; then
        # Disk-level partitioning
        sudo gdisk "$OSI_DEVICE_PATH" --clear || show_error "Failed to create partition table on $OSI_DEVICE_PATH"

        # GPT partitioning for NVMe SSD
        # Create a 1GB EFI System Partition (ESP)
        create_partition ef00 2048s 1953791s   # 1GB EFI System Partition (ESP)
        create_partition 8300 1953792s -1s     # Remaining space for the root partition

        # Format the partitions
        sudo mkfs.fat -F32 "${OSI_DEVICE_PATH}p1" || show_error "Failed to create FAT32 filesystem on ${OSI_DEVICE_PATH}p1"
        sudo mkfs.btrfs -f -L "$rootlabel" "${OSI_DEVICE_PATH}p2" || show_error "Failed to create Btrfs filesystem on ${OSI_DEVICE_PATH}p2"
    fi
else
    # For other devices
    if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
        declare -r partition_table="msdos"
    else
        declare -r partition_table="gpt"
    fi

    # Write partition table to the disk
    if [ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]; then
        # Disk-level partitioning
        sudo gdisk "$OSI_DEVICE_PATH" --clear || show_error "Failed to create partition table on $OSI_DEVICE_PATH"

        # MBR partitioning for BIOS systems on physical hardware
        create_partition 8300 2048s -1s

        # Set boot flag on the partition (for BIOS systems)
        sudo gdisk "$OSI_DEVICE_PATH" <<EOF
x
a
2
w
Y
EOF
    fi
fi

# Check if encryption is requested, write filesystems accordingly
if [[ "$OSI_USE_ENCRYPTION" -eq 1 ]]; then
    # If user requested disk encryption
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        echo "$OSI_ENCRYPTION_PIN" | sudo cryptsetup -q luksFormat "${OSI_DEVICE_PATH}2" || show_error "Failed to format ${OSI_DEVICE_PATH}2 with LUKS"
        echo "$OSI_ENCRYPTION_PIN" | sudo cryptsetup open "${OSI_DEVICE_PATH}2" "$rootlabel" - || show_error "Failed to open ${OSI_DEVICE_PATH}2 with LUKS"
        sudo mkfs.btrfs -f "/dev/mapper/$rootlabel" || show_error "Failed to create Btrfs filesystem on /dev/mapper/$rootlabel"
    else
        # If target is a partition
        sudo mkfs.btrfs -f "$OSI_DEVICE_PATH" || show_error "Failed to create Btrfs filesystem on $OSI_DEVICE_PATH"
    fi
else
    # If no disk encryption requested
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        yes | sudo mkfs.btrfs -f "$OSI_DEVICE_PATH" || show_error "Failed to create Btrfs filesystem on $OSI_DEVICE_PATH"
    else
        # If target is a partition
        yes | sudo mkfs.btrfs -f "$OSI_DEVICE_PATH" || show_error "Failed to create Btrfs filesystem on $OSI_DEVICE_PATH"
    fi
fi

# Mount the root partition
sudo mkdir -p "$workdir" || show_error "Failed to create mount directory $workdir"

if is_nvme_ssd "$OSI_DEVICE_PATH"; then
    # For NVMe SSD
    if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
        # Non-EFI system
        sudo mount "${OSI_DEVICE_PATH}1" "$workdir" || show_error "Failed to mount ${OSI_DEVICE_PATH}1 to $workdir"
    else
        # EFI system
        sudo mount "${OSI_DEVICE_EFI_PARTITION}" "$workdir/boot/efi" || show_error "Failed to mount EFI partition to $workdir/boot/efi"
        sudo mount "${OSI_DEVICE_PATH}2" "$workdir" || show_error "Failed to mount ${OSI_DEVICE_PATH}2 to $workdir"
    fi
else
    # For other devices
    if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
        # Non-EFI system
        sudo mount "$OSI_DEVICE_PATH" "$workdir" || show_error "Failed to mount $OSI_DEVICE_PATH to $workdir"
    else
        # EFI system
        sudo mount "${OSI_DEVICE_EFI_PARTITION}" "$workdir/boot/efi" || show_error "Failed to mount EFI partition to $workdir/boot/efi"
        sudo mount "${OSI_DEVICE_PATH}2" "$workdir" || show_error "Failed to mount ${OSI_DEVICE_PATH}2 to $workdir"
    fi
fi

# Install system packages
sudo pacstrap "$workdir" base base-devel linux-zen linux-zen-headers linux-firmware dkms || show_error "Failed to install system packages"

# Populate the Arch Linux keyring inside chroot
sudo arch-chroot "$workdir" pacman-key --init || show_error "Failed to initialize Arch Linux keyring"
sudo arch-chroot "$workdir" pacman-key --populate archlinux || show_error "Failed to populate Arch Linux keyring"

# Install desktop environment packages
sudo arch-chroot "$workdir" pacman -S --noconfirm firefox fsarchiver gdm gedit git gnome-backgrounds gnome-calculator gnome-console gnome-control-center gnome-disk-utility gnome-font-viewer gnome-photos gnome-screenshot gnome-settings-daemon gnome-shell gnome-software gnome-text-editor gnome-tweaks gnu-netcat gpart gpm gptfdisk nautilus neofetch networkmanager network-manager-applet power-profiles-daemon dbus ostree bubblewrap glib2 libarchive flatpak xdg-user-dirs-gtk || show_error "Failed to install desktop environment packages"

# Install grub packages including os-prober
sudo arch-chroot "$workdir" pacman -S --noconfirm grub efibootmgr os-prober || show_error "Failed to install GRUB, efibootmgr, or os-prober"

# Install GRUB based on firmware type (UEFI or BIOS)
if [ -d "$workdir/sys/firmware/efi" ]; then
    # For UEFI systems
    sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory="/boot/efi" --bootloader-id=GRUB || show_error "Failed to install GRUB on NVME drive on UEFI system"
    sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file for UEFI system"
else
    # For BIOS systems
    sudo arch-chroot "$workdir" grub-install --target=i386-pc "$OSI_DEVICE_PATH" || show_error "Failed to install GRUB on BIOS system"
    sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file for BIOS system"
fi

# Run os-prober to collect information about other installed operating systems
sudo arch-chroot "$workdir" os-prober || show_error "Failed to run os-prober"

# Generate the fstab file
sudo genfstab -U "$workdir" | sudo tee "$workdir/etc/fstab" || show_error "Failed to generate fstab file"

exit 0
