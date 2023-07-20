#!/usr/bin/env bash

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
if ! sudo pacman -Syy; then
    printf 'Failed to synchronize with repos.\n'
    exit 1
fi

# Optimize download speed using reflector based on IP address
country_code=$(curl -s https://ipapi.co/country/)
if ! sudo reflector --country $country_code --age 20 --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; then
    printf 'Failed to optimize download speed with reflector.\n'
    exit 1
fi

exit 0
