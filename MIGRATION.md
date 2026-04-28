# Migrating to a new machine

This stack is designed to bootstrap from `config.toml` on any machine. You won't
preserve runtime state (watch history, *arr import library, current torrents,
Jellyseerr request history, Immich photos+albums) — just the *configuration*
(subtitle providers, quality profiles, indexers, download client wiring,
Recyclarr profiles, custom Subdivx provider, homepage layout).

If you need to preserve any of that, see "Preserving runtime state" at the end.

## On the old machine

```bash
# Optional: stop the stack so config files aren't being written to.
make down
```

Copy these files to the new machine (they're gitignored, so `git clone` won't
move them):

- `config.toml`        — your single source of truth
- `.env`               — *optional*; `make configure` regenerates it from config.toml
- `homepage/.env`      — *optional*; same, regenerated
- `recyclarr/secrets.yml` — *optional*; regenerated

If you have a Newznab/usenet provider with a personal API key, those live in
`config.toml` already.

## On the new machine

### 1. Install prerequisites

```bash
sudo apt install -y docker.io docker-compose-plugin curl jq python3-pip
pip install --user yq
# yq must be the python wrapper (kislyuk/yq), not Mike Farah's Go version
# OR: sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
```

### 2. Clone the repo

```bash
git clone https://github.com/IAvecilla/media_server.git
cd media_server
```

### 3. Copy your config.toml from the old machine

```bash
scp old-machine:/path/to/media_server/config.toml ./config.toml
```

Edit it if your `data_location` path is different on the new host.

### 4. Bootstrap

```bash
make bootstrap            # without GPU
make bootstrap GPU=1      # with NVIDIA GPU (Jellyfin transcoding)
```

That single command:

- Verifies prereqs
- Copies `config.toml.example` → `config.toml` if missing (then exits so you can edit it)
- Starts the stack (`make up`)
- Runs `configure.sh`, which:
  - Generates `.env` from `config.toml` (random passwords for Immich DB / Prograrr)
  - Pre-seeds Sonarr Anime (port 8990) and Bazarr Anime (port 6868)
  - Waits for every service to come up
  - Reads and propagates fresh API keys
  - Configures qBittorrent (paths, seeding, categories)
  - Runs the Jellyfin first-time wizard (admin user, libraries: Movies/Shows/Anime/Music)
  - Configures Sonarr / Radarr / Sonarr Anime (root folders, download clients, Jellyfin notifications)
  - Configures Prowlarr (apps + FlareSolverr + indexers)
  - Configures Bazarr + Bazarr Anime (subtitle providers/languages, links to *arr)
  - Configures Jellyseerr (links to Jellyfin / Sonarr / Radarr / Sonarr Anime)
  - Configures SABnzbd (paths, categories, usenet servers) if usenet is enabled
  - Updates Homepage `.env` and `recyclarr/secrets.yml` with discovered keys

### 5. Manual finishing touches

These can't be auto-configured:

- **Immich** — open http://YOUR_IP:2283, create the admin account, then
  Account Settings → API Keys → create a key, paste into
  `homepage/.env` as `HOMEPAGE_VAR_IMMICH_API_KEY`, then `make restart`.
- **Bazarr Subdivx** — if you use Spanish subtitles, edit
  `bazarr/custom/subdivx.py` line 114 with your API key from
  https://subx-api.duckdns.org/docs and `docker compose restart bazarr`.

### 6. Sanity check

```bash
make status            # all services should be Up / healthy
docker exec gluetun wget -qO- https://ipinfo.io   # should show VPN IP, not yours
```

Open the Homepage at http://YOUR_IP:3010 — every widget should populate.

## Preserving runtime state (optional)

If you want to keep watched history / *arr libraries / qBittorrent torrents /
Immich photos, copy these directories from the old machine **with the stack
stopped on both ends**:

| Directory                 | What it preserves                          |
|---------------------------|--------------------------------------------|
| `jellyfin-config/data/`   | Users, watch state, library DB             |
| `sonarr/sonarr.db`        | Series library, history, queue             |
| `sonarr-anime/sonarr.db`  | Anime series library                       |
| `radarr/radarr.db`        | Movie library, history, queue              |
| `prowlarr/prowlarr.db`    | Indexers (configure.sh re-creates these)   |
| `bazarr/db/`              | Subtitle history                           |
| `qbittorrent/qBittorrent/BT_backup/` | Active torrents                 |
| `jellyseerr/`             | Request history                            |
| `immich/postgres/`        | Photo metadata, albums                     |
| `${data_location}/immich/`| Uploaded photos                            |

If you copy these, you'll need to stop the stack on the new machine before
running `make configure`, or the running services will conflict with the
restored DBs.

## Credentials to rotate (one-time, after any historical leak)

The repo's git history was rewritten on $(date +%Y-%m-%d) to remove leaked
secrets. If you're reading this immediately after that scrub, **rotate
everything that was ever committed**:

- VPN OpenVPN password (regenerate at provider portal)
- Bazarr subtitle-provider passwords (re-enter in Bazarr UI / config.toml)
- All *arr API keys → automatic: stop the *arr containers, delete their
  `config.xml`, restart, re-run `make configure`
- qBittorrent / Jellyfin / Jellyseerr passwords (set via `config.toml`)
- Immich Postgres password (set via `config.toml` → `immich.db_password`)

After rotation, every old key floating around in past clones / forks of the
public repo is dead.
