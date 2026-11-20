#!/bin/bash

# ==============================================================================
# new_nobara_v1.1.sh
# Optimized Configuration Script for New Nobara Boxes
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with root privileges (sudo)."
    exit 1
fi

# --- Module 1: GPU Tuning (Robust Detection) ---
tune_gpu() {
    echo "--> Detecting discrete AMD GPU..."
    local GPU_DEVICE=""

    for card in /sys/class/drm/card*/device/uevent; do
        if [ -f "$card" ]; then
            local card_path
            card_path=$(dirname "$card")
            # Filter for amdgpu driver and AMD vendor ID (0x00001002)
            if grep -q "DRIVER=amdgpu" "$card" && [ "$(cat "$card_path/vendor" 2>/dev/null)" = "0x00001002" ]; then
                # Ensure it is a discrete GPU (Class 0x030000)
                if [ "$(cat "$card_path/class" 2>/dev/null)" = "0x030000" ]; then
                    GPU_DEVICE="$card_path/power_dpm_force_performance_level"
                    break
                fi
            fi
        fi
    done

    if [ -z "$GPU_DEVICE" ]; then
        echo "Error: No discrete AMD GPU detected."
        exit 1
    fi

    echo "--> Locking to 'high' performance..."
    echo "high" | tee "$GPU_DEVICE" > /dev/null

    # Verification of performance mode application
    if [ "$(cat "$GPU_DEVICE")" = "high" ]; then
        echo "✓ GPU performance confirmed at 'high'."
    else
        echo "❌ Failure: GPU did not accept 'high' setting."
        exit 1
    fi
}

# --- Module 2: Full Setup Flow ---
run_full_setup() {
    echo "--> Running Nobara System Sync..."
    command -v nobara-sync &>/dev/null && nobara-sync

    echo "--> Updating DNF packages..."
    dnf update -y && dnf autoremove -y

    echo "--> Installing Cinnamon Desktop..."
    # Using the @ group syntax for reliable group installation
    dnf install -y @cinnamon-desktop

    echo "--> Downloading placeholder wallpaper..."
    local WALLPAPER_DIR="/usr/share/backgrounds/nobara-cinnamon"
    mkdir -p "$WALLPAPER_DIR"
    curl -L "https://source.unsplash.com/random/1920x1080/?nature,landscape" -o "$WALLPAPER_DIR/unsplash-background.jpg"

    echo "════════════════════════════════════════"
    echo "Setup Complete (v1.1). Reboot recommended."
    echo "════════════════════════════════════════"
}

# --- Execution ---
case "$1" in
    setup)      run_full_setup ;;
    gpu-high)   tune_gpu ;;
    *)
        echo "Usage: sudo ./new_nobara_v1.1.sh [setup|gpu-high]"
        exit 1
        ;;
esac
