#!/usr/bin/env bash

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'
declare -r rootlabel='ArcExp'

# Function to display an error and exit
show_error() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

# Write partition table to the disk
if [[ ! -d "$workdir/sys/firmware/efi" ]]; then
    sudo sfdisk $OSI_DEVICE_PATH < "$osidir/misc/mbr.sfdisk"
else
    sudo sfdisk $OSI_DEVICE_PATH < "$osidir/misc/gpt.sfdisk"
fi

# NVMe drives follow a slightly different naming scheme to other block devices
# this will change `/dev/nvme0n1` to `/dev/nvme0n1p` for easier parsing later
if [[ $OSI_DEVICE_PATH == *"nvme"*"n"* ]]; then
	declare -r partition_path="${OSI_DEVICE_PATH}p"
else
	declare -r partition_path="${OSI_DEVICE_PATH}"
fi

# Function to create Btrfs subvolumes
create_btrfs_subvolumes() {
  local mount_point="$1"

  # Create root subvolume with properties
  sudo btrfs subvolume create "$mount_point/@"
  sudo btrfs property set "$mount_point/@" ro false
  sudo btrfs property set "$mount_point/@" noatime true
  sudo btrfs property set "$mount_point/@" compress zstd:1
  sudo btrfs property set "$mount_point/@" discard async
  sudo btrfs property set "$mount_point/@" space_cache v2
  sudo btrfs property set "$mount_point/@" commit 120

  # Create @home subvolume with properties
  sudo btrfs subvolume create "$mount_point/@home"
  sudo btrfs property set "$mount_point/@home" ro false
  sudo btrfs property set "$mount_point/@home" noatime true
  sudo btrfs property set "$mount_point/@home" compress zstd:1
  sudo btrfs property set "$mount_point/@home" discard async
  sudo btrfs property set "$mount_point/@home" space_cache v2
  sudo btrfs property set "$mount_point/@home" commit 120

  # Create @cache subvolume with properties
  sudo btrfs subvolume create "$mount_point/@cache"
  sudo btrfs property set "$mount_point/@cache" ro false
  sudo btrfs property set "$mount_point/@cache" noatime true
  sudo btrfs property set "$mount_point/@cache" compress zstd:1
  sudo btrfs property set "$mount_point/@cache" discard async
  sudo btrfs property set "$mount_point/@cache" space_cache v2
  sudo btrfs property set "$mount_point/@cache" commit 120

  # Create @log subvolume with properties
  sudo btrfs subvolume create "$mount_point/@log"
  sudo btrfs property set "$mount_point/@log" ro false
  sudo btrfs property set "$mount_point/@log" noatime true
  sudo btrfs property set "$mount_point/@log" compress zstd:1
  sudo btrfs property set "$mount_point/@log" discard async
  sudo btrfs property set "$mount_point/@log" space_cache v2
  sudo btrfs property set "$mount_point/@log" commit 120
}

# Check if encryption is requested, write filesystems accordingly
if [[ $OSI_USE_ENCRYPTION -eq 1 ]]; then

	# If user requested disk encryption
	if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then

		# If target is a drive
		sudo mkfs.fat -F32 ${partition_path}1
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup -q luksFormat ${partition_path}2
		echo $OSI_ENCRYPTION_PIN | sudo cryptsetup open ${partition_path}2 $rootlabel -
		sudo mkfs.btrfs -f -L $rootlabel /dev/mapper/$rootlabel

		sudo mount -o noatime,compress=zstd:1,discard=async,space_cache=v2,commit=120 /dev/mapper/$rootlabel "$workdir"
		sudo mount --mkdir ${partition_path}1 "$workdir/boot"
		
		# Call the function to create Btrfs subvolumes
    		create_btrfs_subvolumes "$workdir"

	else

		# If target is a partition
		printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
		exit 1
	fi

else

	# If no disk encryption requested
	if [[ $OSI_DEVICE_IS_PARTITION -eq 0 ]]; then

		# If target is a drive
		sudo mkfs.fat -F32 ${partition_path}1
		sudo mkfs.btrfs -f -L $rootlabel ${partition_path}2

		sudo mount -o noatime,compress=zstd:1,discard=async,space_cache=v2,commit=120 ${partition_path}2 "$workdir"
		sudo mount --mkdir ${partition_path}1 "$workdir/boot"
		
		# Call the function to create Btrfs subvolumes
    		create_btrfs_subvolumes "$workdir"

	else

		# If target is a partition
		printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
		exit 1
	fi

fi

# Install basic system packages
sudo pacstrap "$workdir" base sudo linux linux-headers linux-firmware

# Install remaining packages
sudo arch-chroot "$workdir" pacman -S --noconfirm eog fsarchiver firefox git gnome neofetch networkmanager network-manager-applet power-profiles-daemon flatpak xdg-user-dirs-gtk || show_error "Failed to install desktop environment packages"

# Function to check if a package is installed
is_package_installed() {
    sudo arch-chroot "$workdir" pacman -Q "$1" >/dev/null 2>&1
}

# Detect the virtualization platform
if [[ -n "$(lspci | grep -i vmware)" ]]; then
    VIRTUALIZATION="VMware"
elif [[ -n "$(lspci | grep -i virtualbox)" ]]; then
    VIRTUALIZATION="VirtualBox"
else
    VIRTUALIZATION="Unknown"
fi

# Install packages based on the detected virtualization platform
case "$VIRTUALIZATION" in
    "VMware")
        if ! is_package_installed "open-vm-tools"; then
            sudo arch-chroot "$workdir" pacman -Syyu --noconfirm open-vm-tools xf86-input-vmmouse xf86-video-vmware xf86-video-qxl
        fi
        ;;
    "VirtualBox")
        if ! is_package_installed "virtualbox-guest-utils"; then
            sudo arch-chroot "$workdir" pacman -Syyu --noconfirm virtualbox-guest-utils
        fi
        ;;
    *)
        echo "Unknown virtualization platform or no virtualization detected."
        ;;
esac

# Install common packages for guest agents
if ! is_package_installed "qemu-guest-agent" || ! is_package_installed "spice-vdagent"; then
    sudo arch-chroot "$workdir" pacman -Syyu --noconfirm qemu-guest-agent spice-vdagent
fi

# Determine processor type and install microcode
proc_type=$(lscpu)
if grep -E "GenuineIntel" <<< ${proc_type}; then
    echo "Installing Intel microcode"
    if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed intel-ucode; then
        printf 'Failed to install Intel microcode.\n'
        exit 1
    fi
    proc_ucode=intel-ucode.img
elif grep -E "AuthenticAMD" <<< ${proc_type}; then
    echo "Installing AMD microcode"
    if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed amd-ucode; then
        printf 'Failed to install AMD microcode.\n'
        exit 1
    fi
    proc_ucode=amd-ucode.img
fi

# Generate the fstab file
sudo genfstab -U "$workdir" | sudo tee "$workdir/etc/fstab" || show_error "Failed to generate fstab file"

# Install GRUB based on firmware type (UEFI or BIOS)
if [ -d "$workdir/sys/firmware/efi" ]; then
    # For UEFI systems
    sudo arch-chroot "$workdir" pacman -S --noconfirm grub efibootmgr os-prober grub-btrfs || show_error "Failed to install GRUB or related packages"
    sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory="/boot/efi" --bootloader-id=GRUB || show_error "Failed to install GRUB on NVME drive on UEFI system"
    sudo arch-chroot "$workdir" os-prober || show_error "Failed to run os-prober"
    sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file for UEFI system"
else
    # For BIOS systems
    sudo arch-chroot "$workdir" pacman -S --noconfirm grub os-prober grub-btrfs || show_error "Failed to install GRUB or related packages"
    sudo arch-chroot "$workdir" grub-install --target=i386-pc "$partition_path" || show_error "Failed to install GRUB on BIOS system"
    sudo arch-chroot "$workdir" os-prober || show_error "Failed to run os-prober"
    sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file for BIOS system"
fi

exit 0
