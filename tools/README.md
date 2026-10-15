# Tools

Optional helper scripts. They are not run by `deploy.sh`.

## strip-desktop.sh

Turns a Pi installed with **Raspberry Pi OS (Desktop)** into a headless server. It removes the desktop, Chromium, Firefox, VLC, Thonny, VNC and the other bundled desktop apps, and boots to the console instead of a graphical login.

This matters on a bridge Pi with a weak Wi-Fi link. The desktop image pulls in several hundred MB per `apt upgrade`, and while that downloads, OwnTone's AirPlay stream stutters. On a test Pi, removing the desktop dropped about 600 packages.

```bash
sudo ./tools/strip-desktop.sh

# Protect extra packages that only came in as dependencies:
sudo EXTRA_KEEP="cloudflared nginx" ./tools/strip-desktop.sh
```

What it does:

1. Marks the packages a headless bridge needs as manually installed, so autoremove can't take them away: SSH, git, NetworkManager/Wi-Fi, avahi, OwnTone, Python + websockets, curl, ALSA, sudo and unattended-upgrades, plus anything in `EXTRA_KEEP`.
2. Sets the default boot target to `multi-user.target` (no graphical login).
3. Purges the desktop packages with `--autoremove`.
4. Checks that every protected package is still installed. If one is missing it stops and tells you **not** to reboot, and which `apt-get install` command brings it back.
5. Clears the apt cache.

It never reboots on its own.

**Before running it**, especially on a Pi you can only reach over Wi-Fi, preview what would be removed:

```bash
apt-get -s purge --autoremove $(dpkg-query -W -f='${Package}\n' 'rpd-*' lightdm chromium firefox 2>/dev/null) | grep ^Purg
```

Check that nothing you rely on is in the list. If something is, add it to `EXTRA_KEEP`.
