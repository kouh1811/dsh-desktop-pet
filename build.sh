#!/bin/bash
# Build the dsh-desktop-pet companion binary (macOS).
# Requires Xcode Command Line Tools (provides swiftc):  xcode-select --install
set -e
cd "$(dirname "$0")/companion"
swiftc -O dsh-desktop-pet.swift -o dsh-desktop-pet
echo "✔ built companion/dsh-desktop-pet"
