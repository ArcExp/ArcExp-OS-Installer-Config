#!/bin/bash

# Define the path to the keymap file
keymap_file="keymap.txt"

# Check if the keymap file exists
if [ -f "$keymap_file" ]; then
    # Read the contents of the keymap file and store it in a variable
    keymap_content=$(<"$keymap_file")

    # Construct the gsettings command using the file's content
    gsettings_command="gsettings set org.gnome.desktop.input-sources sources \"$keymap_content\""

    # Execute the gsettings command
    eval "$gsettings_command"

    # Print a message indicating success
    echo "Keymap set using contents of $keymap_file."
else
    # Print an error message if the file does not exist
    echo "Error: $keymap_file not found."
fi

rm keymap.txt
rm keymap.sh
