#!/usr/bin/env bash
# =============================================================================
# configure.sh — Read config.toml and configure all running media server services
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.toml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# =============================================================================
# Pre-flight checks
# =============================================================================
if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config.toml not found. Copy config.toml.example to config.toml and edit it."
    exit 1
fi

for cmd in curl jq yq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        err "${cmd} is required but not installed."
        exit 1
    fi
done

# =============================================================================
# Config parsing — convert TOML to JSON once, query with jq
# =============================================================================
CONFIG_JSON=$(yq -p toml -o json '.' "$CONFIG_FILE")
cfg() { echo "$CONFIG_JSON" | jq -r "$1"; }

# =============================================================================
# Read config values
# =============================================================================
TIMEZONE=$(cfg '.timezone // "America/Argentina/Buenos_Aires"')
DATA_LOCATION=$(cfg '.data_location // "/path/to/your/media"')

JELLYFIN_USER=$(cfg '.jellyfin.username // "admin"')
JELLYFIN_PASS=$(cfg '.jellyfin.password // ""')

QBIT_USER=$(cfg '.qbittorrent.username // "admin"')
QBIT_PASS=$(cfg '.qbittorrent.password // ""')

DL_COMPLETE=$(cfg '.downloads.complete_path // "/data/torrents/complete"')
DL_INCOMPLETE=$(cfg '.downloads.incomplete_path // "/data/torrents/incomplete"')
SEED_RATIO=$(cfg '.downloads.seeding_ratio // 1.0')
SEED_TIME=$(cfg '.downloads.seeding_time_minutes // 1440')

SUBTITLE_LANGS=$(cfg '[.subtitles.languages[]?] | join(",")')
SUBTITLE_PROVIDERS=$(cfg '[.subtitles.providers[]?] | join(",")')

SONARR_PROFILE=$(cfg '.quality.sonarr_profile // "WEB-1080p"')
SONARR_ANIME_PROFILE=$(cfg '.quality.sonarr_anime_profile // "Anime"')
RADARR_PROFILE=$(cfg '.quality.radarr_profile // "HD Bluray + WEB"')

VPN_ENABLE=$(cfg '.vpn.enable // true')
VPN_PROVIDER=$(cfg '.vpn.provider // "protonvpn"')
VPN_TYPE=$(cfg '.vpn.type // "openvpn"')
VPN_COUNTRIES=$(cfg '.vpn.server_countries // "Argentina"')
VPN_OVPN_USER=$(cfg '.vpn.openvpn_user // ""')
VPN_OVPN_PASS=$(cfg '.vpn.openvpn_password // ""')
VPN_WG_KEY=$(cfg '.vpn.wireguard_private_key // ""')
VPN_WG_ADDR=$(cfg '.vpn.wireguard_addresses // ""')

IMMICH_VERSION=$(cfg '.immich.version // "release"')
IMMICH_UPLOAD_LOCATION=$(cfg '.immich.upload_location // ""')
IMMICH_DB_USER=$(cfg '.immich.db_username // "postgres"')
IMMICH_DB_NAME=$(cfg '.immich.db_database_name // "immich"')
IMMICH_DB_PASS=$(cfg '.immich.db_password // ""')

# Service URLs (all behind gluetun, exposed on host ports)
JELLYFIN_URL="http://localhost:8700"
QBIT_URL="http://localhost:8701"
SONARR_URL="http://localhost:8989"
SONARR_ANIME_URL="http://localhost:8990"
RADARR_URL="http://localhost:7878"
PROWLARR_URL="http://localhost:9696"
BAZARR_URL="http://localhost:6767"
BAZARR_ANIME_URL="http://localhost:6868"
SEERR_URL="http://localhost:5055"

# API keys — populated later
SONARR_API_KEY=""
SONARR_ANIME_API_KEY=""
RADARR_API_KEY=""
PROWLARR_API_KEY=""
BAZARR_API_KEY=""
BAZARR_ANIME_API_KEY=""
JELLYFIN_API_KEY=""
JELLYFIN_TOKEN=""
JELLYSEERR_API_KEY=""
SABNZBD_API_KEY=""

# =============================================================================
# Helper: HTTP request with retries
# =============================================================================
api() {
    local method="$1"; shift
    local url="$1"; shift
    curl -sf -X "$method" "$url" -H "Content-Type: application/json" "$@" 2>/dev/null
}

# =============================================================================
# Pre-seed Sonarr Anime config (port 8990 instead of default 8989)
# =============================================================================
preseed_sonarr_anime() {
    local config_dir="${SCRIPT_DIR}/sonarr-anime"
    local config_file="${config_dir}/config.xml"

    if [[ -f "$config_file" ]]; then
        info "Sonarr Anime config.xml already exists — skipping preseed."
        return
    fi

    log "Pre-seeding Sonarr Anime config (port 8990)..."
    mkdir -p "$config_dir"
    cat > "$config_file" <<'EOF'
<Config>
  <BindAddress>*</BindAddress>
  <Port>8990</Port>
  <SslPort>6990</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>True</LaunchBrowser>
  <AuthenticationMethod>None</AuthenticationMethod>
  <Branch>main</Branch>
  <LogLevel>info</LogLevel>
  <InstanceName>SonarrAnime</InstanceName>
</Config>
EOF
    log "Sonarr Anime config.xml created with port 8990."
}

# =============================================================================
# Pre-seed Bazarr Anime config (port 6868 instead of default 6767)
# =============================================================================
preseed_bazarr_anime() {
    local config_dir="${SCRIPT_DIR}/bazarr-anime/config"
    local config_file="${config_dir}/config.yaml"

    if [[ -f "$config_file" ]]; then
        info "Bazarr Anime config.yaml already exists — skipping preseed."
        return
    fi

    log "Pre-seeding Bazarr Anime config (port 6868)..."
    mkdir -p "$config_dir"
    cat > "$config_file" <<'EOF'
general:
  port: 6868
EOF
    log "Bazarr Anime config.yaml created with port 6868."
}

# =============================================================================
# Step 1: Generate .env
# =============================================================================
generate_env() {
    log "Generating .env file..."

    # Preserve existing PROGRARR_API_KEY if set, otherwise generate a random one.
    local prograrr_key=""
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        prograrr_key=$(grep -oP '^PROGRARR_API_KEY=\K.*' "${SCRIPT_DIR}/.env" || true)
    fi
    if [[ -z "$prograrr_key" ]]; then
        prograrr_key=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
        log "Generated new PROGRARR_API_KEY."
    fi

    # Immich DB password: preserve existing if set, otherwise generate.
    local immich_db_pass="${IMMICH_DB_PASS}"
    if [[ -z "$immich_db_pass" ]] && [[ -f "${SCRIPT_DIR}/.env" ]]; then
        immich_db_pass=$(grep -oP '^IMMICH_DB_PASSWORD=\K.*' "${SCRIPT_DIR}/.env" || true)
    fi
    if [[ -z "$immich_db_pass" ]]; then
        immich_db_pass=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
        log "Generated new IMMICH_DB_PASSWORD."
    fi

    # Immich upload location defaults to ${DATA_LOCATION}/immich
    local immich_upload="${IMMICH_UPLOAD_LOCATION}"
    [[ -z "$immich_upload" ]] && immich_upload="${DATA_LOCATION%/}/immich"

    cat > "${SCRIPT_DIR}/.env" <<EOF
# Auto-generated by configure.sh — do not edit manually
# Re-run: make configure

TIMEZONE=${TIMEZONE}
DATA_LOCATION=${DATA_LOCATION}

# VPN
VPN_SERVICE_PROVIDER=${VPN_PROVIDER}
VPN_TYPE=${VPN_TYPE}
SERVER_COUNTRIES=${VPN_COUNTRIES}
OPENVPN_USER=${VPN_OVPN_USER}
OPENVPN_PASSWORD=${VPN_OVPN_PASS}
WIREGUARD_PRIVATE_KEY=${VPN_WG_KEY}
WIREGUARD_ADDRESSES=${VPN_WG_ADDR}

# qBittorrent
QBITTORRENT_USERNAME=${QBIT_USER}
QBITTORRENT_PASSWORD=${QBIT_PASS}

# Prograrr — acts as a bearer token for the exposed service
PROGRARR_API_KEY=${prograrr_key}

# Immich
IMMICH_VERSION=${IMMICH_VERSION}
IMMICH_UPLOAD_LOCATION=${immich_upload}
IMMICH_DB_USERNAME=${IMMICH_DB_USER}
IMMICH_DB_DATABASE_NAME=${IMMICH_DB_NAME}
IMMICH_DB_PASSWORD=${immich_db_pass}

# API Keys (populated after services start)
SONARR_API_KEY=
RADARR_API_KEY=
JELLYSEERR_API_KEY=
EOF

    log ".env generated."
}

# =============================================================================
# Step 2: Wait for services to be healthy
# =============================================================================
wait_for_service() {
    local name="$1"
    local url="$2"
    local max_attempts="${3:-30}"
    local attempt=0

    info "Waiting for ${name}..."
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf -o /dev/null "$url" 2>/dev/null; then
            log "${name} is ready."
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    warn "${name} did not become ready after $((max_attempts * 2))s — skipping."
    return 1
}

wait_for_services() {
    log "Waiting for services to become healthy..."
    wait_for_service "qBittorrent" "$QBIT_URL" 60 || true
    wait_for_service "Sonarr" "$SONARR_URL" 60 || true
    wait_for_service "Sonarr Anime" "$SONARR_ANIME_URL" 60 || true
    wait_for_service "Radarr" "$RADARR_URL" 60 || true
    wait_for_service "Prowlarr" "$PROWLARR_URL" 60 || true
    wait_for_service "Bazarr" "$BAZARR_URL" 60 || true
    wait_for_service "Bazarr Anime" "$BAZARR_ANIME_URL" 60 || true
    wait_for_service "Jellyfin" "$JELLYFIN_URL/health" 60 || true
    wait_for_service "Seerr" "$SEERR_URL" 60 || true
}

# =============================================================================
# Step 3: Read API keys from config.xml / ini files
# =============================================================================
read_api_key_xml() {
    local config_file="${SCRIPT_DIR}/$1/config.xml"
    [[ -f "$config_file" ]] || { echo ""; return; }
    grep -oP '<ApiKey>\K[^<]+' "$config_file" 2>/dev/null || echo ""
}

read_api_keys() {
    log "Reading API keys from service configs..."

    SONARR_API_KEY=$(read_api_key_xml "sonarr")
    SONARR_ANIME_API_KEY=$(read_api_key_xml "sonarr-anime")
    RADARR_API_KEY=$(read_api_key_xml "radarr")
    PROWLARR_API_KEY=$(read_api_key_xml "prowlarr")

    # Bazarr stores its key in config.yaml or config.ini
    if [[ -f "${SCRIPT_DIR}/bazarr/config/config.yaml" ]]; then
        BAZARR_API_KEY=$(yq '.auth.apikey' "${SCRIPT_DIR}/bazarr/config/config.yaml" 2>/dev/null || true)
    elif [[ -f "${SCRIPT_DIR}/bazarr/config/config.ini" ]]; then
        BAZARR_API_KEY=$(grep -oP 'apikey *= *\K.*' "${SCRIPT_DIR}/bazarr/config/config.ini" 2>/dev/null || true)
    fi

    # Bazarr Anime API key
    if [[ -f "${SCRIPT_DIR}/bazarr-anime/config/config.yaml" ]]; then
        BAZARR_ANIME_API_KEY=$(yq '.auth.apikey' "${SCRIPT_DIR}/bazarr-anime/config/config.yaml" 2>/dev/null || true)
    fi

    # SABnzbd API key
    if [[ -f "${SCRIPT_DIR}/sabnzbd/sabnzbd.ini" ]]; then
        SABNZBD_API_KEY=$(grep -oP 'api_key *= *\K.*' "${SCRIPT_DIR}/sabnzbd/sabnzbd.ini" 2>/dev/null || true)
    fi

    [[ -n "$SONARR_API_KEY" ]] && log "Sonarr:   ${SONARR_API_KEY:0:8}..." || warn "Sonarr API key not found."
    [[ -n "$SONARR_ANIME_API_KEY" ]] && log "Sonarr Anime: ${SONARR_ANIME_API_KEY:0:8}..." || warn "Sonarr Anime API key not found."
    [[ -n "$RADARR_API_KEY" ]] && log "Radarr:   ${RADARR_API_KEY:0:8}..." || warn "Radarr API key not found."
    [[ -n "$PROWLARR_API_KEY" ]] && log "Prowlarr: ${PROWLARR_API_KEY:0:8}..." || warn "Prowlarr API key not found."

    # Update .env with discovered keys
    sed -i.bak "s|^SONARR_API_KEY=.*|SONARR_API_KEY=${SONARR_API_KEY}|" "${SCRIPT_DIR}/.env"
    sed -i.bak "s|^RADARR_API_KEY=.*|RADARR_API_KEY=${RADARR_API_KEY}|" "${SCRIPT_DIR}/.env"
    rm -f "${SCRIPT_DIR}/.env.bak"
}

# =============================================================================
# Step 4: Configure qBittorrent
# =============================================================================
configure_qbittorrent() {
    log "Configuring qBittorrent..."

    # Try logging in with configured password, then fall back to default
    local sid=""
    for try_pass in "$QBIT_PASS" "adminadmin"; do
        sid=$(curl -sf -c - "$QBIT_URL/api/v2/auth/login" \
            -d "username=${QBIT_USER}&password=${try_pass}" 2>/dev/null \
            | sed -n 's/.*SID[[:space:]]*//p' || true)
        [[ -n "$sid" ]] && break
    done

    if [[ -z "$sid" ]]; then
        warn "Could not login to qBittorrent — skipping."
        return
    fi

    local cookie="SID=$sid"

    # Set preferences
    curl -sf -o /dev/null -b "$cookie" "$QBIT_URL/api/v2/app/setPreferences" \
        --data-urlencode "json={
            \"web_ui_username\": \"${QBIT_USER}\",
            \"web_ui_password\": \"${QBIT_PASS}\",
            \"save_path\": \"${DL_COMPLETE}\",
            \"temp_path_enabled\": true,
            \"temp_path\": \"${DL_INCOMPLETE}\",
            \"max_ratio\": ${SEED_RATIO},
            \"max_seeding_time\": ${SEED_TIME},
            \"max_ratio_act\": 1,
            \"bypass_auth_subnet_whitelist_enabled\": true,
            \"bypass_auth_subnet_whitelist\": \"172.16.0.0/12,192.168.0.0/16\"
        }" || warn "Failed to set qBittorrent preferences."

    # Create categories for each *arr service
    for category in sonarr sonarr-anime radarr lidarr; do
        curl -sf -o /dev/null -b "$cookie" "$QBIT_URL/api/v2/torrents/createCategory" \
            -d "category=${category}&savePath=${DL_COMPLETE}/${category}" 2>/dev/null || true
    done

    log "qBittorrent configured (credentials, paths, seeding limits, categories)."
}

# =============================================================================
# Step 5: Configure Jellyfin
# =============================================================================
configure_jellyfin() {
    log "Configuring Jellyfin..."

    local jf_header="X-Emby-Authorization: MediaBrowser Client=\"configure.sh\", Device=\"server\", DeviceId=\"configure-script\", Version=\"1.0\""

    # Check if startup wizard is available
    local startup
    startup=$(curl -sf "$JELLYFIN_URL/Startup/Configuration" 2>/dev/null || true)
    if [[ -z "$startup" ]]; then
        info "Jellyfin wizard already completed — skipping initial setup."

        # Still try to authenticate to get API key
        local auth_result
        auth_result=$(api POST "$JELLYFIN_URL/Users/AuthenticateByName" \
            -H "$jf_header" \
            -d "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASS}\"}" || true)

        if [[ -n "$auth_result" ]]; then
            JELLYFIN_TOKEN=$(echo "$auth_result" | jq -r '.AccessToken // empty')
            if [[ -n "$JELLYFIN_TOKEN" ]]; then
                local keys_json
                keys_json=$(curl -sf "$JELLYFIN_URL/Auth/Keys" -H "X-Emby-Token: $JELLYFIN_TOKEN" || true)
                if [[ -n "$keys_json" ]]; then
                    JELLYFIN_API_KEY=$(echo "$keys_json" | jq -r '.Items[-1].AccessToken // empty')
                fi

                # Ensure all libraries exist (may have been added after initial wizard)
                local existing_libs
                existing_libs=$(curl -sf "$JELLYFIN_URL/Library/VirtualFolders" -H "X-Emby-Token: $JELLYFIN_TOKEN" || echo "[]")

                local -A LIBRARIES=( ["Movies"]="movies:/data/media/movies" ["Shows"]="tvshows:/data/media/tv" ["Anime"]="tvshows:/data/media/anime" ["Music"]="music:/data/media/music" )
                for lib_name in "${!LIBRARIES[@]}"; do
                    if ! echo "$existing_libs" | jq -e --arg n "$lib_name" '.[] | select(.Name == $n)' &>/dev/null; then
                        IFS=: read -r lib_type lib_path <<< "${LIBRARIES[$lib_name]}"
                        local encoded
                        encoded=$(printf '%s' "$lib_path" | jq -sRr @uri)
                        api POST "$JELLYFIN_URL/Library/VirtualFolders?name=${lib_name}&collectionType=${lib_type}&refreshLibrary=false&paths=${encoded}" \
                            -H "X-Emby-Token: $JELLYFIN_TOKEN" \
                            -d '{"LibraryOptions":{}}' || true
                        log "Jellyfin: added missing library '${lib_name}' → ${lib_path}"
                    fi
                done
            fi
        fi
        return
    fi

    # Step 1: Initial configuration
    api POST "$JELLYFIN_URL/Startup/Configuration" -H "$jf_header" \
        -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' || true

    # Step 2: Create admin user
    api POST "$JELLYFIN_URL/Startup/User" -H "$jf_header" \
        -d "{\"Name\":\"${JELLYFIN_USER}\",\"Password\":\"${JELLYFIN_PASS}\"}" || true

    # Step 3: Add libraries
    local -A LIBRARIES=( ["Movies"]="movies:/data/media/movies" ["Shows"]="tvshows:/data/media/tv" ["Anime"]="tvshows:/data/media/anime" ["Music"]="music:/data/media/music" )
    for lib_name in "${!LIBRARIES[@]}"; do
        IFS=: read -r lib_type lib_path <<< "${LIBRARIES[$lib_name]}"
        local encoded
        encoded=$(printf '%s' "$lib_name" | jq -sRr @uri)

        api POST "$JELLYFIN_URL/Library/VirtualFolders?name=${encoded}&collectionType=${lib_type}&refreshLibrary=false" \
            -H "$jf_header" \
            -d '{"LibraryOptions":{}}' || true

        api POST "$JELLYFIN_URL/Library/VirtualFolders/Paths?refreshLibrary=true" \
            -H "$jf_header" \
            -d "{\"Name\":\"${lib_name}\",\"PathInfo\":{\"Path\":\"${lib_path}\"}}" || true
    done

    # Step 4: Complete wizard
    api POST "$JELLYFIN_URL/Startup/Complete" || true

    # Step 5: Authenticate and create API key
    local auth_result
    auth_result=$(api POST "$JELLYFIN_URL/Users/AuthenticateByName" \
        -H "$jf_header" \
        -d "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASS}\"}" || true)

    if [[ -n "$auth_result" ]]; then
        JELLYFIN_TOKEN=$(echo "$auth_result" | jq -r '.AccessToken // empty')
        if [[ -n "$JELLYFIN_TOKEN" ]]; then
            api POST "$JELLYFIN_URL/Auth/Keys?app=MediaServer" -H "X-Emby-Token: $JELLYFIN_TOKEN" || true

            local keys_json
            keys_json=$(curl -sf "$JELLYFIN_URL/Auth/Keys" -H "X-Emby-Token: $JELLYFIN_TOKEN" || true)
            if [[ -n "$keys_json" ]]; then
                JELLYFIN_API_KEY=$(echo "$keys_json" | jq -r '.Items[-1].AccessToken // empty')
                [[ -n "$JELLYFIN_API_KEY" ]] && log "Jellyfin API key: ${JELLYFIN_API_KEY:0:8}..."
            fi
        fi
    fi

    log "Jellyfin configured (admin user, libraries, API key)."
}

# =============================================================================
# Step 6: Configure Sonarr & Radarr
# =============================================================================
configure_arr() {
    local name="$1" url="$2" key="$3" root_folder="$4"
    local H="X-Api-Key: $key"

    if [[ -z "$key" ]]; then
        warn "No API key for ${name} — skipping."
        return
    fi

    log "Configuring ${name}..."

    # Root folder — add if missing
    local existing_roots
    existing_roots=$(api GET "$url/api/v3/rootfolder" -H "$H" || echo "[]")
    if ! echo "$existing_roots" | jq -e ".[] | select(.path == \"$root_folder\")" &>/dev/null; then
        api POST "$url/api/v3/rootfolder" -H "$H" -d "{\"path\":\"$root_folder\"}" >/dev/null || warn "Failed to add root folder."
        log "${name}: root folder ${root_folder}"
    fi

    # Download clients — add qBittorrent if missing
    local existing_clients
    existing_clients=$(api GET "$url/api/v3/downloadclient" -H "$H" || echo "[]")

    local category
    category=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    if ! echo "$existing_clients" | jq -e '.[] | select(.implementation == "QBittorrent")' &>/dev/null; then
        api POST "$url/api/v3/downloadclient" -H "$H" -d '{
            "name": "qBittorrent",
            "implementation": "QBittorrent",
            "configContract": "QBittorrentSettings",
            "enable": true,
            "protocol": "torrent",
            "priority": 1,
            "fields": [
                {"name": "host", "value": "localhost"},
                {"name": "port", "value": 8701},
                {"name": "username", "value": "'"$QBIT_USER"'"},
                {"name": "password", "value": "'"$QBIT_PASS"'"},
                {"name": "tvCategory", "value": "'"$category"'"},
                {"name": "movieCategory", "value": "'"$category"'"},
                {"name": "musicCategory", "value": "'"$category"'"}
            ]
        }' >/dev/null || warn "Failed to add qBittorrent to ${name}."
        log "${name}: qBittorrent download client added."
    else
        info "${name}: qBittorrent already configured."
    fi

    # Add SABnzbd if usenet providers are configured
    local usenet_count
    usenet_count=$(cfg '[.usenet_providers? // [] | length] | .[0]')
    if [[ "$usenet_count" -gt 0 ]] && [[ -n "$SABNZBD_API_KEY" ]]; then
        if ! echo "$existing_clients" | jq -e '.[] | select(.implementation == "Sabnzbd")' &>/dev/null; then
            api POST "$url/api/v3/downloadclient" -H "$H" -d '{
                "name": "SABnzbd",
                "implementation": "Sabnzbd",
                "configContract": "SabnzbdSettings",
                "enable": true,
                "protocol": "usenet",
                "priority": 1,
                "fields": [
                    {"name": "host", "value": "localhost"},
                    {"name": "port", "value": 8080},
                    {"name": "apiKey", "value": "'"$SABNZBD_API_KEY"'"},
                    {"name": "tvCategory", "value": "'"$category"'"},
                    {"name": "movieCategory", "value": "'"$category"'"}
                ]
            }' >/dev/null || warn "Failed to add SABnzbd to ${name}."
            log "${name}: SABnzbd download client added."
        fi
    fi

    # Add Jellyfin notification if we have an API key
    if [[ -n "$JELLYFIN_API_KEY" ]]; then
        local existing_notifs
        existing_notifs=$(api GET "$url/api/v3/notification" -H "$H" || echo "[]")
        if ! echo "$existing_notifs" | jq -e '.[] | select(.implementation == "MediaBrowser")' &>/dev/null; then
            api POST "$url/api/v3/notification" -H "$H" -d '{
                "name": "Jellyfin",
                "implementation": "MediaBrowser",
                "configContract": "MediaBrowserSettings",
                "enable": true,
                "onDownload": true,
                "onUpgrade": true,
                "onRename": true,
                "fields": [
                    {"name": "host", "value": "jellyfin"},
                    {"name": "port", "value": 8096},
                    {"name": "useSsl", "value": false},
                    {"name": "apiKey", "value": "'"$JELLYFIN_API_KEY"'"},
                    {"name": "updateLibrary", "value": true}
                ]
            }' >/dev/null || true
            log "${name}: Jellyfin library update notification added."
        fi
    fi

    log "${name} configured."
}

configure_sonarr_radarr() {
    configure_arr "Sonarr" "$SONARR_URL" "$SONARR_API_KEY" "/data/media/tv"
    configure_arr "Sonarr-Anime" "$SONARR_ANIME_URL" "$SONARR_ANIME_API_KEY" "/data/media/anime"
    configure_arr "Radarr" "$RADARR_URL" "$RADARR_API_KEY" "/data/media/movies"
}

# =============================================================================
# Step 7: Configure Seerr (Jellyseerr)
# =============================================================================
configure_seerr() {
    log "Configuring Seerr (Jellyseerr)..."

    # Check if Seerr is initialized (wizard must be completed manually first)
    local public_settings
    public_settings=$(curl -sf "$SEERR_URL/api/v1/settings/public" 2>/dev/null || true)
    if [[ -z "$public_settings" ]]; then
        warn "Seerr not reachable — skipping."
        return
    fi

    local initialized
    initialized=$(echo "$public_settings" | jq -r '.initialized // false')
    if [[ "$initialized" != "true" ]]; then
        warn "Seerr wizard not completed — please visit $SEERR_URL and complete setup first."
        return
    fi

    # Read API key from settings.json
    local settings_file="${SCRIPT_DIR}/jellyseerr/settings.json"
    if [[ ! -f "$settings_file" ]]; then
        warn "Seerr settings.json not found — skipping."
        return
    fi

    JELLYSEERR_API_KEY=$(jq -r '.main.apiKey // empty' "$settings_file" 2>/dev/null || true)
    if [[ -z "$JELLYSEERR_API_KEY" ]]; then
        warn "Seerr API key not found in settings.json — skipping."
        return
    fi

    log "Seerr API key: ${JELLYSEERR_API_KEY:0:8}..."

    local SH="X-Api-Key: $JELLYSEERR_API_KEY"
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    # --- Sonarr servers ---
    local existing_sonarr
    existing_sonarr=$(api GET "$SEERR_URL/api/v1/settings/sonarr" -H "$SH" || echo "[]")

    # Add main Sonarr (port 8989)
    if [[ -n "$SONARR_API_KEY" ]] && ! echo "$existing_sonarr" | jq -e '.[] | select(.port == 8989)' &>/dev/null; then
        local sonarr_profiles sonarr_profile_id sonarr_profile_name
        sonarr_profiles=$(api GET "$SONARR_URL/api/v3/qualityprofile" -H "X-Api-Key: $SONARR_API_KEY" || echo "[]")
        sonarr_profile_id=$(echo "$sonarr_profiles" | jq -r --arg name "$SONARR_PROFILE" '[.[] | select(.name == $name)] | .[0].id // empty')
        sonarr_profile_name="$SONARR_PROFILE"
        if [[ -z "$sonarr_profile_id" ]]; then
            sonarr_profile_id=$(echo "$sonarr_profiles" | jq -r '.[0].id // empty')
            sonarr_profile_name=$(echo "$sonarr_profiles" | jq -r '.[0].name // empty')
        fi

        local sonarr_roots sonarr_root
        sonarr_roots=$(api GET "$SONARR_URL/api/v3/rootfolder" -H "X-Api-Key: $SONARR_API_KEY" || echo "[]")
        sonarr_root=$(echo "$sonarr_roots" | jq -r '.[0].path // "/data/media/tv"')

        if [[ -n "$sonarr_profile_id" ]]; then
            api POST "$SEERR_URL/api/v1/settings/sonarr" -H "$SH" -d '{
                "name": "Sonarr",
                "hostname": "gluetun",
                "port": 8989,
                "apiKey": "'"$SONARR_API_KEY"'",
                "useSsl": false,
                "activeProfileId": '"$sonarr_profile_id"',
                "activeProfileName": "'"$sonarr_profile_name"'",
                "activeDirectory": "'"$sonarr_root"'",
                "isDefault": true,
                "is4k": false,
                "enableSeasonFolders": true,
                "externalUrl": "http://'"$server_ip"':8989"
            }' >/dev/null || warn "Failed to add Sonarr to Seerr."
            log "Seerr: Sonarr (main) added."
        else
            warn "Seerr: Could not determine Sonarr quality profile — skipping."
        fi
    else
        [[ -n "$SONARR_API_KEY" ]] && info "Seerr: Sonarr (main) already configured."
    fi

    # Add anime Sonarr (port 8990)
    if [[ -n "$SONARR_ANIME_API_KEY" ]] && ! echo "$existing_sonarr" | jq -e '.[] | select(.port == 8990)' &>/dev/null; then
        local anime_profiles anime_profile_id anime_profile_name
        anime_profiles=$(api GET "$SONARR_ANIME_URL/api/v3/qualityprofile" -H "X-Api-Key: $SONARR_ANIME_API_KEY" || echo "[]")
        anime_profile_id=$(echo "$anime_profiles" | jq -r --arg name "$SONARR_ANIME_PROFILE" '[.[] | select(.name == $name)] | .[0].id // empty')
        anime_profile_name="$SONARR_ANIME_PROFILE"
        if [[ -z "$anime_profile_id" ]]; then
            anime_profile_id=$(echo "$anime_profiles" | jq -r '.[0].id // empty')
            anime_profile_name=$(echo "$anime_profiles" | jq -r '.[0].name // empty')
        fi

        local anime_roots anime_root
        anime_roots=$(api GET "$SONARR_ANIME_URL/api/v3/rootfolder" -H "X-Api-Key: $SONARR_ANIME_API_KEY" || echo "[]")
        anime_root=$(echo "$anime_roots" | jq -r '.[0].path // "/data/media/anime"')

        if [[ -n "$anime_profile_id" ]]; then
            api POST "$SEERR_URL/api/v1/settings/sonarr" -H "$SH" -d '{
                "name": "Sonarr (Anime)",
                "hostname": "gluetun",
                "port": 8990,
                "apiKey": "'"$SONARR_ANIME_API_KEY"'",
                "useSsl": false,
                "activeProfileId": '"$anime_profile_id"',
                "activeProfileName": "'"$anime_profile_name"'",
                "activeDirectory": "'"$anime_root"'",
                "activeAnimeProfileId": '"$anime_profile_id"',
                "activeAnimeProfileName": "'"$anime_profile_name"'",
                "activeAnimeDirectory": "'"$anime_root"'",
                "isDefault": false,
                "is4k": false,
                "enableSeasonFolders": true,
                "externalUrl": "http://'"$server_ip"':8990"
            }' >/dev/null || warn "Failed to add Sonarr Anime to Seerr."
            log "Seerr: Sonarr (Anime) added."
        else
            warn "Seerr: Could not determine Sonarr Anime quality profile — skipping."
        fi
    else
        [[ -n "$SONARR_ANIME_API_KEY" ]] && info "Seerr: Sonarr (Anime) already configured."
    fi

    # --- Radarr server ---
    local existing_radarr
    existing_radarr=$(api GET "$SEERR_URL/api/v1/settings/radarr" -H "$SH" || echo "[]")

    if [[ -n "$RADARR_API_KEY" ]] && ! echo "$existing_radarr" | jq -e '.[] | select(.port == 7878)' &>/dev/null; then
        local radarr_profiles radarr_profile_id radarr_profile_name
        radarr_profiles=$(api GET "$RADARR_URL/api/v3/qualityprofile" -H "X-Api-Key: $RADARR_API_KEY" || echo "[]")
        radarr_profile_id=$(echo "$radarr_profiles" | jq -r --arg name "$RADARR_PROFILE" '[.[] | select(.name == $name)] | .[0].id // empty')
        radarr_profile_name="$RADARR_PROFILE"
        if [[ -z "$radarr_profile_id" ]]; then
            radarr_profile_id=$(echo "$radarr_profiles" | jq -r '.[0].id // empty')
            radarr_profile_name=$(echo "$radarr_profiles" | jq -r '.[0].name // empty')
        fi

        local radarr_roots radarr_root
        radarr_roots=$(api GET "$RADARR_URL/api/v3/rootfolder" -H "X-Api-Key: $RADARR_API_KEY" || echo "[]")
        radarr_root=$(echo "$radarr_roots" | jq -r '.[0].path // "/data/media/movies"')

        if [[ -n "$radarr_profile_id" ]]; then
            api POST "$SEERR_URL/api/v1/settings/radarr" -H "$SH" -d '{
                "name": "Radarr",
                "hostname": "gluetun",
                "port": 7878,
                "apiKey": "'"$RADARR_API_KEY"'",
                "useSsl": false,
                "activeProfileId": '"$radarr_profile_id"',
                "activeProfileName": "'"$radarr_profile_name"'",
                "activeDirectory": "'"$radarr_root"'",
                "isDefault": true,
                "is4k": false,
                "externalUrl": "http://'"$server_ip"':7878"
            }' >/dev/null || warn "Failed to add Radarr to Seerr."
            log "Seerr: Radarr added."
        else
            warn "Seerr: Could not determine Radarr quality profile — skipping."
        fi
    else
        [[ -n "$RADARR_API_KEY" ]] && info "Seerr: Radarr already configured."
    fi

    # Update .env with Seerr API key
    sed -i.bak "s|^JELLYSEERR_API_KEY=.*|JELLYSEERR_API_KEY=${JELLYSEERR_API_KEY}|" "${SCRIPT_DIR}/.env"
    rm -f "${SCRIPT_DIR}/.env.bak"

    log "Seerr configured."
}

# =============================================================================
# Step 8: Configure Prowlarr
# =============================================================================
configure_prowlarr() {
    if [[ -z "$PROWLARR_API_KEY" ]]; then
        warn "No Prowlarr API key — skipping."
        return
    fi

    log "Configuring Prowlarr..."

    local PH="X-Api-Key: $PROWLARR_API_KEY"

    # Create FlareSolverr tag
    local existing_tags
    existing_tags=$(api GET "$PROWLARR_URL/api/v1/tag" -H "$PH" || echo "[]")
    if ! echo "$existing_tags" | jq -e '.[] | select(.label == "flaresolverr")' &>/dev/null; then
        api POST "$PROWLARR_URL/api/v1/tag" -H "$PH" -d '{"label":"flaresolverr"}' >/dev/null || true
    fi
    local fs_tag_id
    fs_tag_id=$(api GET "$PROWLARR_URL/api/v1/tag" -H "$PH" | jq -r '.[] | select(.label == "flaresolverr") | .id' || echo "1")

    # Create anime tag
    if ! echo "$existing_tags" | jq -e '.[] | select(.label == "anime")' &>/dev/null; then
        api POST "$PROWLARR_URL/api/v1/tag" -H "$PH" -d '{"label":"anime"}' >/dev/null || true
    fi
    local anime_tag_id
    anime_tag_id=$(api GET "$PROWLARR_URL/api/v1/tag" -H "$PH" | jq -r '.[] | select(.label == "anime") | .id' || echo "2")

    # Add FlareSolverr proxy
    local existing_proxies
    existing_proxies=$(api GET "$PROWLARR_URL/api/v1/indexerProxy" -H "$PH" || echo "[]")
    if ! echo "$existing_proxies" | jq -e '.[] | select(.implementation == "FlareSolverr")' &>/dev/null; then
        api POST "$PROWLARR_URL/api/v1/indexerProxy" -H "$PH" -d '{
            "name": "FlareSolverr",
            "implementation": "FlareSolverr",
            "configContract": "FlareSolverrSettings",
            "fields": [
                {"name": "host", "value": "http://gluetun:8191"},
                {"name": "requestTimeout", "value": 60}
            ],
            "tags": ['"$fs_tag_id"']
        }' >/dev/null || warn "Failed to add FlareSolverr."
        log "Prowlarr: FlareSolverr proxy added."
    fi

    # Connect Sonarr
    local existing_apps
    existing_apps=$(api GET "$PROWLARR_URL/api/v1/applications" -H "$PH" || echo "[]")

    if [[ -n "$SONARR_API_KEY" ]] && ! echo "$existing_apps" | jq -e '.[] | select(.name == "Sonarr")' &>/dev/null; then
        api POST "$PROWLARR_URL/api/v1/applications" -H "$PH" -d '{
            "name": "Sonarr",
            "syncLevel": "fullSync",
            "implementation": "Sonarr",
            "configContract": "SonarrSettings",
            "fields": [
                {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                {"name": "baseUrl", "value": "http://gluetun:8989"},
                {"name": "apiKey", "value": "'"$SONARR_API_KEY"'"},
                {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]}
            ]
        }' >/dev/null || warn "Failed to connect Sonarr."
        log "Prowlarr: Sonarr connected."
    fi

    # Connect Sonarr Anime (with anime tag so only anime-tagged indexers sync)
    if [[ -n "$SONARR_ANIME_API_KEY" ]] && ! echo "$existing_apps" | jq -e '.[] | select(.name == "Sonarr (Anime)")' &>/dev/null; then
        api POST "$PROWLARR_URL/api/v1/applications" -H "$PH" -d '{
            "name": "Sonarr (Anime)",
            "syncLevel": "fullSync",
            "implementation": "Sonarr",
            "configContract": "SonarrSettings",
            "tags": ['"$anime_tag_id"'],
            "fields": [
                {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                {"name": "baseUrl", "value": "http://gluetun:8990"},
                {"name": "apiKey", "value": "'"$SONARR_ANIME_API_KEY"'"},
                {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]}
            ]
        }' >/dev/null || warn "Failed to connect Sonarr Anime."
        log "Prowlarr: Sonarr (Anime) connected with anime tag."
    fi

    # Connect Radarr
    if [[ -n "$RADARR_API_KEY" ]] && ! echo "$existing_apps" | jq -e '.[] | select(.implementation == "Radarr")' &>/dev/null; then
        api POST "$PROWLARR_URL/api/v1/applications" -H "$PH" -d '{
            "name": "Radarr",
            "syncLevel": "fullSync",
            "implementation": "Radarr",
            "configContract": "RadarrSettings",
            "fields": [
                {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                {"name": "baseUrl", "value": "http://gluetun:7878"},
                {"name": "apiKey", "value": "'"$RADARR_API_KEY"'"},
                {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]}
            ]
        }' >/dev/null || warn "Failed to connect Radarr."
        log "Prowlarr: Radarr connected."
    fi

    # Add indexers from config — use schema approach for proper field definitions
    local indexer_count
    indexer_count=$(cfg '[.indexers? // [] | length] | .[0]')

    if [[ "$indexer_count" -gt 0 ]]; then
        # Fetch all indexer schemas once
        local schemas
        schemas=$(api GET "$PROWLARR_URL/api/v1/indexer/schema" -H "$PH" || echo "[]")

        local existing_indexers
        existing_indexers=$(api GET "$PROWLARR_URL/api/v1/indexer" -H "$PH" || echo "[]")

        for ((i = 0; i < indexer_count; i++)); do
            local idx_name idx_def idx_impl idx_enable idx_fs idx_anime
            idx_name=$(cfg ".indexers[$i].name")
            idx_def=$(cfg ".indexers[$i].definitionName // null")
            idx_impl=$(cfg ".indexers[$i].implementation // null")
            idx_enable=$(cfg ".indexers[$i].enable // true")
            idx_fs=$(cfg ".indexers[$i].flaresolverr // false")
            idx_anime=$(cfg ".indexers[$i].anime // false")

            [[ "$idx_enable" != "true" ]] && continue

            # Build tags array (combine flaresolverr + anime tags)
            local tag_list=()
            [[ "$idx_fs" == "true" ]] && tag_list+=("$fs_tag_id")
            [[ "$idx_anime" == "true" ]] && tag_list+=("$anime_tag_id")
            local tags
            tags=$(printf '%s\n' "${tag_list[@]}" | jq -s '.' 2>/dev/null || echo "[]")

            # If indexer already exists, ensure tags are up to date
            local existing_idx
            existing_idx=$(echo "$existing_indexers" | jq -c ".[] | select(.name == \"$idx_name\")")
            if [[ -n "$existing_idx" ]]; then
                local missing_tags
                missing_tags=$(echo "$existing_idx" | jq -c --argjson desired "$tags" '$desired - .tags')
                if [[ "$missing_tags" != "[]" ]]; then
                    local idx_id
                    idx_id=$(echo "$existing_idx" | jq -r '.id')
                    local full_idx
                    full_idx=$(api GET "$PROWLARR_URL/api/v1/indexer/$idx_id" -H "$PH")
                    local updated
                    updated=$(echo "$full_idx" | jq -c --argjson t "$tags" '.tags = (.tags + $t | unique)')
                    api PUT "$PROWLARR_URL/api/v1/indexer/$idx_id" -H "$PH" -d "$updated" >/dev/null \
                        || warn "Failed to update tags on '${idx_name}'."
                    log "Prowlarr: updated tags on '${idx_name}'."
                else
                    info "Prowlarr: indexer '${idx_name}' already exists."
                fi
                continue
            fi

            if [[ "$idx_impl" == "Newznab" ]]; then
                # Newznab indexer — use Newznab schema and inject fields
                local idx_baseUrl idx_apiPath idx_apiKey
                idx_baseUrl=$(cfg ".indexers[$i].fields.baseUrl")
                idx_apiPath=$(cfg ".indexers[$i].fields.apiPath // \"/api\"")
                idx_apiKey=$(cfg ".indexers[$i].fields.apiKey")

                local newznab_schema
                newznab_schema=$(echo "$schemas" | jq -c '[.[] | select(.implementation == "Newznab")] | .[0]')

                if [[ "$newznab_schema" == "null" ]] || [[ -z "$newznab_schema" ]]; then
                    warn "Prowlarr: no Newznab schema found — skipping '${idx_name}'."
                    continue
                fi

                local payload
                payload=$(echo "$newznab_schema" | jq -c \
                    --arg name "$idx_name" \
                    --argjson tags "$tags" \
                    --arg baseUrl "$idx_baseUrl" \
                    --arg apiPath "$idx_apiPath" \
                    --arg apiKey "$idx_apiKey" \
                    '.name = $name | .enable = true | del(.id) | .appProfileId = 1 | .tags = $tags |
                     (.fields[] | select(.name == "baseUrl")).value = $baseUrl |
                     (.fields[] | select(.name == "apiPath")).value = $apiPath |
                     (.fields[] | select(.name == "apiKey")).value = $apiKey')

                api POST "$PROWLARR_URL/api/v1/indexer" -H "$PH" -d "$payload" >/dev/null \
                    || warn "Failed to add Newznab indexer '${idx_name}'."
                log "Prowlarr: Newznab indexer '${idx_name}' added."
            else
                # Standard indexer — find schema by definitionName
                local schema
                schema=$(echo "$schemas" | jq -c --arg defName "$idx_def" '[.[] | select(.definitionName == $defName)] | .[0]')

                if [[ "$schema" == "null" ]] || [[ -z "$schema" ]]; then
                    warn "Prowlarr: no schema found for '${idx_def}' — skipping."
                    continue
                fi

                local payload
                payload=$(echo "$schema" | jq -c \
                    --arg name "$idx_name" \
                    --argjson tags "$tags" \
                    '.name = $name | .enable = true | del(.id) | .appProfileId = 1 | .tags = $tags')

                api POST "$PROWLARR_URL/api/v1/indexer" -H "$PH" -d "$payload" >/dev/null \
                    || warn "Failed to add indexer '${idx_name}'."
                log "Prowlarr: indexer '${idx_name}' added."
            fi
        done
    fi

    log "Prowlarr configured."
}

# =============================================================================
# Step 8: Configure Bazarr
# =============================================================================
configure_bazarr() {
    log "Configuring Bazarr..."

    local bazarr_config="${SCRIPT_DIR}/bazarr/config/config.yaml"

    if [[ -f "$bazarr_config" ]]; then
        # Newer Bazarr uses config.yaml
        if [[ -n "$SONARR_API_KEY" ]]; then
            yq -i ".sonarr.ip = \"localhost\" | .sonarr.port = 8989 | .sonarr.apikey = \"${SONARR_API_KEY}\" | .sonarr.base_url = \"\" | .sonarr.ssl = false | .general.use_sonarr = true" "$bazarr_config"
        fi
        if [[ -n "$RADARR_API_KEY" ]]; then
            yq -i ".radarr.ip = \"localhost\" | .radarr.port = 7878 | .radarr.apikey = \"${RADARR_API_KEY}\" | .radarr.base_url = \"\" | .radarr.ssl = false | .general.use_radarr = true" "$bazarr_config"
        fi
        yq -i ".general.minimum_score = 90 | .general.minimum_score_movie = 80" "$bazarr_config"
        yq -i ".subsync.use_subsync = true | .subsync.force_audio = true | .subsync.gss = true | .subsync.max_offset_seconds = 60 | .subsync.no_fix_framerate = true | .subsync.use_subsync_threshold = true | .subsync.subsync_threshold = 96 | .subsync.use_subsync_movie_threshold = true | .subsync.subsync_movie_threshold = 86" "$bazarr_config"
        log "Bazarr configured (Sonarr/Radarr connections via config.yaml)."
    elif [[ -f "${SCRIPT_DIR}/bazarr/config/config.ini" ]]; then
        # Older Bazarr uses config.ini
        local bazarr_ini="${SCRIPT_DIR}/bazarr/config/config.ini"
        python3 - "$bazarr_ini" "$SONARR_API_KEY" "$RADARR_API_KEY" << 'PYEOF'
import sys, configparser
config_path, sonarr_key, radarr_key = sys.argv[1], sys.argv[2], sys.argv[3]
config = configparser.ConfigParser()
config.read(config_path)
def ensure(s):
    if not config.has_section(s): config.add_section(s)
if sonarr_key:
    ensure('sonarr'); ensure('general')
    config.set('sonarr', 'ip', 'localhost'); config.set('sonarr', 'port', '8989')
    config.set('sonarr', 'apikey', sonarr_key); config.set('sonarr', 'ssl', 'False')
    config.set('general', 'use_sonarr', 'True')
if radarr_key:
    ensure('radarr'); ensure('general')
    config.set('radarr', 'ip', 'localhost'); config.set('radarr', 'port', '7878')
    config.set('radarr', 'apikey', radarr_key); config.set('radarr', 'ssl', 'False')
    config.set('general', 'use_radarr', 'True')
with open(config_path, 'w') as f: config.write(f)
PYEOF
        log "Bazarr configured (Sonarr/Radarr connections via config.ini)."
    else
        warn "Bazarr config not found — service may not have started yet."
    fi
}

# =============================================================================
# Step 8b: Configure Bazarr Anime
# =============================================================================
configure_bazarr_anime() {
    log "Configuring Bazarr Anime..."

    local bazarr_config="${SCRIPT_DIR}/bazarr-anime/config/config.yaml"
    local bazarr_main_config="${SCRIPT_DIR}/bazarr/config/config.yaml"

    if [[ ! -f "$bazarr_config" ]]; then
        warn "Bazarr Anime config not found — service may not have started yet."
        return
    fi

    # Connect to Sonarr Anime (no Radarr), set lower score threshold for anime
    if [[ -n "$SONARR_ANIME_API_KEY" ]]; then
        yq -i ".sonarr.ip = \"localhost\" | .sonarr.port = 8990 | .sonarr.apikey = \"${SONARR_ANIME_API_KEY}\" | .sonarr.base_url = \"\" | .sonarr.ssl = false | .general.use_sonarr = true | .general.use_radarr = false | .general.minimum_score = 60 | .general.minimum_score_episode = 60" "$bazarr_config"
    fi
    yq -i ".subsync.use_subsync = true | .subsync.force_audio = true | .subsync.gss = true | .subsync.max_offset_seconds = 60 | .subsync.no_fix_framerate = true | .subsync.use_subsync_threshold = true | .subsync.subsync_threshold = 90 | .subsync.use_subsync_movie_threshold = true | .subsync.subsync_movie_threshold = 70" "$bazarr_config"

    # Copy subtitle provider settings from main Bazarr if not already configured
    if [[ -f "$bazarr_main_config" ]]; then
        local anime_providers
        anime_providers=$(yq '.opensubtitlescom.username // ""' "$bazarr_config")
        if [[ -z "$anime_providers" ]]; then
            log "Bazarr Anime: copying subtitle providers from main Bazarr..."
            # Copy provider sections
            for section in opensubtitlescom opensubtitles addic7ed subtitulamostv subdivx supersubtitles; do
                local section_json
                section_json=$(yq -o json ".${section} // {}" "$bazarr_main_config")
                if [[ "$section_json" != "{}" ]]; then
                    yq -i ".${section} = $(echo "$section_json")" "$bazarr_config"
                fi
            done
            # Copy enabled providers list and add anime-specific providers
            local enabled_providers
            enabled_providers=$(yq -o json '.general.enabled_providers // ""' "$bazarr_main_config")
            if [[ -n "$enabled_providers" && "$enabled_providers" != '""' ]]; then
                yq -i ".general.enabled_providers = ${enabled_providers}" "$bazarr_config"
            fi
            yq -i '.general.enabled_providers += ["animetosho", "podnapisi"] | .general.enabled_providers |= unique' "$bazarr_config"
        fi
    fi

    # Copy language profile from main Bazarr database if anime database has none
    local anime_db="${SCRIPT_DIR}/bazarr-anime/db/bazarr.db"
    local main_db="${SCRIPT_DIR}/bazarr/db/bazarr.db"
    if [[ -f "$anime_db" ]] && [[ -f "$main_db" ]]; then
        local profile_count
        profile_count=$(python3 -c "
import sqlite3
conn = sqlite3.connect('${anime_db}')
cur = conn.cursor()
cur.execute('SELECT COUNT(*) FROM table_languages_profiles')
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null || echo "0")
        if [[ "$profile_count" -eq 0 ]]; then
            log "Bazarr Anime: copying language profiles from main Bazarr..."
            python3 -c "
import sqlite3
src = sqlite3.connect('${main_db}')
dst = sqlite3.connect('${anime_db}')
for row in src.execute('SELECT profileId, cutoff, originalFormat, items, name, mustContain, mustNotContain, tag FROM table_languages_profiles'):
    dst.execute('INSERT INTO table_languages_profiles (profileId, cutoff, originalFormat, items, name, mustContain, mustNotContain, tag) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', row)
dst.commit()
src.close()
dst.close()
print('Done')
" && log "Bazarr Anime: language profiles copied."
            # Set default series profile to the first one
            yq -i '.general.serie_default_profile = 1' "$bazarr_config"
            # Restart to pick up database changes
            docker restart bazarr-anime &>/dev/null || true
            log "Bazarr Anime: restarted to apply language profiles."
        fi
    fi

    # Apply default profile to any series that don't have one
    if [[ -n "$BAZARR_ANIME_API_KEY" ]]; then
        local unassigned
        unassigned=$(curl -sf "http://localhost:6868/api/series?start=0&length=500" \
            -H "X-API-KEY: $BAZARR_ANIME_API_KEY" 2>/dev/null \
            | jq -r '[.data[] | select(.profileId == null) | .sonarrSeriesId] | join(",")' 2>/dev/null || true)
        if [[ -n "$unassigned" ]]; then
            local ids_json
            ids_json=$(echo "$unassigned" | tr ',' '\n' | jq -s '.')
            curl -sf -X POST "http://localhost:6868/api/series" \
                -H "X-API-KEY: $BAZARR_ANIME_API_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"seriesid\": ${ids_json}, \"profileid\": [1]}" &>/dev/null || true
            log "Bazarr Anime: assigned language profile to unassigned series."
        fi
    fi

    log "Bazarr Anime configured."
}

# =============================================================================
# Step 9: Configure SABnzbd
# =============================================================================
configure_sabnzbd() {
    local usenet_count
    usenet_count=$(cfg '[.usenet_providers? // [] | length] | .[0]')

    if [[ "$usenet_count" -eq 0 ]] || [[ "$usenet_count" == "null" ]]; then
        info "No usenet providers configured — skipping SABnzbd."
        return
    fi

    if [[ -z "$SABNZBD_API_KEY" ]]; then
        warn "SABnzbd API key not found — skipping SABnzbd configuration."
        return
    fi

    log "Configuring SABnzbd..."

    local SAB_URL="http://localhost:8080"

    # Add gluetun to host_whitelist so Homepage can reach SABnzbd
    local sab_ini="${SCRIPT_DIR}/sabnzbd/sabnzbd.ini"
    if [[ -f "$sab_ini" ]]; then
        local current_whitelist
        current_whitelist=$(grep -oP 'host_whitelist *= *\K.*' "$sab_ini" 2>/dev/null || true)
        if [[ "$current_whitelist" != *"gluetun"* ]]; then
            sed -i "s|^host_whitelist *= *.*|host_whitelist = ${current_whitelist} gluetun,|" "$sab_ini"
            log "SABnzbd: added gluetun to host_whitelist."
        fi
    fi

    # Configure download paths
    curl -sf -o /dev/null "${SAB_URL}/api?mode=set_config&section=misc&keyword=download_dir&download_dir=/data/usenet/incomplete&apikey=${SABNZBD_API_KEY}" \
        || warn "Failed to set SABnzbd incomplete dir."
    curl -sf -o /dev/null "${SAB_URL}/api?mode=set_config&section=misc&keyword=complete_dir&complete_dir=/data/usenet/complete&apikey=${SABNZBD_API_KEY}" \
        || warn "Failed to set SABnzbd complete dir."

    # Create categories for arr services (needed before Sonarr/Radarr can add SABnzbd)
    for sab_cat in sonarr sonarr-anime radarr; do
        curl -sf -o /dev/null "${SAB_URL}/api?mode=set_config&section=categories&keyword=${sab_cat}&name=${sab_cat}&dir=${sab_cat}&apikey=${SABNZBD_API_KEY}" || true
    done
    log "SABnzbd: categories created."

    # Add each usenet provider as a server
    for ((i = 0; i < usenet_count; i++)); do
        local srv_name srv_host srv_port srv_ssl srv_user srv_pass srv_connections srv_enable
        srv_name=$(cfg ".usenet_providers[$i].name")
        srv_enable=$(cfg ".usenet_providers[$i].enable // true")
        srv_host=$(cfg ".usenet_providers[$i].host")
        srv_port=$(cfg ".usenet_providers[$i].port // 563")
        srv_ssl=$(cfg ".usenet_providers[$i].ssl // true")
        srv_user=$(cfg ".usenet_providers[$i].username // \"\"")
        srv_pass=$(cfg ".usenet_providers[$i].password // \"\"")
        srv_connections=$(cfg ".usenet_providers[$i].connections // 10")

        [[ "$srv_enable" != "true" ]] && continue

        # Convert boolean ssl to 0/1
        local ssl_val=0
        [[ "$srv_ssl" == "true" ]] && ssl_val=1

        local enable_val=1

        # Check if a server with this host already exists (may have a different name)
        local existing_server
        existing_server=$(grep -B1 "^host = ${srv_host}$" "$sab_ini" 2>/dev/null | grep -oP '^\[\[\K[^\]]+' || true)
        local sab_key="${existing_server:-${srv_name}}"

        curl -sf -o /dev/null "${SAB_URL}/api?mode=set_config&section=servers&keyword=${sab_key}&name=${sab_key}&host=${srv_host}&port=${srv_port}&ssl=${ssl_val}&username=${srv_user}&password=${srv_pass}&connections=${srv_connections}&ssl_verify=2&enable=${enable_val}&timeout=60&apikey=${SABNZBD_API_KEY}" \
            || warn "Failed to add usenet server '${srv_name}' to SABnzbd."
        log "SABnzbd: server '${sab_key}' configured."
    done

    log "SABnzbd configured."
}

# =============================================================================
# Step 10: Update Homepage + Recyclarr with discovered keys
# =============================================================================
update_configs() {
    log "Updating Homepage and Recyclarr configs..."

    # Homepage environment variables
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    # Preserve existing Immich API key if user has set one (created manually in Immich UI).
    local immich_key=""
    if [[ -f "${SCRIPT_DIR}/homepage/.env" ]]; then
        immich_key=$(grep -oP '^HOMEPAGE_VAR_IMMICH_API_KEY=\K.*' "${SCRIPT_DIR}/homepage/.env" || true)
    fi

    cat > "${SCRIPT_DIR}/homepage/.env" <<EOF
HOMEPAGE_ALLOWED_HOSTS=localhost:3010,${server_ip}:3010
HOMEPAGE_VAR_SERVER_IP=${server_ip}
HOMEPAGE_VAR_JELLYFIN_API_KEY=${JELLYFIN_API_KEY:-}
HOMEPAGE_VAR_JELLYSEERR_API_KEY=${JELLYSEERR_API_KEY:-}
HOMEPAGE_VAR_QBITTORRENT_USERNAME=${QBIT_USER}
HOMEPAGE_VAR_QBITTORRENT_PASSWORD=${QBIT_PASS}
HOMEPAGE_VAR_SONARR_API_KEY=${SONARR_API_KEY:-}
HOMEPAGE_VAR_SONARR_ANIME_API_KEY=${SONARR_ANIME_API_KEY:-}
HOMEPAGE_VAR_RADARR_API_KEY=${RADARR_API_KEY:-}
HOMEPAGE_VAR_BAZARR_API_KEY=${BAZARR_API_KEY:-}
HOMEPAGE_VAR_PROWLARR_API_KEY=${PROWLARR_API_KEY:-}
HOMEPAGE_VAR_SABNZBD_API_KEY=${SABNZBD_API_KEY:-}
HOMEPAGE_VAR_IMMICH_API_KEY=${immich_key}
EOF
    log "Homepage .env written."

    # Recyclarr secrets
    if [[ -n "$SONARR_API_KEY" ]] && [[ -n "$RADARR_API_KEY" ]]; then
        cat > "${SCRIPT_DIR}/recyclarr/secrets.yml" <<EOF
radarr_url: http://localhost:7878
radarr_apikey: ${RADARR_API_KEY}
sonarr_url: http://localhost:8989
sonarr_apikey: ${SONARR_API_KEY}
sonarr_anime_url: http://localhost:8990
sonarr_anime_apikey: ${SONARR_ANIME_API_KEY}
EOF
        log "Recyclarr secrets.yml updated."
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN} Media Server Configuration${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo ""

    preseed_sonarr_anime
    preseed_bazarr_anime
    generate_env
    wait_for_services
    read_api_keys
    configure_qbittorrent
    configure_sabnzbd
    configure_jellyfin
    configure_sonarr_radarr
    configure_seerr
    configure_prowlarr
    configure_bazarr
    configure_bazarr_anime
    update_configs

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} Configuration complete!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    info "API Keys:"
    info "  Sonarr:       ${SONARR_API_KEY:-not found}"
    info "  Sonarr Anime: ${SONARR_ANIME_API_KEY:-not found}"
    info "  Radarr:       ${RADARR_API_KEY:-not found}"
    info "  Prowlarr:     ${PROWLARR_API_KEY:-not found}"
    info "  Jellyfin:     ${JELLYFIN_API_KEY:-not found}"
    info "  Seerr:        ${JELLYSEERR_API_KEY:-not found}"
    info "  Bazarr:       ${BAZARR_API_KEY:-not found}"
    info "  Bazarr Anime: ${BAZARR_ANIME_API_KEY:-not found}"
    echo ""
    info "Restart services for all changes to take effect:"
    info "  make restart"
    echo ""
}

main "$@"
