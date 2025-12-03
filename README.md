# HomePod Spotify Connect Bridge

Turn your Apple HomePod into a Spotify Connect device using a Raspberry Pi.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204%2F5-red.svg)
![OS](https://img.shields.io/badge/OS-Raspberry%20Pi%20OS%20Bookworm-green.svg)

## Overview

Apple HomePod doesn't natively support Spotify Connect, limiting it to AirPlay from Apple devices. This project bridges that gap by using a Raspberry Pi to:

1. **Receive** Spotify Connect streams (via SpoCon/librespot-java)
2. **Forward** audio to HomePod (via OwnTone/AirPlay)

The result: Your HomePod appears as a Spotify Connect device to any Spotify app on your network.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Spotify    │────▶│   SpoCon    │────▶│   OwnTone   │────▶│   HomePod   │
│    App      │     │  (Pi)       │     │  (AirPlay)  │     │             │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                         │                    │
                         └── Named Pipe ──────┘
```

## Requirements

### Hardware
- Raspberry Pi 4 or 5 (Pi 3B+ works but Pi 4+ recommended)
- MicroSD card (16GB minimum, 32GB recommended)
- Power supply for Pi
- Apple HomePod or HomePod Mini

### Software
- Raspberry Pi OS Bookworm (64-bit recommended)
- Spotify Premium account

### Network
- Pi and HomePod on the same local network
- Ports 3689 (OwnTone web UI) and 5355/udp (mDNS) accessible

## Quick Start

### 1. Prepare the Raspberry Pi

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash your SD card:

1. **Choose Device**: Raspberry Pi 4 or 5
2. **Choose OS**: Raspberry Pi OS (64-bit)
3. **Choose Storage**: Your SD card
4. **Configure** (click ⚙️ gear icon):
   - Hostname: `homepod-bridge`
   - Enable SSH with password
   - Set username/password
   - Configure WiFi
   - Set timezone/locale

### 2. First Boot

1. Insert SD card into Pi
2. Connect power
3. Wait 2-3 minutes for first boot to complete
4. Find your Pi: `ping homepod-bridge.local`

### 3. Deploy

```bash
# Clone this repository
git clone https://github.com/herbertkokholm/homepod-spotify-connect.git
cd homepod-spotify-connect

# Copy deploy script to Pi
scp deploy.sh pi@homepod-bridge.local:~

# SSH in and run
ssh pi@homepod-bridge.local
chmod +x deploy.sh
sudo ./deploy.sh
```

### 4. Configure OwnTone

1. Open `http://homepod-bridge.local:3689` in your browser
2. Go to **Settings** → **Remotes & Outputs**
3. Find your HomePod and **enable it** (click the speaker icon)

### 5. Play Music!

1. Open Spotify on any device
2. Click the **Connect to a device** icon (speaker icon)
3. Select **"HomePod"** from the list
4. Enjoy!

## Configuration

### Customize Device Name

Edit `/opt/spocon/config.toml` on the Pi:

```toml
deviceName = "Living Room HomePod"  # Change this
deviceType = "SPEAKER"
```

Then restart: `sudo systemctl restart spocon`

### Audio Quality

In the same config file:

```toml
[player]
preferredAudioQuality = "VORBIS_320"  # Options: VORBIS_96, VORBIS_160, VORBIS_320
```

### Restrict Access

By default, any Spotify Premium user on your network can use the HomePod. To restrict:

```toml
[auth]
strategy = "USER_PASS"
username = "your_spotify_username"
password = "your_spotify_password"
```

## Troubleshooting

### Check Service Status

```bash
# Quick status check
homepod-spotify-status

# Detailed service status
sudo systemctl status spocon
sudo systemctl status owntone

# View logs
sudo journalctl -u spocon -f
tail -f /var/log/owntone.log
```

### HomePod Not Appearing in OwnTone

1. Ensure HomePod and Pi are on the same network/VLAN
2. Check HomePod's AirPlay settings (allow "Everyone" or "Anyone on the Same Network")
3. Restart OwnTone: `sudo systemctl restart owntone`
4. Try accessing OwnTone at `http://<PI_IP>:3689` instead of hostname

### SpoCon Not Appearing in Spotify

1. Verify SpoCon is running: `sudo systemctl status spocon`
2. Check firewall: `sudo ufw allow 5355/udp`
3. Restart SpoCon: `sudo systemctl restart spocon`
4. Check logs: `sudo journalctl -u spocon -n 50`

### Audio Delay

A 2-3 second delay is normal due to AirPlay buffering. This cannot be eliminated without native Spotify support on HomePod.

### No Sound

1. Verify HomePod is enabled in OwnTone web UI
2. Check the named pipes exist: `ls -la /srv/music/`
3. Restart both services:
   ```bash
   sudo systemctl restart spocon
   sudo systemctl restart owntone
   ```

## File Structure

```
homepod-spotify-connect/
├── README.md           # This file
├── LICENSE             # MIT License
├── deploy.sh           # Main deployment script
├── prepare-sd.sh       # SD card preparation helper
└── config/
    └── spocon.toml     # Example SpoCon configuration
```

## How It Works

1. **SpoCon** implements the Spotify Connect protocol using [librespot-java](https://github.com/librespot-org/librespot-java)
2. SpoCon outputs raw PCM audio to a **named pipe** (`/srv/music/spotify`)
3. **OwnTone** reads from the pipe and streams via AirPlay
4. **HomePod** receives the AirPlay stream and plays audio

## Credits

- [SpoCon](https://github.com/spocon/spocon) - Spotify Connect daemon
- [librespot-java](https://github.com/librespot-org/librespot-java) - Spotify Connect library
- [OwnTone](https://github.com/owntone/owntone-server) - Media server with AirPlay support
- Original guide inspiration from [XDA Developers](https://www.xda-developers.com/homepod-spotify-connect-with-raspberry-pi/)

## License

MIT License - see [LICENSE](LICENSE) file.

## Contributing

Contributions welcome! Please open an issue or pull request.

## Disclaimer

This project is not affiliated with, endorsed by, or connected to Apple Inc. or Spotify AB. HomePod is a trademark of Apple Inc. Spotify is a trademark of Spotify AB.
