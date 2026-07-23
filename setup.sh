#!/usr/bin/env bash
# setup.sh — installs host-side tools (vocalinux + ydotool) for cohere-arabic-dictation
# Supports: Fedora, Ubuntu/Debian

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[x]${NC} $*"; exit 1; }

# ── Detect distro ────────────────────────────────────────────────────────────
if command -v dnf &>/dev/null; then
    DISTRO="fedora"
elif command -v apt-get &>/dev/null; then
    DISTRO="debian"
else
    error "Unsupported distro. Only Fedora and Ubuntu/Debian are supported."
fi
info "Detected distro: $DISTRO"

# ── 1. Install ydotool ───────────────────────────────────────────────────────
info "Installing ydotool..."
if [ "$DISTRO" = "fedora" ]; then
    sudo dnf install -y ydotool
else
    # Ubuntu 22.04+ has ydotool in universe
    sudo apt-get update -q
    sudo apt-get install -y ydotool || {
        warn "ydotool not in apt repos, building from source..."
        sudo apt-get install -y cmake git libevdev-dev
        tmp=$(mktemp -d)
        git clone https://github.com/ReimuNotMoe/ydotool "$tmp/ydotool"
        cmake -S "$tmp/ydotool" -B "$tmp/build" -DCMAKE_BUILD_TYPE=Release
        cmake --build "$tmp/build" -j"$(nproc)"
        sudo cmake --install "$tmp/build"
        rm -rf "$tmp"
    }
fi

# ── 2. /dev/uinput permissions ───────────────────────────────────────────────
info "Setting up /dev/uinput permissions..."
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' \
    | sudo tee /etc/udev/rules.d/60-uinput.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger

if ! groups | grep -q "\binput\b"; then
    info "Adding $USER to the 'input' group (requires re-login to take effect)..."
    sudo usermod -aG input "$USER"
    NEED_RELOGIN=1
fi

# ── 3. ydotoold systemd user service ────────────────────────────────────────
info "Setting up ydotoold systemd user service..."
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/ydotoold.service <<'EOF'
[Unit]
Description=ydotool daemon
After=default.target

[Service]
ExecStart=/usr/bin/ydotoold
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now ydotoold
info "ydotoold running: $(systemctl --user is-active ydotoold)"

# ── 4. Install vocalinux ─────────────────────────────────────────────────────
info "Installing vocalinux..."
if [ "$DISTRO" = "fedora" ]; then
    sudo dnf install -y python3-pip portaudio-devel python3-devel
else
    sudo apt-get install -y python3-pip portaudio19-dev python3-dev
fi

VOCALINUX_VENV="$HOME/.local/share/vocalinux/venv"
python3 -m venv "$VOCALINUX_VENV"
"$VOCALINUX_VENV/bin/pip" install --quiet --upgrade pip
"$VOCALINUX_VENV/bin/pip" install --quiet vocalinux pyaudio

# ── 5. vocalinux config ──────────────────────────────────────────────────────
info "Installing vocalinux config..."
mkdir -p ~/.config/vocalinux
cp "$(dirname "$0")/config/vocalinux.json" ~/.config/vocalinux/config.json

# ── 6. Set default PipeWire mic ──────────────────────────────────────────────
info "Detecting microphone..."
USB_MIC=$(pactl list sources short 2>/dev/null \
    | grep -i "alsa_input.usb" \
    | grep -v "monitor" \
    | awk '{print $2}' \
    | head -1)

if [ -n "$USB_MIC" ]; then
    info "Found USB mic: $USB_MIC"
    pactl set-default-source "$USB_MIC"

    mkdir -p ~/.config/wireplumber/wireplumber.conf.d
    cat > ~/.config/wireplumber/wireplumber.conf.d/51-default-source.conf <<EOF
wireplumber.settings = {
  default.audio.source = "$USB_MIC"
}
EOF
    info "Set as persistent default mic."
else
    warn "No USB mic detected. Set your default mic manually with:"
    warn "  pactl set-default-source <source-name>"
    warn "  (list sources: pactl list sources short)"
fi

# ── 7. Desktop entry ─────────────────────────────────────────────────────────
info "Creating vocalinux desktop entry..."
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/vocalinux.desktop <<EOF
[Desktop Entry]
Name=Vocalinux
Comment=Arabic speech-to-text dictation
Exec=$VOCALINUX_VENV/bin/vocalinux-gui
Icon=audio-input-microphone
Type=Application
Categories=Utility;Accessibility;
EOF

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
info "Host setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Copy .env.example to .env and add your HuggingFace token"
echo "  2. Run:  docker compose up -d"
echo "  3. Wait for the model to load (~60s first run, then cached)"
echo "  4. Launch vocalinux from your app menu or run:"
echo "       $VOCALINUX_VENV/bin/vocalinux-gui"
echo ""

if [ "${NEED_RELOGIN:-0}" = "1" ]; then
    warn "You were added to the 'input' group. Please LOG OUT and back in before using ydotool."
fi
