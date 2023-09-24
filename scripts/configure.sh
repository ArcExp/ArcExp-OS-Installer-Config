#!/usr/bin/env bash

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'

# Enable systemd services
sudo arch-chroot "$workdir" systemctl enable gdm.service NetworkManager.service bluetooth.service fstrim.timer

# Set chosen locale and en_US.UTF-8 for it is required by some programs
echo "$OSI_LOCALE UTF-8" | sudo tee -a "$workdir/etc/locale.gen"

if [[ "$OSI_LOCALE" != 'en_US.UTF-8' ]]; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a "$workdir/etc/locale.gen"
fi

echo "LANG=\"$OSI_LOCALE\"" | sudo tee "$workdir/etc/locale.conf"

# Generate locales
sudo arch-chroot "$workdir" locale-gen

# Add dconf tweaks for GNOME desktop configuration
sudo cp -rv "$osidir/misc/dconf" "$workdir/etc/"

sudo arch-chroot "$workdir" dconf update

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
sudo arch-chroot "$workdir" ln -sf "/usr/share/zoneinfo/$OSI_TIMEZONE" /etc/localtime

# Set Keymap
declare -r current_keymap=$(gsettings get org.gnome.desktop.input-sources sources)
printf "[org.gnome.desktop.input-sources]\nsources = $current_keymap\n" | sudo tee "$workdir/etc/dconf/db/local.d/keymap"

# Set auto-login if requested
if [[ "$OSI_USER_AUTOLOGIN" -eq 1 ]]; then
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$OSI_USER_NAME\n" | sudo tee "$workdir/etc/gdm/custom.conf"
fi

sudo arch-chroot "$workdir" mkinitcpio -P

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

# Add multilib repository
printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | sudo tee -a "$workdir/etc/pacman.conf"

# Graphics Drivers find and install
gpu_type=$(lspci)

if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    # Install NVIDIA drivers
    if ! sudo arch-chroot "$workdir" pacman -S --noconfirm --needed dkms nvidia-dkms nvidia-utils nvidia-settings cuda; then
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

exit 0
