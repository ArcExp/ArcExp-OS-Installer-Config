#!/usr/bin/env bash

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'

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
   [ -z "${OSI_ENCRYPTION_PIN+x}" ] || \
   [ -z "${OSI_USER_NAME+x}" ] || \
   [ -z "${OSI_USER_AUTOLOGIN+x}" ] || \
   [ -z "${OSI_USER_PASSWORD+x}" ] || \
   [ -z "${OSI_FORMATS+x}" ] || \
   [ -z "${OSI_TIMEZONE+x}" ] || \
   [ -z "${OSI_ADDITIONAL_SOFTWARE+x}" ]
then
    show_error "configure.sh called without all environment variables set!"
fi

# Enable systemd services
for service in gdm NetworkManager fstrim.timer; do
    sudo arch-chroot "$workdir" systemctl enable "$service.service" || show_error "Failed to enable $service.service"
done

# Set locale and generate locales
echo "$OSI_LOCALE UTF-8" | sudo tee -a "$workdir/etc/locale.gen"
if [[ "$OSI_LOCALE" != 'en_US.UTF-8' ]]; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a "$workdir/etc/locale.gen"
fi
echo "LANG=\"$OSI_LOCALE\"" | sudo tee "$workdir/etc/locale.conf"
sudo arch-chroot "$workdir" locale-gen || show_error "Failed to generate locales"

# Add dconf tweaks for GNOME desktop configuration
sudo cp -rv "$osidir/dconf-settings/dconf" "$workdir/etc/" || show_error "Failed to copy dconf tweaks"
sudo arch-chroot "$workdir" dconf update || show_error "Failed to update dconf"

# Set hostname
echo 'ArcExp' | sudo tee "$workdir/etc/hostname"

# Add user, setup groups, set password, and set user properties
sudo arch-chroot "$workdir" useradd -m -s /bin/bash -p NP "$OSI_USER_NAME" || show_error "Failed to add user"
echo "$OSI_USER_NAME:$OSI_USER_PASSWORD" | sudo arch-chroot "$workdir" chpasswd || show_error "Failed to set user password"
sudo arch-chroot "$workdir" usermod -a -G wheel "$OSI_USER_NAME" || show_error "Failed to modify user group"
sudo arch-chroot "$workdir" chage -M -1 "$OSI_USER_NAME" || show_error "Failed to set user properties"
echo "$OSI_USER_NAME ALL=(ALL) ALL" | sudo arch-chroot "$workdir" tee -a /etc/sudoers || show_error "Failed to add user to sudoers"

# Set timezone
sudo arch-chroot "$workdir" ln -sf "/usr/share/zoneinfo/$OSI_TIMEZONE" /etc/localtime || show_error "Failed to set timezone"

# Set Keymap
sudo arch-chroot "$workdir" mkdir -p /etc/dconf/db/local.d/
current_keymap=$(gsettings get org.gnome.desktop.input-sources sources)
printf "[org.gnome.desktop.input-sources]\nsources = $current_keymap\n" | sudo tee "$workdir/etc/dconf/db/local.d/keymap"

# Set auto-login if requested
if [[ "$OSI_USER_AUTOLOGIN" -eq 1 ]]; then
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$OSI_USER_NAME\n" | sudo tee "$workdir/etc/gdm/custom.conf"
fi

# Add multilib repository
printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | sudo tee -a "$workdir/etc/pacman.conf"

# Install steam
sudo arch-chroot "$workdir" pacman -S steam --noconfirm || show_error "Failed to install Steam"

# Create home directory and subdirectories
home_subdirs=("Desktop" "Documents" "Downloads" "Music" "Pictures" "Public" "Templates" "Videos")
for subdir in "${home_subdirs[@]}"; do
    sudo arch-chroot "$workdir" mkdir -p "/home/$OSI_USER_NAME/$subdir" || show_error "Failed to create /home/$OSI_USER_NAME/$subdir"
done
sudo arch-chroot "$workdir" touch "/home/$OSI_USER_NAME/Templates/Text File" || show_error "Failed to create the Text File in the Templates directory"
sudo arch-chroot "$workdir" chown -R "$OSI_USER_NAME:$OSI_USER_NAME" "/home/$OSI_USER_NAME" || show_error "Failed to set ownership of home directory"

# Import primary key and install keyring and mirrorlist
sudo arch-chroot "$workdir" pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || show_error "Failed to import primary key"
sudo arch-chroot "$workdir" pacman-key --lsign-key 3056513887B78AEB || show_error "Failed to sign primary key"
sudo arch-chroot "$workdir" pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' || show_error "Failed to install keyring and mirrorlist"
echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | sudo tee -a "$workdir/etc/pacman.conf"
sudo arch-chroot "$workdir" pacman -Sy --noconfirm || show_error "Failed to refresh package databases"

# Install packages from Chaotic-AUR
aur_packages=("yay" "extension-manager" "protonup-qt" "qbittorrent-enhanced" "xone-dkms" "xpadneo-dkms" "xone-dongle-firmware" "ttf-ms-fonts" "onlyoffice-bin" "lutris-git" "gamescope-git" "mangohud-git" "lib32-mangohud-git")
for package in "${aur_packages[@]}"; do
    sudo arch-chroot "$workdir" pacman -S --noconfirm "$package" || show_error "Failed to install $package from Chaotic-AUR"
done

sudo arch-chroot "$workdir" flatpak install -y flathub com.discordapp.Discord
sudo arch-chroot "$workdir" flatpak install -y flathub com.github.tchx84.Flatseal

# Remove Chaotic-AUR keys, keyring, and mirrorlist
sudo arch-chroot "$workdir" pacman -Rns --noconfirm chaotic-keyring || show_error "Failed to remove chaotic-keyring"
sudo arch-chroot "$workdir" pacman -Rns --noconfirm chaotic-mirrorlist || show_error "Failed to remove chaotic-mirrorlist"

# Remove the repository section from pacman.conf
repo_name="chaotic-aur"
sudo sed -i "/^\[$repo_name\]/,/^$/d" "$workdir/etc/pacman.conf"
sudo arch-chroot "$workdir" pacman -Sy --noconfirm || show_error "Failed to refresh package databases"

# Determine processor type and install microcode
proc_type=$(lscpu)
if grep -E "GenuineIntel" <<< "${proc_type}"; then
    proc_ucode=intel-ucode.img
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed intel-ucode || show_error "Failed to install Intel microcode"
elif grep -E "AuthenticAMD" <<< "${proc_type}"; then
    proc_ucode=amd-ucode.img
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed amd-ucode || show_error "Failed to install AMD microcode"
fi

# Graphics Drivers find and install
gpu_type=$(lspci)
if grep -E "NVIDIA|GeForce" <<< "${gpu_type}"; then
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings cuda bumblebee || show_error "Failed to install NVIDIA drivers"
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed xf86-video-amdgpu || show_error "Failed to install AMD GPU drivers"
elif grep -E "Integrated Graphics Controller" <<< "${gpu_type}"; then
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa || show_error "Failed to install Intel Integrated Graphics drivers"
elif grep -E "Intel Corporation UHD" <<< "${gpu_type}"; then
    sudo arch-chroot "$workdir" pacman -S --needed --noconfirm libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa || show_error "Failed to install Intel UHD Graphics drivers"
fi

# Generate GRUB configuration file
sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || show_error "Failed to generate GRUB configuration file"

# Update system
sudo arch-chroot "$workdir" pacman -Syu || show_error "Failed to update the system"

exit 0
