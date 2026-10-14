#!/bin/bash
#
# Turns a Raspberry Pi OS (Desktop) install into a headless server by removing
# the desktop, browsers and bundled desktop apps. See tools/README.md.
#
# Usage:
#   sudo ./strip-desktop.sh
#   sudo EXTRA_KEEP="cloudflared nginx" ./strip-desktop.sh   # protect more packages
#
# Does not reboot; reboot yourself once it reports that everything is in place.
#

set -euo pipefail

DESKTOP="agnostics chromium firefox geany labwc lightdm lxpanel-pi lxterminal pcmanfm
pi-greeter piwiz realvnc-vnc-server rp-prefapps rpd-applications rpd-common rpd-developer
rpd-graphics rpd-plym-splash rpd-preferences rpd-theme rpd-utilities rpd-wallpaper
rpd-wallpaper-trixie rpd-wayland-core rpd-wayland-extras rpd-x-core rpd-x-extras rpi-imager
thonny vlc xserver-xorg-core xwayland"

# What a headless Pi needs to stay reachable, plus what the HomePod bridge uses.
# Several of these (e.g. openssh-server, git) are only installed as dependencies
# of the desktop on some images, so autoremove would otherwise take them away.
KEEP="openssh-server git network-manager wpasupplicant iw avahi-daemon owntone
python3 python3-websockets curl ca-certificates alsa-utils sudo ${EXTRA_KEEP:-}"

installed() {
    # shellcheck disable=SC2086 # word splitting of the package lists is intended
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' $1 2>/dev/null | awk '$1=="ii"{print $2}'
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

keep=$(installed "$KEEP")
remove=$(installed "$DESKTOP")

if [ -z "$remove" ]; then
    echo "No desktop packages installed, nothing to do."
    exit 0
fi

echo "Protecting: $(echo "$keep" | xargs)"
# shellcheck disable=SC2086
apt-mark manual $keep > /dev/null

systemctl set-default multi-user.target

# shellcheck disable=SC2086
apt-get purge -y --autoremove $remove

missing=""
for p in $keep; do
    dpkg -s "$p" > /dev/null 2>&1 || missing="$missing $p"
done
if [ -n "$missing" ]; then
    echo
    echo "!!! These packages were removed:$missing"
    echo "!!! Do NOT reboot. Reinstall them first: sudo apt-get install$missing"
    exit 1
fi

apt-get clean

echo
echo "Desktop removed; all protected packages are still installed."
echo "Disk: $(df -h / | awk 'NR==2{print $3" used, "$4" free"}')"
echo "Reboot when ready: sudo reboot"
