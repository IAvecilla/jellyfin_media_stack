# Self-Hosted Media Server Stack

A complete, automated media server setup using Docker. This stack includes media streaming, automatic downloads, subtitle management, and request handling - all routed through a VPN for privacy.

## Services Overview

| Service | Port | Description |
|---------|------|-------------|
| **Jellyfin** | 8700 | Media streaming server (like Plex/Netflix) |
| **Jellyseerr** | 5055 | Request management for movies/TV shows |
| **Homepage** | 3010 | Dashboard with service widgets and monitoring |
| **Prograrr** | 3000 | Dashboard to monitor downloads and requests |
| **Radarr** | 7878 | Movie collection manager |
| **Sonarr** | 8989 | TV show collection manager |
| **Sonarr Anime** | 8990 | Separate Sonarr instance tuned for anime |
| **Bazarr** | 6767 | Subtitle manager (for Sonarr + Radarr) |
| **Bazarr Anime** | 6868 | Subtitle manager (for Sonarr Anime) |
| **Recyclarr** | - | Auto-syncs quality profiles & custom formats from TRaSH Guides |
| **Prowlarr** | 9696 | Indexer manager for Radarr/Sonarr |
| **qBittorrent** | 8701 | Torrent client |
| **SABnzbd** | 8080 | Usenet client |
| **FlareSolverr** | 8191 | Cloudflare bypass proxy |
| **Gluetun** | - | VPN container (routes traffic through your VPN provider) |
| **Watchtower** | - | Automatic container image updates (daily at 4 AM) |
| **Immich** | 2283 | Photo & video library |

## Architecture

```
                                    ┌─────────────────┐
                                    │    Jellyfin     │ ← Media Streaming
                                    │   (port 8700)   │
                                    └────────▲────────┘
                                             │
┌──────────────┐   ┌──────────────┐ ┌────────┴────────┐
│  Jellyseerr  │ ← │   Prograrr   │ │   Media Files   │
│ (port 5055)  │   │ (port 3000)  │ │  /data/media    │
└──────┬───────┘   └──────┬───────┘ └────────▲────────┘
       │                  │ Dashboard        │
       ▼                  ▼                  │
┌──────────────────────────────────────────────────────────────┐
│                        GLUETUN (VPN)                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  Radarr  │  │  Sonarr  │  │ Prowlarr │  │ qBittorrent  │  │
│  │  (7878)  │  │  (8989)  │  │  (9696)  │  │    (8701)    │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────▲───────┘  │
│       │  ▲          │  ▲          │               │          │
│       │  │Recyclarr │  │          │               │          │
│       │  │(profiles)│  │          │               │          │
│       └──┴──────────┴──┴───┬──────┴───────────────┘          │
│                            │                                 │
│                     ┌──────┴──────┐  ┌─────────────┐         │
│                     │   Bazarr    │  │   SABnzbd   │         │
│                     │   (6767)    │  │   (8080)    │         │
│                     └─────────────┘  └─────────────┘         │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
                      VPN Provider
```

## Prerequisites

- Docker and Docker Compose installed
- A VPN subscription (ProtonVPN, Mullvad, NordVPN, etc.)
- Storage space for media files
- `jq`, `yq`, and `curl` (for `make configure` — auto-configuration)
- (Optional) NVIDIA GPU for hardware transcoding in Jellyfin

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/IAvecilla/media_server.git
cd media_server
```

### 2. Set up your media directory structure

Create the following folder structure in your `data_location` path:

```
/your/data/location/
├── media/
│   ├── movies/
│   ├── tv/
│   ├── anime/
│   └── music/
├── torrents/
│   ├── complete/
│   └── incomplete/
├── usenet/
│   ├── complete/
│   └── incomplete/
└── immich/         # Immich photos
```

### 3. Bootstrap

```bash
make bootstrap            # without GPU
make bootstrap GPU=1      # with NVIDIA GPU support (Jellyfin transcoding)
```

The first run creates `config.toml` from the example and exits. Edit it
(VPN credentials, passwords, indexers), then re-run `make bootstrap` and
the rest happens automatically: stack comes up, `configure.sh` reads
`config.toml`, all services get configured.

> Migrating from another machine? See [MIGRATION.md](./MIGRATION.md).

### What `make bootstrap` does

This reads `config.toml` and automatically:
- Generates `.env` with VPN, credentials, and a random `PROGRARR_API_KEY`
- Pre-seeds Sonarr Anime (port 8990) and Bazarr Anime (port 6868) configs
- Waits for all services to be healthy
- Reads API keys from service config files
- Configures qBittorrent (download paths, seeding limits, categories)
- Runs the Jellyfin setup wizard (admin user, media libraries, API key)
- Configures Sonarr/Radarr/Sonarr Anime (root folders, download clients, Jellyfin notifications)
- Configures Prowlarr (connects Sonarr/Radarr/Sonarr Anime, adds FlareSolverr, adds indexers)
- Configures Bazarr + Bazarr Anime (connects to Sonarr/Radarr)
- Configures Jellyseerr (connects to Jellyfin, Sonarr, Radarr, Sonarr Anime)
- Configures SABnzbd (download paths, categories, usenet providers) if usenet is enabled
- Updates Homepage and Recyclarr with discovered API keys and server IP

## config.toml

All settings live in a single `config.toml` file. See `config.toml.example` for the full reference.

| Section | What it configures |
|---------|-------------------|
| `[jellyfin]` | Admin username and password |
| `[qbittorrent]` | Web UI credentials |
| `[downloads]` | Complete/incomplete paths, seeding ratio and time |
| `[subtitles]` | Languages and providers for Bazarr |
| `[quality]` | Sonarr/Radarr quality profile names (managed by Recyclarr) |
| `[[indexers]]` | Prowlarr indexers — name, definition, FlareSolverr flag, anime flag |
| `[vpn]` | Provider, type, credentials, server countries |
| `[[usenet_providers]]` | Usenet server connections for SABnzbd |
| `[immich]` | Immich photo library (upload location, Postgres credentials) |

## VPN Configuration

This setup uses **[Gluetun](https://github.com/qdm12/gluetun)** to route all *arr apps, qBittorrent, SABnzbd, and FlareSolverr through a VPN.

### Supported VPN Providers

| Provider | VPN Type | Notes |
|----------|----------|-------|
| **ProtonVPN** | openvpn | Supports port forwarding |
| **Mullvad** | wireguard | Supports port forwarding |
| **NordVPN** | openvpn | Use service credentials, not account login |
| **Surfshark** | openvpn | - |
| **ExpressVPN** | openvpn | - |
| **Private Internet Access** | openvpn | Supports port forwarding |
| **Custom WireGuard** | wireguard | Bring your own config |

Full list: [Gluetun Wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)

Configure your VPN in `config.toml` under the `[vpn]` section:

```toml
[vpn]
enable = true
provider = "protonvpn"
type = "openvpn"
server_countries = "Argentina"
openvpn_user = "your_username"
openvpn_password = "your_password"
```

## Custom Configurations

### Subdivx Provider Fix (Spanish Subtitles)

The default Subdivx provider in Bazarr is broken due to Cloudflare protection. This repo includes a custom provider that uses the [Subx API](https://subx-api.duckdns.org/docs) as a workaround.

**Setup:**

1. Get an API key from https://subx-api.duckdns.org/docs
2. Edit `bazarr/custom/subdivx.py` and replace the API key on line 114
3. Restart Bazarr: `docker compose restart bazarr`
4. Enable the Subdivx provider in Bazarr settings

## Folder Structure

```
media_server/
├── Makefile                  # Quick commands (make up, make configure, etc.)
├── docker-compose.yml        # Main configuration
├── docker-compose.gpu.yml    # GPU override (NVIDIA support for Jellyfin)
├── config.toml.example       # Configuration template — copy to config.toml
├── configure.sh              # Auto-configures all services from config.toml
├── .env.example              # Legacy env template (configure.sh generates .env)
├── bazarr/
│   ├── config/               # Bazarr configuration
│   └── custom/
│       └── subdivx.py        # Custom Subdivx subtitle provider
├── homepage/
│   ├── services.yaml         # Service widget definitions
│   ├── settings.yaml         # Dashboard visual settings
│   ├── docker.yaml           # Docker socket config
│   ├── widgets.yaml          # System monitoring widgets
│   └── bookmarks.yaml        # Bookmarks
├── jellyfin-config/          # Jellyfin configuration
├── jellyfin-cache/           # Jellyfin cache
├── jellyseerr/               # Jellyseerr configuration
├── recyclarr/
│   ├── recyclarr.yml         # TRaSH Guides quality profile sync config
│   └── secrets.yml           # API keys (auto-populated by configure.sh)
├── radarr/                   # Radarr configuration
├── sonarr/                   # Sonarr configuration
├── sonarr-anime/             # Sonarr Anime configuration (port 8990)
├── bazarr-anime/             # Bazarr Anime configuration (port 6868)
├── prowlarr/                 # Prowlarr configuration
├── lidarr/                   # Lidarr configuration
├── qbittorrent/              # qBittorrent configuration
├── sabnzbd/                  # SABnzbd configuration
├── gluetun/                  # VPN configuration
└── immich/postgres/          # Immich Postgres data
```

## Makefile Commands

Run `make help` to see all available commands.

```bash
make bootstrap              # First-run install: copy config.toml, up, configure
make up                     # Start all services (no GPU)
make up GPU=1               # Start with NVIDIA GPU support
make down                   # Stop and remove all services
make restart                # Restart all services
make logs                   # Follow all logs
make logs SERVICE=jellyfin  # Follow logs for a specific service
make status                 # Show status of all services
make pull                   # Pull latest images
make configure              # Auto-configure services from config.toml
make setup                  # Create .env from .env.example (legacy)
make setup-gpu              # Install NVIDIA Container Toolkit
```

### Additional useful commands

```bash
# Check VPN IP
docker exec gluetun wget -qO- https://ipinfo.io
```

## Troubleshooting

### Services can't connect to each other

All services behind VPN communicate via `localhost` (they share the gluetun network namespace):
- Radarr from Prowlarr: `http://localhost:7878`
- Sonarr from Prowlarr: `http://localhost:8989`

Services outside the VPN reach them via the `gluetun` container:
- Radarr from Jellyseerr: `http://gluetun:7878`
- Sonarr from Jellyseerr: `http://gluetun:8989`

### VPN not connecting

```bash
docker compose logs gluetun
```

Check your VPN credentials in `config.toml` and re-run `make configure`.

### qBittorrent password

On first run, qBittorrent generates a random password. `make configure` sets the password from `config.toml` automatically. If you need the initial password:

```bash
docker compose logs qbittorrent | grep password
```

### Port forwarding for better torrent speeds

Gluetun supports port forwarding with ProtonVPN. The forwarded port is automatically configured. Check:

```bash
docker exec gluetun cat /tmp/gluetun/forwarded_port
```

## Hardware Transcoding (NVIDIA GPU)

GPU support is optional and enabled by passing `GPU=1` to any `make` command. This uses `docker-compose.gpu.yml` as an override to add NVIDIA GPU access to Jellyfin.

```bash
make up GPU=1
```

Requirements:

1. NVIDIA drivers installed on host
2. Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html):
   ```bash
   make setup-gpu
   ```
3. Verify with: `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`

## Security Notes

- **Never commit `config.toml` or `.env`** — they contain your VPN and API credentials
- Change default passwords for all services
- Consider using a reverse proxy (Traefik, Caddy) with HTTPS for external access
- The VPN ensures your IP is hidden when downloading

## License

MIT
