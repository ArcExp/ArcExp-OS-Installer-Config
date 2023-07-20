#!/usr/bin/env bash

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

# Enable systemd services
if ! sudo arch-chroot "$workdir" systemctl enable gdm.service NetworkManager.service fstrim.timer; then
    printf 'Failed to enable systemd services.\n'
    exit 1
fi

# Set chosen locale and en_US.UTF-8 for it is required by some programs
echo "$OSI_LOCALE UTF-8" | sudo tee -a "$workdir/etc/locale.gen"

if [[ "$OSI_LOCALE" != 'en_US.UTF-8' ]]; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a "$workdir/etc/locale.gen"
fi

echo "LANG=\"$OSI_LOCALE\"" | sudo tee "$workdir/etc/locale.conf"

# Generate locales
if ! sudo arch-chroot "$workdir" locale-gen; then
    printf 'Failed to generate locales.\n'
    exit 1
fi

# Add dconf tweaks for GNOME desktop configuration
if ! sudo cp -rv "$osidir/dconf-settings/dconf" "$workdir/etc/"; then
    printf 'Failed to copy dconf tweaks.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" dconf update; then
    printf 'Failed to update dconf.\n'
    exit 1
fi

# Set hostname
echo 'ArcExp' | sudo tee "$workdir/etc/hostname"

# Add user, setup groups, set password, and set user properties
if ! sudo arch-chroot "$workdir" useradd -m -s /bin/bash -p NP "$OSI_USER_NAME"; then
    printf 'Failed to add user.\n'
    exit 1
fi

echo "$OSI_USER_NAME:$OSI_USER_PASSWORD" | sudo arch-chroot "$workdir" chpasswd

if ! sudo arch-chroot "$workdir" usermod -a -G wheel "$OSI_USER_NAME"; then
    printf 'Failed to modify user group.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" chage -M -1 "$OSI_USER_NAME"; then
    printf 'Failed to set user properties.\n'
    exit 1
fi

# Add the user to the sudoers file
echo "$OSI_USER_NAME ALL=(ALL) ALL" | sudo arch-chroot "$workdir" tee -a /etc/sudoers

# Set timezone
if ! sudo arch-chroot "$workdir" ln -sf "/usr/share/zoneinfo/$OSI_TIMEZONE" /etc/localtime; then
    printf 'Failed to set timezone.\n'
    exit 1
fi

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
if ! sudo arch-chroot "$workdir" pacman -S steam --noconfirm; then
    printf 'Failed to install Steam.\n'
    exit 1
fi

# Create home directory
if ! sudo arch-chroot "$workdir" mkdir -p "/home/$OSI_USER_NAME/{Desktop,Documents,Downloads,Music,Pictures,Public,Templates,Videos}"; then
    printf 'Failed to create home directory.\n'
    exit 1
fi

# Set ownership of the home directory
if ! sudo arch-chroot "$workdir" chown -R "$OSI_USER_NAME:$OSI_USER_NAME" "/home/$OSI_USER_NAME"; then
    printf 'Failed to set ownership of home directory.\n'
    exit 1
fi

# Import primary key and install keyring and mirrorlist
if ! sudo arch-chroot "$workdir" pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com; then
    printf 'Failed to import primary key.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" pacman-key --lsign-key 3056513887B78AEB; then
    printf 'Failed to sign primary key.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'; then
    printf 'Failed to install keyring and mirrorlist.\n'
    exit 1
fi

# Append Chaotic-AUR repository to /etc/pacman.conf
echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | sudo tee -a "$workdir/etc/pacman.conf"

# Refresh package databases
if ! sudo arch-chroot "$workdir" pacman -Sy --noconfirm; then
    printf 'Failed to refresh package databases.\n'
    exit 1
fi

# Install packages from Chaotic-AUR
if ! sudo arch-chroot "$workdir" pacman -S --noconfirm yay extension-manager protonup-qt qbittorrent-enhanced xone-dkms xpadneo-dkms xone-dongle-firmware ttf-ms-fonts onlyoffice-bin lutris-git gamescope-git mangohud-git lib32-mangohud-git; then
    printf 'Failed to install packages from Chaotic-AUR.\n'
    exit 1
fi

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.discordapp.Discord

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.github.tchx84.Flatseal

# Remove Chaotic-AUR keys, keyring, and mirrorlist
if ! sudo arch-chroot "$workdir" pacman -Rns --noconfirm chaotic-keyring; then
    printf 'Failed to remove chaotic-keyring.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" pacman -Rns --noconfirm chaotic-mirrorlist; then
    printf 'Failed to remove chaotic-mirrorlist.\n'
    exit 1
fi

repo_name="chaotic-aur"

# Remove the repository section from pacman.conf
sudo sed -i "/^\[$repo_name\]/,/^$/d" "$workdir/etc/pacman.conf"

# Refresh package databases
if ! sudo arch-chroot "$workdir" pacman -Sy --noconfirm; then
    printf 'Failed to refresh package databases.\n'
    exit 1
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

# Graphics Drivers find and install
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

# Customise grub with Vimix grub theme and update grub config file
if ! sudo arch-chroot "$workdir" git clone https://github.com/vinceliuice/grub2-themes.git; then
    printf 'Failed to clone Vimix grub theme repository.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" cd /grub2-themes; then
    printf 'Failed to change directory to grub2-themes.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" sudo ./install.sh -b -t vimix; then
    printf 'Failed to install Vimix grub theme.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg; then
    printf 'Failed to generate GRUB configuration file.\n'
    exit 1
fi

# Finally, update system
if ! sudo arch-chroot "$workdir" pacman -Syu; then
    printf 'Failed to update the system.\n'
    exit 1
fi

exit 0
