#!/usr/bin/env bash

# Function to display an error and exit
show_error() {
    printf "ERROR: %s\n" "$1" >&2
    exit 1
}

# Loop until pacman-init.service finishes
printf 'Waiting for pacman-init.service to finish running before starting the installation... '

while true; do
    systemctl status pacman-init.service | grep -q 'Finished Initializes Pacman keyring.'

    if [[ $? -eq 0 ]]; then
        printf 'Done'
        break
    fi

    sleep 2
done

# Synchronize with repos
sudo pacman -Syy || show_error "Failed to synchronize with repos"

exit 0
