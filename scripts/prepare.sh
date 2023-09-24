#!/usr/bin/env bash

# prep Pacman for buisness
sudo pacman-key --init
sudo pacman-key --populate archlinux
sudo pacman -Syy
