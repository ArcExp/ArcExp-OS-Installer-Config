#!/usr/bin/env bash

# load collection of checks and functions
source /etc/os-installer/lib.sh || { printf 'Failed to load /etc/os-installer/lib.sh\n'; exit 1; }

# sanity check that all variables were set
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
task_wrapper sudo arch-chroot "$workdir" systemctl enable gdm.service NetworkManager.service fstrim.timer

# Set chosen locale and en_US.UTF-8 for it is required by some programs
echo "$OSI_LOCALE UTF-8" | task_wrapper sudo tee -a "$workdir/etc/locale.gen"

if [[ "$OSI_LOCALE" != 'en_US.UTF-8' ]]; then
    echo "en_US.UTF-8 UTF-8" | task_wrapper sudo tee -a "$workdir/etc/locale.gen"
fi

echo "LANG=\"$OSI_LOCALE\"" | task_wrapper sudo tee "$workdir/etc/locale.conf"

# Generate locales
task_wrapper sudo arch-chroot "$workdir" locale-gen

# Add dconf tweaks for GNOME desktop configuration
task_wrapper sudo cp -rv "$osidir/dconf-settings/dconf" "$workdir/etc/"
task_wrapper sudo arch-chroot "$workdir" dconf update

# Set hostname
echo 'ArcExp' | task_wrapper sudo tee "$workdir/etc/hostname"

# Add user, setup groups, set password, and set user properties
task_wrapper sudo arch-chroot "$workdir" useradd -m -s /bin/bash -p NP "$OSI_USER_NAME"
echo "$OSI_USER_NAME:$OSI_USER_PASSWORD" | task_wrapper sudo arch-chroot "$workdir" chpasswd
task_wrapper sudo arch-chroot "$workdir" usermod -a -G wheel "$OSI_USER_NAME"
task_wrapper sudo arch-chroot "$workdir" chage -M -1 "$OSI_USER_NAME"

# Set timezone
task_wrapper sudo arch-chroot "$workdir" ln -sf "/usr/share/zoneinfo/$OSI_TIMEZONE" /etc/localtime

# Set Keymap
declare -r current_keymap=$(gsettings get org.gnome.desktop.input-sources sources)
printf "[org.gnome.desktop.input-sources]\nsources = $current_keymap\n" | task_wrapper sudo tee $workdir/etc/dconf/db/local.d/keymap

# Set auto-login if requested
if [[ "$OSI_USER_AUTOLOGIN" -eq 1 ]]; then
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$OSI_USER_NAME\n" | task_wrapper sudo tee "$workdir/etc/gdm/custom.conf"
fi

# Add multilib repository
printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | task_wrapper sudo tee -a "$workdir/etc/pacman.conf"

# Install select packages
task_wrapper sudo arch-chroot "$workdir" pacman -S steam amdvlk lib32-amdvlk --noconfirm

# Install pkgbuilder AUR helper and other packages
task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" git clone https://github.com/ArcExp/ArcExp-Pkgs.git && \
pacman -U /ArcExp-Pkgs/pkgbuilder-4.3.2-3-any.pkg.tar.zst --noconfirm && \
pkgbuilder -S --noconfirm extension-manager nautilus-admin-gtk4 protonup-qt qbittorrent-enhanced xone-dkms xpadneo-dkms xone-dongle-firmware flatseal adwsteamgtk ttf-ms-fonts onlyoffice-bin lutris-git gamescope-git mangohud-git lib32-mangohud-git betterdiscord-installer discord_arch_electron

# Change installed kernel
task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" pacman -Rns --noconfirm linux

task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" pkgbuilder -S --noconfirm linux-fsync-nobara-bin

# Update GRUB configuration
task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" grub-mkconfig -o /boot/grub/grub.cfg

# Create home directory
task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" mkdir -p /home/"$OSI_USER_NAME"/{Desktop,Documents,Downloads,Music,Pictures,Public,Templates,Videos}

task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" touch /home/"$OSI_USER_NAME"/Templates/"Text File"

# Finally, update system and exit script
task_wrapper sudo arch-chroot "$workdir" su "$OSI_USER_NAME" pkgbuilder -Syu --noconfirm

exit 0
