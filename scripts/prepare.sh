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
sudo pacman -Syy

# Optimize download speed using reflector based on IP address
country_code=$(curl -s https://ipapi.co/country/)
sudo reflector --country $country_code --age 20 --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

exit 0
