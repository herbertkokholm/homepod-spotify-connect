#!/bin/bash
#
# HomePod Spotify Connect - SD Card Preparation
#
# Optional helper script to configure an already-imaged SD card for headless boot.
# Run this on your workstation after imaging with Raspberry Pi Imager.
#
# Usage:
#   ./prepare-sd.sh                    # Interactive mode
#   ./prepare-sd.sh --instructions     # Print manual setup guide
#

set -e

# ============================================================================
# CONFIGURATION - Edit these or set via environment
# ============================================================================

WIFI_COUNTRY="${WIFI_COUNTRY:-DK}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
PI_USERNAME="${PI_USERNAME:-pi}"
PI_PASSWORD="${PI_PASSWORD:-}"
PI_HOSTNAME="${PI_HOSTNAME:-homepod-bridge}"
TIMEZONE="${TIMEZONE:-Europe/Copenhagen}"

# ============================================================================
# PRINT INSTRUCTIONS
# ============================================================================

print_instructions() {
    cat << 'EOF'
================================================================================
RASPBERRY PI SETUP INSTRUCTIONS
================================================================================

RECOMMENDED: Use Raspberry Pi Imager (handles everything automatically)
--------------------------------------------------------------------------------

1. Download Raspberry Pi Imager:
   https://www.raspberrypi.com/software/

2. Run Imager and select:
   - Device:  Raspberry Pi 4 or 5
   - OS:      Raspberry Pi OS (64-bit)
   - Storage: Your SD card

3. Click the GEAR ICON (⚙️) before writing:

   ┌─ OS Customisation ─────────────────────────────────────────┐
   │                                                             │
   │  ☑ Set hostname:        homepod-bridge                     │
   │                                                             │
   │  ☑ Enable SSH                                               │
   │    ○ Use password authentication                            │
   │                                                             │
   │  ☑ Set username and password                                │
   │    Username: pi                                             │
   │    Password: ********                                       │
   │                                                             │
   │  ☑ Configure wireless LAN                                   │
   │    SSID:     YourNetwork                                    │
   │    Password: ********                                       │
   │    Country:  DK                                             │
   │                                                             │
   │  ☑ Set locale settings                                      │
   │    Time zone:       Europe/Copenhagen                       │
   │    Keyboard layout: dk                                      │
   │                                                             │
   └─────────────────────────────────────────────────────────────┘

4. Click WRITE and wait for completion

5. Insert SD card into Pi and power on

6. Wait 2-3 minutes, then connect:
   
   ssh pi@homepod-bridge.local

7. Deploy:

   # On your workstation:
   git clone https://github.com/YOUR_USERNAME/homepod-spotify-connect.git
   scp homepod-spotify-connect/deploy.sh pi@homepod-bridge.local:~

   # On the Pi:
   chmod +x deploy.sh
   sudo ./deploy.sh

================================================================================
EOF
}

# ============================================================================
# DETECT SD CARD
# ============================================================================

detect_boot_mount() {
    local candidates=(
        "/Volumes/bootfs"
        "/Volumes/boot"
        "/media/$USER/bootfs"
        "/media/$USER/boot"
        "/run/media/$USER/bootfs"
        "/run/media/$USER/boot"
        "/mnt/boot"
    )
    
    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ] && [ -f "$candidate/cmdline.txt" ]; then
            echo "$candidate"
            return 0
        fi
    done
    
    return 1
}

# ============================================================================
# MAIN
# ============================================================================

if [ "$1" == "--instructions" ] || [ "$1" == "-i" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    print_instructions
    exit 0
fi

echo ""
echo "HomePod Spotify Connect - SD Card Preparation"
echo "=============================================="
echo ""

BOOT_MOUNT=$(detect_boot_mount) || {
    echo "No SD card boot partition detected."
    echo ""
    echo "Options:"
    echo "  1. Mount your SD card and run again"
    echo "  2. Run: $0 --instructions"
    echo ""
    echo "Tip: Use Raspberry Pi Imager instead - it's easier!"
    exit 1
}

echo "Found boot partition: $BOOT_MOUNT"
echo ""

# Prompt for missing values
if [ -z "$WIFI_SSID" ]; then
    read -p "WiFi SSID: " WIFI_SSID
fi

if [ -z "$WIFI_PASSWORD" ]; then
    read -s -p "WiFi Password: " WIFI_PASSWORD
    echo ""
fi

if [ -z "$PI_PASSWORD" ]; then
    read -s -p "Pi Password: " PI_PASSWORD
    echo ""
fi

echo ""
echo "Configuring SD card..."

# Enable SSH
touch "$BOOT_MOUNT/ssh"
echo "  ✓ SSH enabled"

# WiFi configuration
cat > "$BOOT_MOUNT/wpa_supplicant.conf" << EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$WIFI_COUNTRY

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASSWORD"
    key_mgmt=WPA-PSK
}
EOF
echo "  ✓ WiFi configured"

# User configuration (Bookworm style)
if command -v openssl &> /dev/null; then
    HASHED_PASS=$(echo "$PI_PASSWORD" | openssl passwd -6 -stdin)
    echo "$PI_USERNAME:$HASHED_PASS" > "$BOOT_MOUNT/userconf.txt"
    echo "  ✓ User configured"
else
    echo "  ⚠ openssl not found, skipping userconf.txt"
fi

echo ""
echo "Done! Next steps:"
echo ""
echo "  1. Eject SD card safely"
echo "  2. Insert into Pi and power on"
echo "  3. Wait 2-3 minutes"
echo "  4. Connect: ssh $PI_USERNAME@$PI_HOSTNAME.local"
echo ""
