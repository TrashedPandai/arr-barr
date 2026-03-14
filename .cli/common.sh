#!/usr/bin/env bash
# Shared boilerplate for arr CLI commands
# Source this: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Source the theme
CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
source "$CLI_DIR/branding.sh"

# Paths
ARR_HOME="$(cd "$CLI_DIR/.." && pwd)"

# Docker access
DOCKER_CMD="docker"
detect_docker() {
    if ! command -v docker &>/dev/null && [ -x /usr/local/bin/docker ]; then
        export PATH="/usr/local/bin:$PATH"
    fi
    if docker info &>/dev/null; then
        :
    elif sudo -n docker info &>/dev/null; then
        DOCKER_CMD="sudo docker"
    elif sudo -n /usr/local/bin/docker info &>/dev/null; then
        DOCKER_CMD="sudo /usr/local/bin/docker"
    else
        DOCKER_CMD="sudo docker"
        echo ""
        echo -e "  ${C_YELLOW}Docker requires elevated access. Enter your password to continue.${S_RESET}"
        echo ""
        sudo true || exit 1
    fi
}

# DATA_ROOT from .env
get_data_root() {
    if [ -f "$ARR_HOME/.env" ]; then
        raw="$(grep '^DATA_ROOT=' "$ARR_HOME/.env" | cut -d= -f2- || true)"
        echo "$raw"
    else
        echo ""
    fi
}

# ── Services ──────────────────────────────────────────────────────────────────

# Services list: name|port|label
SERVICES=(
    "gluetun||VPN Tunnel"
    "transmission|9091|Torrents"
    "sabnzbd|8080|Usenet"
    "prowlarr|9696|Indexers"
    "flaresolverr|8191|Anti-Bot Bypass"
    "radarr|7878|Movies"
    "sonarr|8989|TV Shows"
    "lidarr|8686|Music"
    "bazarr|6767|Subtitles"
    "jellyfin|8096|Media Server"
    "seerr|5055|Requests"
    "lazylibrarian|5299|Book Search"
    "kavita|5004|Book Reader"
    "audiobookshelf|13378|Audiobooks"
    "questarr|5002|Games"
)

KNOWN_SERVICES=""
for entry in "${SERVICES[@]}"; do
    KNOWN_SERVICES+="${entry%%|*} "
done

# ── Human-Readable Formatters ────────────────────────────────────────────────

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%.1f GB" "$(awk "BEGIN {printf \"%.1f\", $bytes / 1073741824}")"
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%.1f MB" "$(awk "BEGIN {printf \"%.1f\", $bytes / 1048576}")"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.0f KB" "$(awk "BEGIN {printf \"%.0f\", $bytes / 1024}")"
    else
        printf "%d B" "$bytes"
    fi
}

human_speed() {
    local bps=$1
    if [ "$bps" -ge 1048576 ]; then
        printf "%.1f MB/s" "$(awk "BEGIN {printf \"%.1f\", $bps / 1048576}")"
    elif [ "$bps" -ge 1024 ]; then
        printf "%.0f KB/s" "$(awk "BEGIN {printf \"%.0f\", $bps / 1024}")"
    else
        printf "%d B/s" "$bps"
    fi
}

human_eta() {
    local secs=$1
    if [ "$secs" -le 0 ]; then
        echo "—"
    elif [ "$secs" -ge 86400 ]; then
        printf "%dd %dh" "$((secs / 86400))" "$(((secs % 86400) / 3600))"
    elif [ "$secs" -ge 3600 ]; then
        printf "%dh %dm" "$((secs / 3600))" "$(((secs % 3600) / 60))"
    elif [ "$secs" -ge 60 ]; then
        printf "%dm %ds" "$((secs / 60))" "$((secs % 60))"
    else
        printf "%ds" "$secs"
    fi
}

# ── Table Helpers ─────────────────────────────────────────────────────────────

# Print a formatted table row
# Usage: table_row "col1" "col2" "col3" ... with widths
# Or simpler: kv_line "Key" "Value"
kv_line() {
    local key="$1"
    local value="$2"
    local key_color="${3:-$C_SUBTEXT0}"
    local val_color="${4:-$C_TEXT}"
    printf "  ${key_color}%-16s${S_RESET} ${val_color}%s${S_RESET}\n" "$key" "$value"
}

# ── Confirmations ────────────────────────────────────────────────────────────

# Ask yes/no with styled prompt
# Usage: confirm "Are you sure?" && do_thing
confirm() {
    local msg="${1:-Continue?}"
    local default="${2:-n}"
    local hint="y/N"
    [ "$default" = "y" ] && hint="Y/n"
    printf "  ${C_PEACH}?${S_RESET} ${C_TEXT}${msg}${S_RESET} ${C_OVERLAY0}[${hint}]${S_RESET} "
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# ── Message Helpers ───────────────────────────────────────────────────────────

msg_success() { echo -e "  ${C_GREEN}✓${S_RESET} ${C_TEXT}$1${S_RESET}"; }
msg_error()   { echo -e "  ${C_RED}✗${S_RESET} ${C_TEXT}$1${S_RESET}"; }
msg_warn()    { echo -e "  ${C_YELLOW}!${S_RESET} ${C_TEXT}$1${S_RESET}"; }
msg_info()    { echo -e "  ${C_BLUE}●${S_RESET} ${C_TEXT}$1${S_RESET}"; }
msg_dim()     { echo -e "  ${C_OVERLAY0}$1${S_RESET}"; }

# ── Prerequisites ────────────────────────────────────────────────────────────

require_jq() {
    if command -v jq &>/dev/null; then
        return 0
    elif command -v python3 &>/dev/null; then
        jq() {
            python3 -c "
import sys, json
data = json.load(sys.stdin)
expr = sys.argv[1]
if expr == '.':
    print(json.dumps(data))
else:
    parts = expr.strip('.').split('.')
    for p in parts:
        if p.startswith('[') and p.endswith(']'):
            data = data[int(p[1:-1])]
        elif '[' in p:
            key, idx = p.split('[')
            idx = int(idx.rstrip(']'))
            data = data[key][idx]
        else:
            data = data[p]
    if isinstance(data, (dict, list)):
        print(json.dumps(data))
    else:
        print(data)
" "$@"
        }
        export -f jq 2>/dev/null || true
        return 0
    else
        msg_error "jq or python3 required but not found."
        msg_dim "Install jq: sudo apt install jq  /  sudo opkg install jq"
        return 1
    fi
}

require_curl() {
    if ! command -v curl &>/dev/null; then
        msg_error "curl is required but not found."
        msg_dim "Install: sudo apt install curl (Debian/Ubuntu) or sudo dnf install curl (Fedora)"
        exit 1
    fi
}

require_env() {
    if [ ! -f "$ARR_HOME/.env" ]; then
        msg_error ".env file not found."
        echo -e "  ${C_SUBTEXT0}Run ${S_BOLD}arr setup${S_RESET}${C_SUBTEXT0} first.${S_RESET}"
        exit 1
    fi
}

# ── Compose Helper ────────────────────────────────────────────────────────────

compose_cmd() {
    $DOCKER_CMD compose -f "$ARR_HOME/compose.yaml" --env-file "$ARR_HOME/.env" "$@"
}

# ── Progress Steps ────────────────────────────────────────────────────────────

# Show a numbered step indicator
# Usage: step 1 5 "Installing dependencies"
step() {
    local current=$1
    local total=$2
    local msg="$3"
    printf "  ${C_SAPPHIRE}[%d/%d]${S_RESET} ${C_TEXT}%s${S_RESET}\n" "$current" "$total" "$msg"
}
