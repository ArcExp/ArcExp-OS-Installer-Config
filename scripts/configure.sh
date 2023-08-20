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

# Enable systemd services
if ! sudo arch-chroot "$workdir" systemctl enable gdm.service NetworkManager.service bluetooth.service fstrim.timer; then
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
if ! sudo cp -rv "$osidir/misc/dconf" "$workdir/etc/"; then
    printf 'Failed to copy dconf tweaks.\n'
    exit 1
fi

if ! sudo arch-chroot "$workdir" dconf update; then
    printf 'Failed to update dconf.\n'
    exit 1
fi

sudo arch-chroot "$workdir" mkdir "/usr/share/backgrounds/"

sudo cp "$osidir/misc/wallpapers/ArcExp.png" "$workdir/usr/share/backgrounds/"
sudo cp "$osidir/misc/wallpapers/ArcExp-Light.png" "$workdir/usr/share/backgrounds/"

# Set hostname
echo 'ArcExp' | sudo tee "$workdir/etc/hostname"

# Function to generate a hashed password
generate_hashed_password() {
    local password="$1"
    local salt="$(openssl rand -base64 12)"
    echo "$password" | mkpasswd --method=sha-512 --salt="$salt" --stdin
}

# Add user, setup groups, and set user properties
if ! sudo arch-chroot "$workdir" useradd -m -s /bin/bash "$OSI_USER_NAME"; then
    printf 'Failed to add user.\n'
    exit 1
fi

# Generate hashed password
hashed_password=$(generate_hashed_password "$OSI_USER_PASSWORD")

# Set hashed password for the user
if ! echo "$OSI_USER_NAME:$hashed_password" | sudo arch-chroot "$workdir" chpasswd --encrypted; then
    printf 'Failed to set user password.\n'
    exit 1
fi

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

# Create home directory and subdirectories
if ! sudo arch-chroot "$workdir" mkdir -p "/home/$OSI_USER_NAME/Desktop" \
    "/home/$OSI_USER_NAME/Documents" \
    "/home/$OSI_USER_NAME/Downloads" \
    "/home/$OSI_USER_NAME/Music" \
    "/home/$OSI_USER_NAME/Pictures" \
    "/home/$OSI_USER_NAME/Public" \
    "/home/$OSI_USER_NAME/Templates" \
    "/home/$OSI_USER_NAME/Videos"; then
    printf 'Failed to create home directory and subdirectories.\n'
    exit 1
fi

# Create 'Text File' in the 'Templates' directory
if ! sudo arch-chroot "$workdir" touch "/home/$OSI_USER_NAME/Templates/Text File"; then
    printf 'Failed to create the Text File in the Templates directory.\n'
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

# Graphics Drivers find and install
gpu_type=$(lspci)

if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    # Install NVIDIA drivers
    if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings cuda; then
        printf 'Failed to install NVIDIA drivers.\n'
        exit 1
    fi
elif grep -E "Radeon|AMD" <<< ${gpu_type}; then
    # Install AMD GPU drivers
    if ! sudo arch-chroot "$workdir" pacman -S mesa xf86-video-amdgpu --noconfirm; then
        printf 'Failed to install AMD GPU drivers.\n'
        exit 1
    fi
elif ls /sys/class/drm/card* | grep "Intel"; then
    # Install Intel GPU drivers
    if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa; then
        printf 'Failed to install Intel Graphics drivers.\n'
        exit 1
    fi
fi

# List of packages from Chaotic-AUR to install
chaotic_packages=(
    yay
    extension-manager
    protonup-qt
    qbittorrent-enhanced
    xone-dkms
    xpadneo-dkms
    xone-dongle-firmware
    ttf-ms-fonts
    onlyoffice-bin
    lutris-git
    gamescope-git
    mangohud-git
    lib32-mangohud-git
)

# Function to install packages from Chaotic-AUR
install_chaotic_packages() {
    local package
    for package in "${chaotic_packages[@]}"; do
        if ! sudo arch-chroot "$workdir" pacman -S --noconfirm "$package"; then
            printf 'Failed to install package "%s" from Chaotic-AUR. Skipping.\n' "$package"
        fi
    done
}

# Install packages from Chaotic-AUR
install_chaotic_packages

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.discordapp.Discord

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.github.tchx84.Flatseal

yes | sudo arch-chroot "$workdir" flatpak install -y flathub com.usebottles.bottles

yes | sudo arch-chroot "$workdir" flatpak install -y flathub io.github.Foldex.AdwSteamGtk

sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg

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

# Finally, update system
if ! sudo arch-chroot "$workdir" pacman -Syu; then
    printf 'Failed to update the system.\n'
    exit 1
fi

exit 0
