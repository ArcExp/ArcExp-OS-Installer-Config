#!/usr/bin/env bash

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'

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
    printf 'configure.sh called without all environment variables set!\n'
    exit 1
fi

# Set chosen locale and en_US.UTF-8 for it is required by some programs
echo "$OSI_LOCALE UTF-8" | sudo tee -a "$workdir/etc/locale.gen"

if [[ "$OSI_LOCALE" != 'en_US.UTF-8' ]]; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a "$workdir/etc/locale.gen"
fi

echo "LANG=\"$OSI_LOCALE\"" | sudo tee "$workdir/etc/locale.conf"

# Generate locales
sudo arch-chroot "$workdir" locale-gen

# Add dconf tweaks for GNOME desktop configuration
sudo cp -rv "$osidir/dconf-settings/dconf" "$workdir/etc/"
sudo arch-chroot "$workdir" dconf update

# Set hostname
echo 'ArcExp' | sudo tee "$workdir/etc/hostname"

# Add user, setup groups, set password, and set user properties
sudo arch-chroot "$workdir" useradd -m -s /bin/bash -p NP "$OSI_USER_NAME"
echo "$OSI_USER_NAME:$OSI_USER_PASSWORD" | sudo arch-chroot "$workdir" chpasswd
sudo arch-chroot "$workdir" usermod -a -G wheel "$OSI_USER_NAME"
sudo arch-chroot "$workdir" chage -M -1 "$OSI_USER_NAME"

# Add the user to the sudoers file
echo "$OSI_USER_NAME ALL=(ALL) ALL" | sudo arch-chroot "$workdir" tee -a /etc/sudoers

# Set timezone
sudo arch-chroot "$workdir" ln -sf "/usr/share/zoneinfo/$OSI_TIMEZONE" /etc/localtime

# Set Keymap
declare -r current_keymap=$(gsettings get org.gnome.desktop.input-sources sources)
printf "[org.gnome.desktop.input-sources]\nsources = $current_keymap\n" | sudo tee $workdir/etc/dconf/db/local.d/keymap

# Set auto-login if requested
if [[ "$OSI_USER_AUTOLOGIN" -eq 1 ]]; then
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$OSI_USER_NAME\n" | sudo tee "$workdir/etc/gdm/custom.conf"
fi

# Add multilib repository
printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | sudo tee -a "$workdir/etc/pacman.conf"

# Install steam
sudo arch-chroot "$workdir" pacman -S steam --noconfirm

# Create home directory and subdirectories
sudo arch-chroot "$workdir" mkdir -p "/home/$OSI_USER_NAME/Desktop" \
    "/home/$OSI_USER_NAME/Documents" \
    "/home/$OSI_USER_NAME/Downloads" \
    "/home/$OSI_USER_NAME/Music" \
    "/home/$OSI_USER_NAME/Pictures" \
    "/home/$OSI_USER_NAME/Public" \
    "/home/$OSI_USER_NAME/Templates" \
    "/home/$OSI_USER_NAME/Videos"

# Create 'Text File' in the 'Templates' directory
sudo arch-chroot "$workdir" touch "/home/$OSI_USER_NAME/Templates/Text File"

# Set ownership of the home directory
sudo arch-chroot "$workdir" chown -R "$OSI_USER_NAME:$OSI_USER_NAME" "/home/$OSI_USER_NAME"

# Import primary key and install keyring and mirrorlist
sudo arch-chroot "$workdir" pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
sudo arch-chroot "$workdir" pacman-key --lsign-key 3056513887B78AEB
sudo arch-chroot "$workdir" pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

# Append Chaotic-AUR repository to /etc/pacman.conf
echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | sudo tee -a "$workdir/etc/pacman.conf"

# Refresh package databases
sudo arch-chroot "$workdir" pacman -Sy --noconfirm

# Install packages from Chaotic-AUR
aur_packages=("yay" "extension-manager" "protonup-qt" "qbittorrent-enhanced" "xone-dkms" "xpadneo-dkms" "xone-dongle-firmware" "ttf-ms-fonts" "onlyoffice-bin" "lutris-git" "gamescope-git" "mangohud-git" "lib32-mangohud-git" "timeshift-autosnap" "backintime")

failed_packages=()
for package in "${aur_packages[@]}"; do
    sudo arch-chroot "$workdir" pacman -S --noconfirm "$package"
    if [ $? -ne 0 ]; then
        printf "Failed to install %s from Chaotic-AUR.\n" "$package"
        failed_packages+=("$package")
    fi
done

if [ ${#failed_packages[@]} -gt 0 ]; then
    echo "Failed to install the following AUR packages:"
    printf '%s\n' "${failed_packages[@]}"
fi

# Enable systemd services
sudo arch-chroot "$workdir" systemctl enable gdm.service NetworkManager.service fstrim.timer

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.discordapp.Discord

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.github.tchx84.Flatseal

# Remove Chaotic-AUR keys, keyring, and mirrorlist
sudo arch-chroot "$workdir" pacman -Rns --noconfirm chaotic-keyring

sudo arch-chroot "$workdir" pacman -Rns --noconfirm chaotic-mirrorlist

repo_name="chaotic-aur"

# Remove the repository section from pacman.conf
sudo sed -i "/^\[$repo_name\]/,/^$/d" "$workdir/etc/pacman.conf"

# Refresh package databases
sudo arch-chroot "$workdir" pacman -Sy --noconfirm

# Determine processor type and install microcode
proc_type=$(lscpu)
if grep -E "GenuineIntel" <<< ${proc_type}; then
    echo "Installing Intel microcode"
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed intel-ucode
    proc_ucode=intel-ucode.img
elif grep -E "AuthenticAMD" <<< ${proc_type}; then
    echo "Installing AMD microcode"
    sudo arch-chroot "$workdir" pacman -S --noconfirm --needed amd-ucode
    proc_ucode=amd-ucode.img
fi

# Determine and install graphics drivers
gpu_type=$(lspci)
if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
   if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings cuda bumblebee; then
        printf 'Failed to install NVIDIA drivers.\n'
        exit 1
   fi
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
   if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed xf86-video-amdgpu; then
        printf 'Failed to install AMD GPU drivers.\n'
        exit 1
   fi
elif grep -E "Integrated Graphics Controller" <<< ${gpu_type}; then
    if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa; then
        printf 'Failed to install Intel Integrated Graphics drivers.\n'
        exit 1
    fi
elif grep -E "Intel Corporation UHD" <<< ${gpu_type}; then
    if ! sudo arch-chroot "$workdir" pacman -S --needed --noconfirm libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa; then
        printf 'Failed to install Intel UHD Graphics drivers.\n'
        exit 1
    fi
fi

# Regenerate grub config file
sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg

# Finally, update system and exit script
sudo arch-chroot "$workdir" pacman -Syu

exit 0
