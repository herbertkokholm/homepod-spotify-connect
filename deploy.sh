#!/bin/bash
#
# HomePod Spotify Connect - Deployment Script
# https://github.com/herbertkokholm/homepod-spotify-connect
#
# Installs go-librespot + OwnTone to make a HomePod appear as a Spotify
# Connect device, plus a bridge that keeps both volumes in sync.
# Safe to re-run; re-running also updates go-librespot to the latest release.
#
# Usage (from a clone of this repo on the Pi):
#   sudo ./deploy.sh
#
#   # Optional overrides:
#   sudo SPOTIFY_DEVICE_NAME="Living Room HomePod" SPOTIFY_BITRATE=160 ./deploy.sh
#
# Requirements:
#   - Raspberry Pi 4 or 5 (arm64 or armhf)
#   - Raspberry Pi OS / Debian Bookworm or Trixie
#   - Spotify Premium account
#   - HomePod on the same network/subnet as the Pi
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DEVICE_NAME="${SPOTIFY_DEVICE_NAME:-HomePod}"
BITRATE="${SPOTIFY_BITRATE:-320}"          # 96, 160 or 320
INITIAL_VOLUME="${SPOTIFY_INITIAL_VOLUME:-50}"
GO_LIBRESPOT_VERSION="${GO_LIBRESPOT_VERSION:-latest}"   # or a tag, e.g. v0.10.2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSIC_DIR="/srv/music"
SPOTIFY_PIPE="$MUSIC_DIR/spotify"
METADATA_PIPE="$MUSIC_DIR/spotify.metadata"
SERVICE_USER="go-librespot"
GO_LIBRESPOT_BIN="/usr/local/bin/go-librespot"
GO_LIBRESPOT_DIR="/var/lib/go-librespot"
BRIDGE_BIN="/usr/local/bin/homepod-volume-bridge"
OWNTONE_CONFIG="/etc/owntone.conf"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_architecture() {
    ARCH=$(dpkg --print-architecture)
    log_info "Architecture: $ARCH"

    case "$ARCH" in
        arm64) GO_LIBRESPOT_ASSET="go-librespot_linux_arm64.tar.gz" ;;
        armhf) GO_LIBRESPOT_ASSET="go-librespot_linux_armv6_rpi.tar.gz" ;;
        amd64) GO_LIBRESPOT_ASSET="go-librespot_linux_x86_64.tar.gz" ;;
        *)
            log_error "No go-librespot build for architecture: $ARCH"
            exit 1
            ;;
    esac
}

check_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_VERSION=$VERSION_CODENAME
        log_info "OS: $PRETTY_NAME"
    else
        log_error "Cannot detect OS version"
        exit 1
    fi
}

check_files() {
    if [ ! -f "$SCRIPT_DIR/volume-bridge.py" ]; then
        log_error "volume-bridge.py not found next to deploy.sh - run this from a clone of the repo"
        exit 1
    fi
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_prerequisites() {
    log_step "Installing prerequisites..."

    apt-get update -qq
    # alsa-utils pulls in libasound2, go-librespot's only shared-library
    # dependency (its package name differs between releases)
    apt-get install -y -qq curl gnupg ca-certificates avahi-daemon avahi-utils \
        python3 python3-websockets alsa-utils > /dev/null
    systemctl enable --now avahi-daemon --quiet

    log_info "Prerequisites installed"
}

install_owntone() {
    log_step "Installing OwnTone..."

    local repo_url="https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi"

    curl -sSfL "$repo_url/owntone.gpg" | gpg --dearmor --yes --output /usr/share/keyrings/owntone-archive-keyring.gpg

    case "$OS_VERSION" in
        bullseye|bookworm|trixie) ;;
        *) log_warn "No OwnTone repo for '$OS_VERSION', using trixie"; OS_VERSION=trixie ;;
    esac
    curl -sSfL "$repo_url/owntone-$OS_VERSION.list" -o /etc/apt/sources.list.d/owntone.list

    apt-get update -qq
    apt-get install -y -qq owntone > /dev/null

    log_info "OwnTone installed: $(dpkg-query -W -f='${Version}' owntone)"
}

install_go_librespot() {
    log_step "Installing go-librespot ($GO_LIBRESPOT_VERSION)..."

    local base="https://github.com/devgianlu/go-librespot/releases"
    local url
    if [ "$GO_LIBRESPOT_VERSION" = "latest" ]; then
        url="$base/latest/download/$GO_LIBRESPOT_ASSET"
    else
        url="$base/download/$GO_LIBRESPOT_VERSION/$GO_LIBRESPOT_ASSET"
    fi

    local tmp
    tmp=$(mktemp -d)
    curl -sSfL "$url" | tar -xz -C "$tmp" go-librespot
    install -m 755 "$tmp/go-librespot" "$GO_LIBRESPOT_BIN"
    rm -rf "$tmp"

    if ! id "$SERVICE_USER" &> /dev/null; then
        useradd --system --home-dir "$GO_LIBRESPOT_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    install -d -m 750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$GO_LIBRESPOT_DIR"

    log_info "go-librespot installed"
}

setup_pipes() {
    log_step "Setting up named pipes..."

    mkdir -p "$MUSIC_DIR"
    chmod 755 "$MUSIC_DIR"

    # OwnTone looks for a metadata pipe next to the audio pipe; go-librespot
    # doesn't write one, but an empty FIFO keeps OwnTone from logging errors
    local pipe
    for pipe in "$SPOTIFY_PIPE" "$METADATA_PIPE"; do
        if [ ! -p "$pipe" ]; then
            rm -f "$pipe"
            mkfifo "$pipe"
        fi
        # go-librespot and OwnTone run as different users
        chmod 666 "$pipe"
    done

    log_info "Pipes ready at $MUSIC_DIR"
}

configure_go_librespot() {
    log_step "Configuring go-librespot..."

    # external_volume: Spotify's slider stays enabled, but the samples are left
    # untouched - the volume bridge applies it as the HomePod's AirPlay volume
    cat > "$GO_LIBRESPOT_DIR/config.yml" << EOF
device_name: "$DEVICE_NAME"
device_type: speaker
bitrate: $BITRATE

audio_backend: pipe
audio_output_pipe: $SPOTIFY_PIPE
audio_output_pipe_format: s16le
audio_output_pipe_wait_for_reader: true

external_volume: true
volume_steps: 100
initial_volume: $INITIAL_VOLUME

zeroconf_enabled: true
zeroconf_backend: avahi
credentials:
  type: zeroconf
  zeroconf:
    persist_credentials: false

server:
  enabled: true
  address: localhost
  port: 3678
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$GO_LIBRESPOT_DIR/config.yml"

    cat > /etc/systemd/system/go-librespot.service << EOF
[Unit]
Description=go-librespot (Spotify Connect)
Documentation=https://github.com/devgianlu/go-librespot
After=network-online.target avahi-daemon.service owntone.service
Wants=network-online.target

[Service]
User=$SERVICE_USER
ExecStart=$GO_LIBRESPOT_BIN --config_dir $GO_LIBRESPOT_DIR
Restart=always
RestartSec=5

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$GO_LIBRESPOT_DIR $MUSIC_DIR

[Install]
WantedBy=multi-user.target
EOF

    log_info "go-librespot configured (device: $DEVICE_NAME, ${BITRATE} kbps)"
}

install_volume_bridge() {
    log_step "Installing volume bridge..."

    install -m 755 "$SCRIPT_DIR/volume-bridge.py" "$BRIDGE_BIN"

    cat > /etc/systemd/system/homepod-volume-bridge.service << EOF
[Unit]
Description=HomePod Spotify Connect volume bridge (go-librespot <-> OwnTone)
After=go-librespot.service owntone.service
Wants=go-librespot.service owntone.service

[Service]
DynamicUser=true
ExecStart=$BRIDGE_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    log_info "Volume bridge installed"
}

configure_owntone() {
    log_step "Configuring OwnTone..."

    # HomePod OS 27 rejects AirPlay clients whose User-Agent isn't AirPlay-like
    # (403 on GET /info). Fixed upstream after 29.3, see owntone-server#2042.
    if ! grep -Eq '^\s*user_agent\s*=' "$OWNTONE_CONFIG"; then
        cp "$OWNTONE_CONFIG" "${OWNTONE_CONFIG}.bak"
        sed -i '0,/^general {/s//general {\n\tuser_agent = "AirPlay\/999.0.0"/' "$OWNTONE_CONFIG"
        log_info "Set OwnTone user_agent for HomePod OS 27 compatibility"
    fi

    # OwnTone's default config already scans /srv/music and autostarts pipes
    # (pipe_autostart defaults to true); only warn if that has been changed.
    if ! grep -Eq '^\s*directories\s*=.*"/srv/music"' "$OWNTONE_CONFIG"; then
        log_warn "$OWNTONE_CONFIG: library 'directories' does not include \"$MUSIC_DIR\" - add it manually"
    fi
    if grep -Eq '^\s*pipe_autostart\s*=\s*false' "$OWNTONE_CONFIG"; then
        log_warn "$OWNTONE_CONFIG: pipe_autostart is false - set it to true"
    fi

    log_info "OwnTone configured"
}

start_services() {
    log_step "Starting services..."

    systemctl daemon-reload

    local svc
    for svc in owntone go-librespot homepod-volume-bridge; do
        systemctl enable "$svc" --quiet
        systemctl restart "$svc"
    done

    sleep 3

    for svc in owntone go-librespot homepod-volume-bridge; do
        if systemctl is-active --quiet "$svc"; then
            log_info "$svc: ✓"
        else
            log_warn "$svc: ✗ (sudo journalctl -u $svc -n 50)"
        fi
    done
}

install_status_script() {
    cat > /usr/local/bin/homepod-spotify-status << 'EOF'
#!/bin/bash
echo "=== HomePod Spotify Connect Status ==="
echo ""
for svc in go-librespot owntone homepod-volume-bridge; do
    printf "%-23s " "$svc:"
    systemctl is-active --quiet "$svc" && echo "running ✓" || echo "stopped ✗"
done
echo ""
[ -p /srv/music/spotify ] && echo "Pipe: /srv/music/spotify ✓" || echo "Pipe: /srv/music/spotify ✗"
echo ""
echo "AirPlay devices on network:"
timeout 5 avahi-browse -tp _airplay._tcp 2>/dev/null | awk -F';' '$1=="+" {print "  " $4}' | sort -u
echo ""
IP=$(hostname -I | awk '{print $1}')
echo "OwnTone Web UI: http://$IP:3689"
echo ""
echo "Logs:"
echo "  sudo journalctl -u go-librespot -f"
echo "  sudo journalctl -u homepod-volume-bridge -f"
echo "  sudo tail -f /var/log/owntone.log"
EOF
    chmod +x /usr/local/bin/homepod-spotify-status
}

print_summary() {
    local IP
    IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           HomePod Spotify Connect - Setup Complete           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Device Name:     $DEVICE_NAME"
    echo "  Bitrate:         $BITRATE kbps"
    echo "  OwnTone Web UI:  http://$IP:3689"
    echo ""
    echo "  NEXT STEPS"
    echo "  1. Open http://$IP:3689 → Outputs (speaker icon, top bar)"
    echo "  2. Enable your HomePod"
    echo "  3. Spotify → Connect to a device → '$DEVICE_NAME'"
    echo ""
    echo "  Status command:  homepod-spotify-status"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo ""
    echo "HomePod Spotify Connect - Deployment Script"
    echo "============================================"
    echo ""

    check_root
    check_architecture
    check_os
    check_files

    echo ""

    install_prerequisites
    install_owntone
    install_go_librespot
    setup_pipes
    configure_go_librespot
    install_volume_bridge
    configure_owntone
    start_services
    install_status_script

    print_summary
}

main "$@"
