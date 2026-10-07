#!/usr/bin/env bash
# =============================================================================
# install-lsfg-vk.sh
# Lossless Scaling Frame Generation (lsfg-vk) Installer for Nobara Linux
# =============================================================================
# Usage:
#   chmod +x install-lsfg-vk.sh
#   ./install-lsfg-vk.sh
#
# What this script does:
#   1. Validates your environment (kernel, mesa, steam)
#   2. Installs Qt6 dependencies via dnf
#   3. Downloads and installs the latest lsfg-vk RPM from GitHub
#   4. Detects your Lossless Scaling install path
#   5. Optionally launches the config UI
# =============================================================================

set -euo pipefail

# ── Formatting ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

info()    { echo -e "${BLU}[INFO]${RST}  $*"; }
success() { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YLW}[WARN]${RST}  $*"; }
error()   { echo -e "${RED}[ERROR]${RST} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${CYN}${BLD}━━━  $*  ━━━${RST}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
MIN_KERNEL_MAJOR=6
MIN_KERNEL_MINOR=14
MIN_MESA_MAJOR=25
MIN_MESA_MINOR=0

GITHUB_API="https://api.github.com/repos/PancakeTAS/lsfg-vk/releases/latest"
STEAM_APPID="993090"   # Lossless Scaling Steam App ID
LS_APPNAME="Lossless Scaling"

STEAM_PATHS=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "/usr/share/steam"
)

# ── Root Guard ────────────────────────────────────────────────────────────────
section "Preflight"

if [[ "$EUID" -eq 0 ]]; then
    die "Do not run this script as root. It will use sudo where needed."
fi
success "Running as user: $USER"

# ── Kernel Version Check ──────────────────────────────────────────────────────
check_kernel() {
    local kernel_ver
    kernel_ver=$(uname -r)
    local major minor
    major=$(echo "$kernel_ver" | cut -d'.' -f1)
    minor=$(echo "$kernel_ver" | cut -d'.' -f2)

    info "Kernel: $kernel_ver"

    if [[ "$major" -lt "$MIN_KERNEL_MAJOR" ]] || \
       [[ "$major" -eq "$MIN_KERNEL_MAJOR" && "$minor" -lt "$MIN_KERNEL_MINOR" ]]; then
        die "Kernel ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}+ required for RX 9060 XT (RDNA 4). \
Current: $kernel_ver — update via: sudo dnf update kernel"
    fi
    success "Kernel OK (${kernel_ver})"
}

# ── Mesa Version Check ────────────────────────────────────────────────────────
check_mesa() {
    if ! command -v glxinfo &>/dev/null; then
        warn "glxinfo not found — skipping Mesa check. Install mesa-demos to verify."
        return
    fi

    local mesa_ver
    mesa_ver=$(glxinfo 2>/dev/null | grep "Mesa" | grep -oP '\d+\.\d+' | head -1)

    if [[ -z "$mesa_ver" ]]; then
        warn "Could not determine Mesa version. Proceeding anyway."
        return
    fi

    local major minor
    major=$(echo "$mesa_ver" | cut -d'.' -f1)
    minor=$(echo "$mesa_ver" | cut -d'.' -f2)

    info "Mesa: $mesa_ver"

    if [[ "$major" -lt "$MIN_MESA_MAJOR" ]] || \
       [[ "$major" -eq "$MIN_MESA_MAJOR" && "$minor" -lt "$MIN_MESA_MINOR" ]]; then
        die "Mesa ${MIN_MESA_MAJOR}.${MIN_MESA_MINOR}+ required. Current: $mesa_ver — \
update via: sudo dnf update mesa-libGL"
    fi
    success "Mesa OK (${mesa_ver})"
}

# ── GPU Check ─────────────────────────────────────────────────────────────────
check_gpu() {
    if command -v glxinfo &>/dev/null; then
        local renderer
        renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1)
        info "GPU renderer: $renderer"
    fi

    if lspci 2>/dev/null | grep -qi "radeon\|amdgpu\|AMD"; then
        success "AMD GPU detected"
    else
        warn "Could not confirm AMD GPU via lspci. Proceeding anyway."
    fi
}

# ── Steam Detection ───────────────────────────────────────────────────────────
section "Steam & Lossless Scaling Detection"

detect_steam_root() {
    for path in "${STEAM_PATHS[@]}"; do
        if [[ -d "$path/steamapps" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

detect_lossless_scaling() {
    local steam_root="$1"
    local ls_path="${steam_root}/steamapps/common/${LS_APPNAME}"

    if [[ -f "${ls_path}/Lossless.dll" ]]; then
        echo "$ls_path"
        return 0
    fi

    # Search all library folders defined in libraryfolders.vdf
    local vdf="${steam_root}/steamapps/libraryfolders.vdf"
    if [[ -f "$vdf" ]]; then
        while IFS= read -r line; do
            local lib_path
            lib_path=$(echo "$line" | grep -oP '"path"\s+"\K[^"]+')
            if [[ -n "$lib_path" ]]; then
                local candidate="${lib_path}/steamapps/common/${LS_APPNAME}"
                if [[ -f "${candidate}/Lossless.dll" ]]; then
                    echo "$candidate"
                    return 0
                fi
            fi
        done < "$vdf"
    fi

    return 1
}

STEAM_ROOT=""
if STEAM_ROOT=$(detect_steam_root); then
    success "Steam root: $STEAM_ROOT"
else
    die "Steam not found in standard paths. Is Steam installed?"
fi

LS_PATH=""
if LS_PATH=$(detect_lossless_scaling "$STEAM_ROOT"); then
    success "Lossless Scaling found: $LS_PATH"
else
    die "Lossless Scaling not found. Purchase it on Steam and run: \
steam steam://install/${STEAM_APPID} — then re-run this script."
fi

DLL_PATH="${LS_PATH}/Lossless.dll"
success "Lossless.dll: $DLL_PATH"

# ── Run Checks ────────────────────────────────────────────────────────────────
section "System Requirements"
check_kernel
check_mesa
check_gpu

# ── Qt6 Dependencies ──────────────────────────────────────────────────────────
section "Installing Qt6 Dependencies"

QT6_PKGS=(
    qt6-qtbase
    qt6-qtdeclarative
    qt6-qtwayland
)

info "Installing: ${QT6_PKGS[*]}"
sudo dnf install -y "${QT6_PKGS[@]}" || die "dnf install failed for Qt6 packages."
success "Qt6 dependencies installed"

# ── Download lsfg-vk RPM ──────────────────────────────────────────────────────
section "Downloading lsfg-vk"

if ! command -v curl &>/dev/null; then
    info "curl not found — installing..."
    sudo dnf install -y curl || die "Failed to install curl."
fi

info "Fetching latest release info from GitHub..."
RELEASE_JSON=$(curl -fsSL "$GITHUB_API") || die "Failed to reach GitHub API. Check your connection."

RPM_URL=$(echo "$RELEASE_JSON" | grep -oP '"browser_download_url":\s*"\K[^"]+\.rpm' | head -1)

if [[ -z "$RPM_URL" ]]; then
    die "Could not find an RPM asset in the latest release. Check: https://github.com/PancakeTAS/lsfg-vk/releases"
fi

RPM_FILE=$(basename "$RPM_URL")
info "Downloading: $RPM_URL"
curl -fsSL -o "/tmp/${RPM_FILE}" "$RPM_URL" || die "Download failed."
success "Downloaded: /tmp/${RPM_FILE}"

# Integrity check: embedded RPM digests first (catches corrupt downloads),
# then an optional pinned SHA256 for authenticity (export LSFG_VK_SHA256).
rpm -K --nosignature "/tmp/${RPM_FILE}" >/dev/null 2>&1 \
    || die "RPM digest verification failed for ${RPM_FILE} (corrupt download?)"
if [[ -n "${LSFG_VK_SHA256:-}" ]]; then
    echo "${LSFG_VK_SHA256}  /tmp/${RPM_FILE}" | sha256sum -c - \
        || die "lsfg-vk RPM checksum mismatch — refusing to install"
else
    warn "LSFG_VK_SHA256 not set — installing RPM without checksum verification"
fi

# ── Install RPM ───────────────────────────────────────────────────────────────
section "Installing lsfg-vk"

info "Installing ${RPM_FILE} via rpm..."
sudo rpm -Uvh "/tmp/${RPM_FILE}" || die "RPM install failed."
success "lsfg-vk installed"

# Cleanup
rm -f "/tmp/${RPM_FILE}"

# ── Verify Installation ───────────────────────────────────────────────────────
section "Verifying Installation"

if command -v lsfg-vk-ui &>/dev/null; then
    success "lsfg-vk-ui found in PATH: $(command -v lsfg-vk-ui)"
elif [[ -f "$HOME/.local/bin/lsfg-vk-ui" ]]; then
    success "lsfg-vk-ui found: $HOME/.local/bin/lsfg-vk-ui"
else
    warn "lsfg-vk-ui not found in PATH. You may need to add ~/.local/bin to PATH."
    warn "Add this to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── Write Base Config ─────────────────────────────────────────────────────────
section "Writing Base Configuration"

CONF_DIR="$HOME/.config/lsfg-vk"
CONF_FILE="${CONF_DIR}/conf.toml"

mkdir -p "$CONF_DIR"

if [[ -f "$CONF_FILE" ]]; then
    warn "Config already exists at $CONF_FILE — skipping write. Edit manually if needed."
else
    cat > "$CONF_FILE" <<TOML
# lsfg-vk configuration — generated by install-lsfg-vk.sh
# Full docs: https://github.com/PancakeTAS/lsfg-vk/wiki/Configuring-lsfg-vk

[global]
# Path to Lossless.dll from your Steam installation
dll = "${DLL_PATH}"

# ── Default Profile ──────────────────────────────────────────────────────────
# Add per-game profiles below by copying this block and editing 'active_in'
# and 'multiplier'. Use the executable name (e.g. Game.exe for Proton games).

[[profile]]
# active_in = ["game_executable.exe"]   # uncomment and set per game
multiplier = 2          # 2x is stable; try 3x or 4x for lower-GPU-load games
flow_scale = 1.0        # lower (e.g. 0.75) improves perf at minor quality cost
performance_mode = false # true uses a lighter model; minimal quality trade-off
# pacing = "none"       # frame pacing mode — leave default unless you see stutter
TOML
    success "Config written: $CONF_FILE"
fi

# ── Print Steam Launch Options ─────────────────────────────────────────────────
section "Steam Launch Options"

echo ""
echo -e "  ${BLD}For Proton (Windows) games:${RST}"
echo -e "  ${GRN}ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%${RST}"
echo ""
echo -e "  ${BLD}For Native Linux games:${RST}"
echo -e "  ${GRN}ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%${RST}"
echo ""
echo -e "  ${BLD}If a game isn't using your RX 9060 XT (add DRI_PRIME=1):${RST}"
echo -e "  ${GRN}DRI_PRIME=1 ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%${RST}"
echo ""
echo -e "  ${YLW}Check active GPU:${RST}  glxinfo | grep 'OpenGL renderer'"
echo ""

# ── Launch UI Prompt ──────────────────────────────────────────────────────────
section "Done"

echo -e "${GRN}${BLD}lsfg-vk installation complete!${RST}"
echo ""
echo -n "Launch lsfg-vk-ui now to configure profiles? [y/N]: "
read -r LAUNCH_UI

if [[ "${LAUNCH_UI,,}" == "y" ]]; then
    info "Launching lsfg-vk-ui..."
    if command -v lsfg-vk-ui &>/dev/null; then
        lsfg-vk-ui &
    elif [[ -f "$HOME/.local/bin/lsfg-vk-ui" ]]; then
        "$HOME/.local/bin/lsfg-vk-ui" &
    else
        warn "Could not locate lsfg-vk-ui binary. Run it manually from your app launcher."
    fi
fi

echo ""
info "Config file:  $CONF_FILE"
info "Docs:         https://github.com/PancakeTAS/lsfg-vk/wiki"
echo ""
