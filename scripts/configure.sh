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

# Set timezone
sudo arch-chroot "$workdir" ln -sf "/usr/share/zoneinfo/$OSI_TIMEZONE" /etc/localtime

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

# Set root password in the chroot environment
root_password=$(generate_hashed_password "$ROOT_PASSWORD")
echo "root:$root_password" | sudo arch-chroot "$workdir" chpasswd --encrypted

# Add non root user, setup groups, and set user properties
if ! sudo arch-chroot "$workdir" useradd -m -s /usr/bin/bash "$OSI_USER_NAME"; then
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

# Set auto-login if requested
if [[ "$OSI_USER_AUTOLOGIN" -eq 1 ]]; then
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$OSI_USER_NAME\n" | sudo tee "$workdir/etc/gdm/custom.conf"
fi

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

# Apply keymap
sudo arch-chroot "$workdir" su - "$OSI_USER_NAME" -c 'true'

sudo arch-chroot "$workdir" gsettings set org.gnome.desktop.input-sources sources $OSI_KEYBOARD_LAYOUT

# sudo arch-chroot "$workdir" setxkbmap $OSI_KEYBOARD_LAYOUT

# sudo arch-chroot "$workdir" gsettings set org.gnome.desktop.input-sources sources "[('xkb', '$OSI_KEYBOARD_LAYOUT')]"

sudo arch-chroot "$workdir" su - -c 'true'

# Add multilib repository
printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | sudo tee -a "$workdir/etc/pacman.conf"

sudo arch-chroot "$workdir" mkinitcpio -P

sudo arch-chroot "$workdir" exit

exit 0
