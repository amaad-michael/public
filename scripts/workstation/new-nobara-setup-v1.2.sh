#!/bin/bash

# ==============================================================================
#  Complete Nobara Setup: AMD GPU Performance + Cinnamon Desktop
# ==============================================================================
#
#  Description:
#  - Forces AMD discrete GPU (RDNA, not iGPU) to high performance mode
#  - Installs Cinnamon Desktop Environment
#  - Downloads wallpaper and provides setup guidance
#
#  Usage:
#  1. Save as new-nobara-setup-v1.2.sh
#  2. chmod +x new-nobara-setup-v1.2.sh
#  3. sudo ./new-nobara-setup-v1.2.sh            (full setup)
#     sudo ./new-nobara-setup-v1.2.sh gpu-high   (GPU tuning only)
#
# ==============================================================================

set -e

# --- Safety Check: Ensure root ---
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with root privileges."
  echo "Please use 'sudo ./new-nobara-setup-v1.2.sh'"
  exit 1
fi

# ==============================================================================
#  PART 1: AMD Discrete GPU Performance Configuration
# ==============================================================================
# Runs as the first part of a full setup, or alone via the gpu-high
# argument (folded in from the retired alt variant on 2026-10-22).

gpu_high() {

echo "--------------------------------------------------"
echo "    AMD GPU Performance Configuration"
echo "--------------------------------------------------"
echo ""

# Detect discrete AMD GPU (not iGPU)
echo "--> Detecting AMD discrete GPU (RDNA)..."
GPU_DEVICE=""

for card in /sys/class/drm/card*/device/uevent; do
    if [ -f "$card" ]; then
        card_path=$(dirname "$card")
        if grep -q "DRIVER=amdgpu" "$card"; then
            # Check if this is a discrete GPU (not integrated)
            if [ -f "$card_path/vendor" ]; then
                vendor=$(cat "$card_path/vendor")
                # AMD vendor ID: 0x1002
                if [ "$vendor" = "0x00001002" ]; then
                    # Prefer discrete GPU over iGPU by checking device class
                    if [ -f "$card_path/class" ]; then
                        class=$(cat "$card_path/class")
                        # VGA (0x030000) is discrete, Display (0x038000) is iGPU
                        if [ "$class" = "0x030000" ]; then
                            GPU_DEVICE="$card_path"
                            break
                        fi
                    fi
                fi
            fi
        fi
    fi
done

if [ -z "$GPU_DEVICE" ]; then
    if [ "${GPU_OPTIONAL:-0}" = "1" ]; then
        echo "No AMD discrete GPU found; skipping GPU tuning (optional step)."
        return 0
    fi
    echo "Error: No AMD discrete GPU found. Exiting."
    exit 1
fi

GPU_CARD=$(basename "$(dirname "$GPU_DEVICE")")
echo "✓ Found discrete GPU: $GPU_CARD at $GPU_DEVICE"
echo ""

# Apply high performance mode
echo "--> Applying high performance mode to $GPU_CARD..."
if echo "high" | sudo tee "$GPU_DEVICE/power_dpm_force_performance_level" > /dev/null; then
    echo "✓ GPU locked to high performance."
    echo "  (Note: This will increase idle power draw.)"
else
    echo "Error: Failed to set GPU performance level."
    exit 1
fi
echo ""

# Verify the setting
CURRENT_LEVEL=$(cat "$GPU_DEVICE/power_dpm_force_performance_level")
echo "Verification: Current level is '$CURRENT_LEVEL'"
echo ""

}

# --- Dispatch: gpu-high runs Part 1 only ---
# v1.2: in gpu-high mode a missing discrete GPU is a skip (exit 0),
# not an error: the single new-box workflow calls this mode as its
# optional final step on every box, gaming rig or not. A full run
# still stops, because a gaming setup without the GPU is wrong.
if [ "${1:-}" = "gpu-high" ]; then
    GPU_OPTIONAL=1
    export GPU_OPTIONAL
    gpu_high
    echo "GPU tuning only: setup not run. Run without arguments for the full setup."
    exit 0
fi

gpu_high

# ==============================================================================
#  PART 2: Cinnamon Desktop Installation
# ==============================================================================

echo "--------------------------------------------------"
echo "    Cinnamon Desktop Environment Setup for Nobara"
echo "--------------------------------------------------"
echo "This script will perform the following actions:"
echo "  1. Update all system packages."
echo "  2. Install the 'Cinnamon Desktop' package group."
echo "  3. Download a beautiful wallpaper from Unsplash."
echo ""
read -rp "Press [Enter] to continue or [Ctrl+C] to cancel."
echo ""

# --- Step 1: System Update via Nobara Sync ---
echo "--> Syncing system packages with Nobara Updater..."
if command -v nobara-sync &> /dev/null; then
    if ! nobara-sync cli; then
        echo "Error: nobara-sync failed. Please check your internet connection and Nobara configuration."
        exit 1
    fi
else
    echo "Warning: nobara-sync not found. Falling back to dnf update."
    if ! dnf update -y; then
        echo "Error: Failed to update system packages. Please check your internet connection and dnf configuration."
        exit 1
    fi
fi
echo "✓ System sync complete."
echo ""

# --- Step 2: Install Cinnamon ---
echo "--> Installing the Cinnamon Desktop Environment..."
echo "This step will download and install many packages."
if ! dnf groupinstall @cinnamon-desktop -y; then
    echo "Error: Failed to install the Cinnamon Desktop group. Please check the output above for errors."
    exit 1
fi
echo "✓ Cinnamon DE group installed successfully."
echo ""

# --- Step 3: Download Placeholder Wallpaper ---
echo "--> Downloading a placeholder wallpaper from Unsplash..."
WALLPAPER_DIR="/usr/share/backgrounds/nobara-cinnamon"
mkdir -p "$WALLPAPER_DIR"

if curl -L "https://source.unsplash.com/random/3840x2160/?nature,landscape" -o "$WALLPAPER_DIR/unsplash-background.jpg"; then
    echo "✓ Wallpaper saved to '$WALLPAPER_DIR/unsplash-background.jpg'"
else
    echo "Warning: Could not download the wallpaper. You can set your own later."
fi
echo ""

# ==============================================================================
#  PART 3: Final Instructions
# ==============================================================================

echo "------------------------------------------------------------------"
echo "          ✅ Setup Complete!"
echo "------------------------------------------------------------------"
echo ""
echo "GPU Performance:"
echo "  - AMD $GPU_CARD is now locked to high performance mode."
echo "  - To revert: echo auto | sudo tee $GPU_DEVICE/power_dpm_force_performance_level"
echo "  - Monitor clocks: watch -n 1 'cat $GPU_DEVICE/pp_dpm_sclk'"
echo ""
echo "Cinnamon Desktop:"
echo "  1. Log out of your current session (or reboot)."
echo "  2. On the login screen, click the small gear icon (⚙️)."
echo "  3. Select 'Cinnamon' from the session list and log in."
echo ""
echo "Customize Appearance:"
echo "  - Open main menu → search for 'Themes' application."
echo "  - Select your preferred style for windows, icons, etc."
echo ""
echo "Set Wallpaper:"
echo "  - Right-click the desktop → 'Change Desktop Background'."
echo "  - Click '+' to add a new folder."
echo "  - Navigate to: /usr/share/backgrounds/nobara-cinnamon"
echo "  - Select 'unsplash-background.jpg'."
echo ""
echo "Enjoy your Cinnamon desktop with GPU performance locked!"
echo "------------------------------------------------------------------"
