#!/bin/bash
#
# HomePod Spotify Connect - Deployment Script
# https://github.com/herbertkokholm/homepod-spotify-connect
#
# Installs SpoCon + OwnTone to make HomePod appear as a Spotify Connect device.
#
# Usage:
#   chmod +x deploy.sh
#   sudo ./deploy.sh
#
# Requirements:
#   - Raspberry Pi 4 or 5
#   - Raspberry Pi OS Bookworm (64-bit)
#   - Spotify Premium account
#   - HomePod on same network
#

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================

DEVICE_NAME="${SPOTIFY_DEVICE_NAME:-HomePod}"
AUDIO_QUALITY="${SPOTIFY_AUDIO_QUALITY:-VORBIS_320}"

# Paths
MUSIC_DIR="/srv/music"
SPOTIFY_PIPE="$MUSIC_DIR/spotify"
METADATA_PIPE="$MUSIC_DIR/spotify.metadata"
SPOCON_CONFIG="/opt/spocon/config.toml"
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
    
    if [[ "$ARCH" != "arm64" && "$ARCH" != "armhf" ]]; then
        log_warn "Untested architecture: $ARCH"
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_VERSION=$VERSION_CODENAME
        log_info "OS: $PRETTY_NAME"
    else
        log_error "Cannot detect OS version"
        exit 1
    fi
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_prerequisites() {
    log_step "Installing prerequisites..."
    
    apt-get update -qq
    apt-get install -y -qq \
        software-properties-common \
        curl \
        wget \
        gnupg \
        apt-transport-https \
        ca-certificates \
        > /dev/null
    
    log_info "Prerequisites installed"
}

install_java() {
    log_step "Installing Java..."
    
    apt-get install -y -qq default-jdk default-jre > /dev/null
    
    if java -version 2>&1 | grep -q "openjdk"; then
        log_info "Java installed: $(java -version 2>&1 | head -n 1)"
    else
        log_error "Java installation failed"
        exit 1
    fi
}

install_spocon() {
    log_step "Installing SpoCon..."
    
    # Try official installer first
    if curl -sL https://spocon.github.io/spocon/install.sh | sh 2>/dev/null; then
        log_info "SpoCon installed via official script"
        return 0
    fi
    
    log_warn "Official installer failed, trying manual method..."
    
    # Manual installation
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 7DBE8BF06EA39B78 2>/dev/null || true
    echo 'deb http://ppa.launchpad.net/spocon/spocon/ubuntu bionic main' | tee /etc/apt/sources.list.d/spocon.list > /dev/null
    apt-get update -qq
    
    if apt-get install -y -qq spocon 2>/dev/null; then
        log_info "SpoCon installed"
        return 0
    fi
    
    # Fix dependencies for Bookworm
    log_warn "Fixing dependencies for Bookworm..."
    
    local SPOCON_DEB="/tmp/spocon.deb"
    local WORK_DIR="/tmp/spocon_work"
    
    wget -q -O "$SPOCON_DEB" "http://ppa.launchpad.net/spocon/spocon/ubuntu/pool/main/s/spocon/spocon_0.14.0_all.deb" || {
        log_error "Failed to download SpoCon"
        exit 1
    }
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    dpkg-deb -R "$SPOCON_DEB" extracted/
    
    # Fix Java dependency
    sed -i 's/openjdk-11-jre-headless/default-jre-headless | openjdk-17-jre-headless | openjdk-11-jre-headless/g' extracted/DEBIAN/control
    
    dpkg-deb -b extracted/ /tmp/spocon_fixed.deb
    dpkg -i /tmp/spocon_fixed.deb || apt-get install -f -y -qq
    
    cd /
    rm -rf "$WORK_DIR" "$SPOCON_DEB" /tmp/spocon_fixed.deb
    
    log_info "SpoCon installed with dependency fixes"
}

setup_pipes() {
    log_step "Setting up named pipes..."
    
    mkdir -p "$MUSIC_DIR"
    rm -f "$SPOTIFY_PIPE" "$METADATA_PIPE"
    
    mkfifo "$SPOTIFY_PIPE"
    mkfifo "$METADATA_PIPE"
    
    chown -R root:root "$MUSIC_DIR"
    chmod 755 "$MUSIC_DIR"
    chmod 666 "$SPOTIFY_PIPE" "$METADATA_PIPE"
    
    log_info "Pipes created at $MUSIC_DIR"
}

configure_spocon() {
    log_step "Configuring SpoCon..."
    
    [ -f "$SPOCON_CONFIG" ] && cp "$SPOCON_CONFIG" "${SPOCON_CONFIG}.bak"
    
    mkdir -p /tmp/spocon_cache
    chmod 755 /tmp/spocon_cache
    
    cat > "$SPOCON_CONFIG" << EOF
deviceName = "$DEVICE_NAME"
deviceType = "SPEAKER"
preferredLocale = "en"

[auth]
strategy = "ZEROCONF"
username = ""
password = ""
blob = ""

[zeroconf]
listenPort = -1
listenAll = true
interfaces = ""

[cache]
enabled = true
dir = "/tmp/spocon_cache/"
doCleanUp = true

[preload]
enabled = true

[time]
synchronizationMethod = "NTP"
manualCorrection = 0

[player]
autoplayEnabled = true
preferredAudioQuality = "$AUDIO_QUALITY"
enableNormalisation = true
normalisationPregain = 3.0
initialVolume = 21845
logAvailableMixers = true
mixerSearchKeywords = ""
crossfadeDuration = 0
output = "PIPE"
releaseLineDelay = 20
pipe = "$SPOTIFY_PIPE"
metadataPipe = "$METADATA_PIPE"
volumeSteps = 64
EOF
    
    log_info "SpoCon configured (device: $DEVICE_NAME)"
}

install_owntone() {
    log_step "Installing OwnTone..."
    
    # Add repository
    wget -q -O - https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi/owntone.gpg | \
        gpg --dearmor --output /usr/share/keyrings/owntone-archive-keyring.gpg 2>/dev/null
    
    local repo_url="https://raw.githubusercontent.com/owntone/owntone-apt/refs/heads/master/repo/rpi"
    
    case "$OS_VERSION" in
        bookworm|trixie)
            wget -q -O /etc/apt/sources.list.d/owntone.list "$repo_url/owntone-bookworm.list"
            ;;
        bullseye)
            wget -q -O /etc/apt/sources.list.d/owntone.list "$repo_url/owntone-bullseye.list"
            ;;
        *)
            wget -q -O /etc/apt/sources.list.d/owntone.list "$repo_url/owntone-bookworm.list"
            ;;
    esac
    
    apt-get update -qq
    
    if ! apt-get install -y -qq owntone 2>/dev/null; then
        apt-get install -f -y -qq
        apt-get install -y -qq owntone || {
            log_error "OwnTone installation failed"
            exit 1
        }
    fi
    
    log_info "OwnTone installed"
}

configure_owntone() {
    log_step "Configuring OwnTone..."
    
    [ -f "$OWNTONE_CONFIG" ] && cp "$OWNTONE_CONFIG" "${OWNTONE_CONFIG}.bak"
    
    # Ensure pipe directory is in library and autostart is enabled
    if [ -f "$OWNTONE_CONFIG" ]; then
        # Add pipe_autostart if not present
        if ! grep -q "pipe_autostart = true" "$OWNTONE_CONFIG"; then
            sed -i '/^\[library\]/a\\tpipe_autostart = true' "$OWNTONE_CONFIG" 2>/dev/null || true
        fi
        
        # Add music directory
        if ! grep -q "/srv/music" "$OWNTONE_CONFIG"; then
            sed -i 's|directories = {|directories = { "/srv/music",|' "$OWNTONE_CONFIG" 2>/dev/null || true
        fi
    fi
    
    log_info "OwnTone configured"
}

configure_firewall() {
    log_step "Configuring firewall..."
    
    if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 5355/udp comment "mDNS for SpoCon" > /dev/null
        ufw allow 3689/tcp comment "OwnTone web UI" > /dev/null
        log_info "Firewall rules added"
    else
        log_info "No active firewall, skipping"
    fi
}

start_services() {
    log_step "Starting services..."
    
    systemctl daemon-reload
    
    systemctl enable spocon --quiet
    systemctl restart spocon
    
    systemctl enable owntone --quiet
    systemctl restart owntone
    
    sleep 3
    
    local spocon_status="✗"
    local owntone_status="✗"
    
    systemctl is-active --quiet spocon && spocon_status="✓"
    systemctl is-active --quiet owntone && owntone_status="✓"
    
    log_info "SpoCon:  $spocon_status"
    log_info "OwnTone: $owntone_status"
}

install_status_script() {
    cat > /usr/local/bin/homepod-spotify-status << 'EOF'
#!/bin/bash
echo "=== HomePod Spotify Connect Status ==="
echo ""
echo "SpoCon:"
systemctl is-active spocon && echo "  Status: Running ✓" || echo "  Status: Stopped ✗"
echo ""
echo "OwnTone:"
systemctl is-active owntone && echo "  Status: Running ✓" || echo "  Status: Stopped ✗"
echo ""
echo "Pipes:"
[ -p /srv/music/spotify ] && echo "  /srv/music/spotify ✓" || echo "  /srv/music/spotify ✗"
[ -p /srv/music/spotify.metadata ] && echo "  /srv/music/spotify.metadata ✓" || echo "  /srv/music/spotify.metadata ✗"
echo ""
IP=$(hostname -I | awk '{print $1}')
echo "OwnTone Web UI: http://$IP:3689"
echo ""
echo "Commands:"
echo "  sudo systemctl restart spocon"
echo "  sudo systemctl restart owntone"
echo "  sudo journalctl -u spocon -f"
EOF
    chmod +x /usr/local/bin/homepod-spotify-status
}

print_summary() {
    local IP=$(hostname -I | awk '{print $1}')
    local HOSTNAME=$(hostname)
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           HomePod Spotify Connect - Setup Complete           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Device Name:     $DEVICE_NAME"
    echo "  Audio Quality:   $AUDIO_QUALITY"
    echo ""
    echo "  OwnTone Web UI:  http://$IP:3689"
    echo "                   http://$HOSTNAME.local:3689"
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│  NEXT STEPS                                                  │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│  1. Open OwnTone in browser: http://$IP:3689"
    echo "│  2. Go to Settings → Remotes & Outputs                       │"
    echo "│  3. Enable your HomePod (click speaker icon)                 │"
    echo "│  4. Open Spotify → Connect to device → Select '$DEVICE_NAME'"
    echo "└──────────────────────────────────────────────────────────────┘"
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
    
    echo ""
    
    install_prerequisites
    install_java
    install_spocon
    setup_pipes
    configure_spocon
    install_owntone
    configure_owntone
    configure_firewall
    start_services
    install_status_script
    
    print_summary
}

main "$@"
