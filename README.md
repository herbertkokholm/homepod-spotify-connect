# HomePod Spotify Connect Bridge

Turn your Apple HomePod into a Spotify Connect device using a Raspberry Pi.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204%2F5-red.svg)
![OS](https://img.shields.io/badge/OS-Bookworm%20%7C%20Trixie-green.svg)

## Overview

Apple HomePod doesn't natively support Spotify Connect, limiting it to AirPlay from Apple devices. This project bridges that gap by using a Raspberry Pi to:

1. **Receive** Spotify Connect streams (via [go-librespot](https://github.com/devgianlu/go-librespot))
2. **Forward** audio to HomePod (via [OwnTone](https://github.com/owntone/owntone-server)/AirPlay 2)
3. **Sync** volume both ways — the Spotify slider sets the HomePod's own volume, and the HomePod's buttons/Siri move the Spotify slider

The result: Your HomePod appears as a Spotify Connect device to any Spotify app on your network.

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌─────────────┐
│  Spotify    │────▶│ go-librespot │────▶│   OwnTone   │────▶│   HomePod   │
│    App      │     │    (Pi)      │     │  (AirPlay)  │     │             │
└─────────────┘     └──────────────┘     └─────────────┘     └─────────────┘
                        │    ▲  └── Named Pipe ──┘  ▲
                        ▼    │                      │
                     ┌───────┴──────────────────────┴┐
                     │ volume bridge (both ways)     │
                     └───────────────────────────────┘
```

## Requirements

### Hardware
- Raspberry Pi 4 or 5 (Pi 3B+ works but Pi 4+ recommended)
- MicroSD card (16GB minimum)
- Apple HomePod or HomePod mini
- Ethernet recommended — AirPlay audio is sensitive to weak Wi-Fi

### Software
- Raspberry Pi OS / Debian Bookworm or Trixie (64-bit recommended)
- Spotify Premium account

### Network
- Pi and HomePod on the same network/subnet (discovery uses mDNS)
- HomePod reachable from the Pi — see [HomePod access](#homepod-refuses-the-connection-403-forbidden)

The bridge is light (~150 MB RAM in total: OwnTone ~60 MB, go-librespot ~50 MB, volume bridge ~30 MB), so it can share a Pi with other services.

## Quick Start

### 1. Prepare the Raspberry Pi

Flash Raspberry Pi OS (64-bit) with [Raspberry Pi Imager](https://www.raspberrypi.com/software/). In the OS customisation settings, set a hostname (e.g. `homepod-bridge`), enable SSH, set a username/password and configure Wi-Fi if you're not using Ethernet.

### 2. Deploy

```bash
ssh pi@homepod-bridge.local
git clone https://github.com/herbertkokholm/homepod-spotify-connect.git
cd homepod-spotify-connect
sudo ./deploy.sh
```

The script is safe to re-run; re-running also updates go-librespot to its latest release.

### 3. Enable the HomePod in OwnTone

1. Open `http://homepod-bridge.local:3689`
2. Click the **speaker icon** in the top bar (Outputs)
3. Enable your HomePod

### 4. Play Music!

1. Open Spotify on any device
2. Click the **Connect to a device** icon
3. Select **"HomePod"**

## Configuration

Settings are passed as environment variables to `deploy.sh`:

| Variable                 | Default    | Description                           |
| ------------------------ | ---------- | ------------------------------------- |
| `SPOTIFY_DEVICE_NAME`    | `HomePod`  | Name shown in Spotify                 |
| `SPOTIFY_BITRATE`        | `320`      | `96`, `160` or `320` kbps             |
| `SPOTIFY_INITIAL_VOLUME` | `50`       | Volume (0–100) when a client connects |
| `GO_LIBRESPOT_VERSION`   | `latest`   | A release tag, e.g. `v0.10.2`         |

```bash
sudo SPOTIFY_DEVICE_NAME="Living Room HomePod" ./deploy.sh
```

The generated go-librespot config lives in `/var/lib/go-librespot/config.yml`; re-running `deploy.sh` overwrites it.

## How It Works

1. **go-librespot** implements the Spotify Connect protocol and writes raw PCM (s16le, 44.1 kHz) to a named pipe (`/srv/music/spotify`)
2. **OwnTone** picks up the pipe from its library and streams it to the HomePod via AirPlay 2
3. go-librespot runs with `external_volume`, so it never scales the audio itself. The **volume bridge** (`volume-bridge.py`) listens to both go-librespot's and OwnTone's websocket events and mirrors volume changes between them, so the HomePod's own volume is the only volume stage. Changes made on the HomePod itself (buttons, Siri, Home app) reach OwnTone and are mirrored back to Spotify too

| Service                 | Runs as              | Port(s)                               |
| ----------------------- | -------------------- | ------------------------------------- |
| `go-librespot`          | `go-librespot`       | 3678 (API, localhost), random (Connect) |
| `owntone`               | `owntone`            | 3689 (web UI), 3688 (websocket)       |
| `homepod-volume-bridge` | dynamic user         | —                                     |

## Troubleshooting

### Check Service Status

```bash
# Quick status check, incl. AirPlay devices the Pi can see
homepod-spotify-status

# Logs
sudo journalctl -u go-librespot -f
sudo journalctl -u homepod-volume-bridge -f
sudo tail -f /var/log/owntone.log
```

### HomePod refuses the connection (403 Forbidden)

OwnTone logs `Response to GET /info ... was negative, aborting (403 Forbidden)`. There are two causes:

1. **Home app access setting** — Home → Home Settings → Speakers & TV → Allow Speaker & TV Access → **Everyone** or **Anyone on the Same Network**.
2. **HomePod OS 27 User-Agent check** — HomePod OS 27 rejects AirPlay clients whose User-Agent doesn't look like AirPlay. `deploy.sh` sets `user_agent = "AirPlay/999.0.0"` in `/etc/owntone.conf`; OwnTone releases after 29.3 do this by default ([owntone-server#2042](https://github.com/owntone/owntone-server/issues/2042)).

You can check the second one directly:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'User-Agent: AirPlay/999.0.0' http://<homepod-ip>:7000/info   # 200 = OK
```

### Choppy or dropping audio

Usually weak Wi-Fi. Use Ethernet if you can; otherwise disable Wi-Fi power saving:

```bash
sudo nmcli con modify "<your Wi-Fi connection>" 802-11-wireless.powersave 2
```

### "HomePod" doesn't appear in Spotify

1. `homepod-spotify-status` — is `go-librespot` running?
2. `avahi-browse -tr _spotify-connect._tcp` should list it
3. Make sure your phone is on the same network/subnet as the Pi

### Audio Delay

A 2–3 second delay on play/pause/skip is normal due to AirPlay buffering.

## Files

```
homepod-spotify-connect/
├── README.md
├── LICENSE
├── deploy.sh          # Installs and configures everything
└── volume-bridge.py   # Two-way volume sync (installed as homepod-volume-bridge)
```

## Credits

- [go-librespot](https://github.com/devgianlu/go-librespot) - Spotify Connect daemon
- [OwnTone](https://github.com/owntone/owntone-server) - Media server with AirPlay support
- Original guide inspiration from [XDA Developers](https://www.xda-developers.com/homepod-spotify-connect-with-raspberry-pi/)

## License

MIT License - see [LICENSE](LICENSE) file.

## Disclaimer

This project is not affiliated with, endorsed by, or connected to Apple Inc. or Spotify AB. HomePod is a trademark of Apple Inc. Spotify is a trademark of Spotify AB.
