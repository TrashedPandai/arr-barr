#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env
require_curl
require_jq || exit 1

DATA_ROOT="$(get_data_root)"

# ══════════════════════════════════════════════════════════════════════════════
#  arr dashboard — the flagship command
# ══════════════════════════════════════════════════════════════════════════════

# ── Terminal width ────────────────────────────────────────────────────────────

TERM_W=$(tput cols 2>/dev/null || echo 80)
(( TERM_W < 60 )) && TERM_W=60
(( TERM_W > 140 )) && TERM_W=140

# ── API Key Extraction ────────────────────────────────────────────────────────

_extract_xml_key() {
    local file="$1" tag="$2"
    grep -oP "(?<=<${tag}>)[^<]+" "$file" 2>/dev/null || true
}

_extract_ini_key() {
    local file="$1" key="$2"
    grep "^${key}" "$file" 2>/dev/null | head -1 | sed 's/^[^=]*= *//' | tr -d ' \r' || true
}

_extract_bazarr_key() {
    # Bazarr stores apikey under auth: in config.yaml
    local file="$1"
    awk '/^auth:/{found=1;next} found && /^  apikey:/{print $2; exit} found && /^[^ ]/{exit}' "$file" 2>/dev/null || true
}

RADARR_KEY="$(_extract_xml_key "$DATA_ROOT/config/radarr/config.xml" "ApiKey")"
SONARR_KEY="$(_extract_xml_key "$DATA_ROOT/config/sonarr/config.xml" "ApiKey")"
LIDARR_KEY="$(_extract_xml_key "$DATA_ROOT/config/lidarr/config.xml" "ApiKey")"
PROWLARR_KEY="$(_extract_xml_key "$DATA_ROOT/config/prowlarr/config.xml" "ApiKey")"
BAZARR_KEY="$(_extract_bazarr_key "$DATA_ROOT/config/bazarr/config/config.yaml")"
SAB_KEY="$(_extract_ini_key "$DATA_ROOT/config/sabnzbd/sabnzbd.ini" "api_key")"

# ── Temp directory for parallel results ───────────────────────────────────────

TMPDIR=$(mktemp -d /tmp/arr-dash-XXXXXX)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

# ── Profiles check ────────────────────────────────────────────────────────────

PROFILES="$(grep '^COMPOSE_PROFILES=' "$ARR_HOME/.env" 2>/dev/null | cut -d= -f2- || true)"

profile_active() {
    local svc="$1"
    # Core services are always active, profile services need to be in COMPOSE_PROFILES
    case "$svc" in
        lazylibrarian|kavita|audiobookshelf)
            echo ",$PROFILES," | grep -q ",$svc," && return 0
            # Also check if container is actually running
            [ -f "$TMPDIR/containers" ] && grep -q "^${svc}|running" "$TMPDIR/containers" && return 0
            return 1
            ;;
        questarr)
            # Gaming is always in compose but may not be running
            [ -f "$TMPDIR/containers" ] && grep -q "^${svc}|running" "$TMPDIR/containers" && return 0
            return 1
            ;;
        *) return 0 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1: PARALLEL DATA FETCH
# ══════════════════════════════════════════════════════════════════════════════

# 1. Container states
(
    $DOCKER_CMD ps -a --format '{{.Names}}|{{.State}}' > "$TMPDIR/containers" 2>/dev/null || true
) &

# 2. Disk usage
(
    df -P /volume1/data 2>/dev/null | awk 'NR==2{print $2"|"$3"|"$4"|"$5}' > "$TMPDIR/disk" || true
) &

# 3. VPN IP (via gluetun container)
(
    $DOCKER_CMD exec gluetun wget -qO- --timeout=3 https://ipinfo.io/json 2>/dev/null > "$TMPDIR/vpn" || true
) &

# 4. Health checks — all 15 endpoints in parallel
declare -A HEALTH_URLS=(
    [gluetun]="http://localhost:8000/v1/openvpn/status|302"
    [transmission]="http://localhost:9091/transmission/rpc|409"
    [sabnzbd]="http://localhost:8080/api?mode=version&output=json|200"
    [prowlarr]="http://localhost:9696/ping|200"
    [flaresolverr]="http://localhost:8191/health|200"
    [radarr]="http://localhost:7878/ping|200"
    [sonarr]="http://localhost:8989/ping|200"
    [lidarr]="http://localhost:8686/ping|200"
    [bazarr]="http://localhost:6767/ping|200"
    [jellyfin]="http://localhost:8096/System/Info/Public|200"
    [seerr]="http://localhost:5055/api/v1/status|200"
    [lazylibrarian]="http://localhost:5299/api?cmd=getVersion|200"
    [kavita]="http://localhost:5004/api/health|200"
    [audiobookshelf]="http://localhost:13378/healthcheck|200"
    [questarr]="http://localhost:5002/|200"
)

for svc in "${!HEALTH_URLS[@]}"; do
    (
        IFS='|' read -r url expected <<< "${HEALTH_URLS[$svc]}"
        start_ns=$(date +%s%N 2>/dev/null || echo 0)
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 "$url" 2>/dev/null || echo "000")
        end_ns=$(date +%s%N 2>/dev/null || echo 0)
        ms=0
        if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
            ms=$(( (end_ns - start_ns) / 1000000 ))
        fi
        echo "${code}|${expected}|${ms}" > "$TMPDIR/health_${svc}"
    ) &
done

# 5. Radarr data
(
    curl -s --max-time 3 "http://localhost:7878/api/v3/movie?apikey=${RADARR_KEY}" 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" > "$TMPDIR/radarr_movies" 2>/dev/null || true
) &
(
    curl -s --max-time 3 "http://localhost:7878/api/v3/queue?apikey=${RADARR_KEY}&page=1&pageSize=1" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('totalRecords',0))" > "$TMPDIR/radarr_queue" 2>/dev/null || true
) &
(
    curl -s --max-time 3 "http://localhost:7878/api/v3/wanted/missing?apikey=${RADARR_KEY}&page=1&pageSize=1" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('totalRecords',0))" > "$TMPDIR/radarr_missing" 2>/dev/null || true
) &

# 6. Sonarr data
(
    curl -s --max-time 3 "http://localhost:8989/api/v3/series?apikey=${SONARR_KEY}" 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" > "$TMPDIR/sonarr_series" 2>/dev/null || true
) &
(
    curl -s --max-time 3 "http://localhost:8989/api/v3/queue?apikey=${SONARR_KEY}&page=1&pageSize=1" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('totalRecords',0))" > "$TMPDIR/sonarr_queue" 2>/dev/null || true
) &
(
    curl -s --max-time 3 "http://localhost:8989/api/v3/wanted/missing?apikey=${SONARR_KEY}&page=1&pageSize=1" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('totalRecords',0))" > "$TMPDIR/sonarr_missing" 2>/dev/null || true
) &

# 7. Lidarr data
(
    curl -s --max-time 3 "http://localhost:8686/api/v1/artist?apikey=${LIDARR_KEY}" 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" > "$TMPDIR/lidarr_artists" 2>/dev/null || true
) &

# 8. Prowlarr indexers
(
    curl -s --max-time 3 "http://localhost:9696/api/v1/indexer?apikey=${PROWLARR_KEY}" 2>/dev/null | \
        python3 -c "
import sys,json
d=json.load(sys.stdin)
total=len(d)
enabled=sum(1 for x in d if x.get('enable',False))
print(f'{enabled}|{total}')
" > "$TMPDIR/prowlarr_indexers" 2>/dev/null || true
) &

# 9. Bazarr badges
(
    if [ -n "$BAZARR_KEY" ]; then
        curl -s --max-time 3 "http://localhost:6767/api/badges?apikey=${BAZARR_KEY}" 2>/dev/null | \
            python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'{d.get(\"episodes\",0)}|{d.get(\"movies\",0)}')
" > "$TMPDIR/bazarr_badges" 2>/dev/null || true
    fi
) &

# 10. Jellyfin system info
(
    curl -s --max-time 3 "http://localhost:8096/System/Info/Public" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Version','?'))" > "$TMPDIR/jellyfin_ver" 2>/dev/null || true
) &

# 11. Transmission
(
    # Session ID dance
    headers=$(curl -s -o /dev/null -D - --max-time 3 http://localhost:9091/transmission/rpc 2>/dev/null || true)
    sid=""
    while IFS= read -r line; do
        if [[ "$line" == X-Transmission-Session-Id:* ]]; then
            sid="${line#X-Transmission-Session-Id: }"
            sid="${sid%%$'\r'}"
            sid="${sid%% }"
        fi
    done <<< "$headers"
    if [ -n "$sid" ]; then
        # Session stats
        curl -s --max-time 3 \
            -H "X-Transmission-Session-Id: $sid" \
            -d '{"method":"session-stats"}' \
            http://localhost:9091/transmission/rpc 2>/dev/null > "$TMPDIR/trans_stats" || true

        # Torrent list
        curl -s --max-time 3 \
            -H "X-Transmission-Session-Id: $sid" \
            -d '{"method":"torrent-get","arguments":{"fields":["name","status","percentDone","rateDownload","rateUpload","eta","uploadRatio","sizeWhenDone","leftUntilDone"]}}' \
            http://localhost:9091/transmission/rpc 2>/dev/null > "$TMPDIR/trans_torrents" || true
    fi
) &

# 12. SABnzbd
(
    if [ -n "$SAB_KEY" ]; then
        curl -s --max-time 3 \
            "http://localhost:8080/api?mode=queue&apikey=${SAB_KEY}&output=json" 2>/dev/null > "$TMPDIR/sab_queue" || true
    fi
) &

# 13. Recent imports (Radarr + Sonarr history)
(
    curl -s --max-time 3 \
        "http://localhost:7878/api/v3/history?apikey=${RADARR_KEY}&page=1&pageSize=5&sortKey=date&sortDirection=descending" 2>/dev/null | \
        python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in d.get('records',[]):
    if r.get('eventType') in ('downloadFolderImported','movieFileRenamed'):
        title=r.get('sourceTitle','?')[:60]
        date=r.get('date','')
        print(f'{title}|{date}|Radarr')
" > "$TMPDIR/radarr_history" 2>/dev/null || true
) &
(
    curl -s --max-time 3 \
        "http://localhost:8989/api/v3/history?apikey=${SONARR_KEY}&page=1&pageSize=5&sortKey=date&sortDirection=descending" 2>/dev/null | \
        python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in d.get('records',[]):
    if r.get('eventType') in ('downloadFolderImported','episodeFileRenamed'):
        title=r.get('sourceTitle','?')[:60]
        date=r.get('date','')
        print(f'{title}|{date}|Sonarr')
" > "$TMPDIR/sonarr_history" 2>/dev/null || true
) &

# ── Wait for ALL background jobs ─────────────────────────────────────────────

wait

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2: PARSE ALL RESULTS
# ══════════════════════════════════════════════════════════════════════════════

# Container states
declare -A CTR_STATE
if [ -f "$TMPDIR/containers" ]; then
    while IFS='|' read -r cname cstate; do
        [ -z "$cname" ] && continue
        CTR_STATE["$cname"]="$cstate"
    done < "$TMPDIR/containers"
fi

# Count running containers
running_count=0
total_expected=0
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r sname _ _ <<< "$entry"
    # Skip profile services that aren't active
    case "$sname" in
        lazylibrarian|kavita|audiobookshelf)
            echo ",$PROFILES," | grep -q ",$sname," || continue
            ;;
    esac
    total_expected=$((total_expected + 1))
    [ "${CTR_STATE[$sname]:-}" = "running" ] && running_count=$((running_count + 1))
done

# Health check results
declare -A HC_STATUS  # healthy|slow|down
declare -A HC_MS
for svc in "${!HEALTH_URLS[@]}"; do
    if [ -f "$TMPDIR/health_${svc}" ]; then
        IFS='|' read -r code expected ms < "$TMPDIR/health_${svc}"
        if [ "$code" = "$expected" ]; then
            if [ "${ms:-0}" -gt 1000 ]; then
                HC_STATUS[$svc]="slow"
            else
                HC_STATUS[$svc]="healthy"
            fi
        else
            HC_STATUS[$svc]="down"
        fi
        HC_MS[$svc]="${ms:-0}"
    else
        HC_STATUS[$svc]="down"
        HC_MS[$svc]="0"
    fi
done

# VPN data
vpn_connected=false
vpn_country=""
vpn_ip=""
if [ -f "$TMPDIR/vpn" ] && [ -s "$TMPDIR/vpn" ]; then
    vpn_country=$(python3 -c "import sys,json; d=json.load(open('$TMPDIR/vpn')); print(d.get('country','??'))" 2>/dev/null || true)
    vpn_ip=$(python3 -c "import sys,json; d=json.load(open('$TMPDIR/vpn')); print(d.get('ip',''))" 2>/dev/null || true)
    [ -n "$vpn_ip" ] && vpn_connected=true
fi

# Disk data
disk_pct=0
disk_free=""
disk_total=""
if [ -f "$TMPDIR/disk" ] && [ -s "$TMPDIR/disk" ]; then
    IFS='|' read -r d_total d_used d_avail d_pct < "$TMPDIR/disk"
    disk_pct="${d_pct%%%}"
    # Convert 1K blocks to human readable
    disk_free=$(awk "BEGIN { gb=${d_avail:-0}/1048576; if(gb>=1024) printf \"%.1fT\",gb/1024; else printf \"%.0fG\",gb }")
    disk_total=$(awk "BEGIN { gb=${d_total:-0}/1048576; if(gb>=1024) printf \"%.1fT\",gb/1024; else printf \"%.0fG\",gb }")
fi

# Library data
radarr_movies=$(cat "$TMPDIR/radarr_movies" 2>/dev/null || echo "?")
radarr_queue=$(cat "$TMPDIR/radarr_queue" 2>/dev/null || echo "0")
radarr_missing=$(cat "$TMPDIR/radarr_missing" 2>/dev/null || echo "0")
sonarr_series=$(cat "$TMPDIR/sonarr_series" 2>/dev/null || echo "?")
sonarr_queue=$(cat "$TMPDIR/sonarr_queue" 2>/dev/null || echo "0")
sonarr_missing=$(cat "$TMPDIR/sonarr_missing" 2>/dev/null || echo "0")
lidarr_artists=$(cat "$TMPDIR/lidarr_artists" 2>/dev/null || echo "?")

# Prowlarr indexers
prowlarr_enabled="?"
prowlarr_total="?"
if [ -f "$TMPDIR/prowlarr_indexers" ] && [ -s "$TMPDIR/prowlarr_indexers" ]; then
    IFS='|' read -r prowlarr_enabled prowlarr_total < "$TMPDIR/prowlarr_indexers"
fi

# Bazarr badges
bazarr_ep="0"
bazarr_mov="0"
if [ -f "$TMPDIR/bazarr_badges" ] && [ -s "$TMPDIR/bazarr_badges" ]; then
    IFS='|' read -r bazarr_ep bazarr_mov < "$TMPDIR/bazarr_badges"
fi

# Jellyfin version
jellyfin_ver=$(cat "$TMPDIR/jellyfin_ver" 2>/dev/null || echo "?")

# Transmission data
trans_dl_speed=0
trans_ul_speed=0
declare -a TRANS_DL_NAMES=() TRANS_DL_PCT=() TRANS_DL_SIZE=() TRANS_DL_ETA=()
declare -a TRANS_SEED_NAMES=() TRANS_SEED_RATIO=()
trans_active_dl=0
trans_active_seed=0

if [ -f "$TMPDIR/trans_stats" ] && [ -s "$TMPDIR/trans_stats" ]; then
    eval "$(python3 -c "
import sys,json
d=json.load(open('$TMPDIR/trans_stats'))
a=d.get('arguments',{})
print(f'trans_dl_speed={a.get(\"downloadSpeed\",0)}')
print(f'trans_ul_speed={a.get(\"uploadSpeed\",0)}')
" 2>/dev/null || true)"
fi

if [ -f "$TMPDIR/trans_torrents" ] && [ -s "$TMPDIR/trans_torrents" ]; then
    eval "$(python3 -c "
import sys,json
d=json.load(open('$TMPDIR/trans_torrents'))
torrents=d.get('arguments',{}).get('torrents',[])
dl_count=0
seed_count=0
for t in torrents:
    status=t.get('status',0)
    name=t.get('name','?')[:55]
    pct=int(t.get('percentDone',0)*100)
    if status==4:  # downloading
        dl_count+=1
        if dl_count<=3:
            size=t.get('sizeWhenDone',0)
            eta=t.get('eta',-1)
            # Sanitize name for shell
            name=name.replace(\"'\",\"\").replace('\"','').replace('$','').replace('\\\\','')
            print(f\"TRANS_DL_NAMES+=(\\\"{name}\\\")\")
            print(f\"TRANS_DL_PCT+=({pct})\")
            print(f\"TRANS_DL_SIZE+=({size})\")
            print(f\"TRANS_DL_ETA+=({eta})\")
    elif status==6:  # seeding
        seed_count+=1
        if seed_count<=2:
            ratio=round(t.get('uploadRatio',0),1)
            name=name.replace(\"'\",\"\").replace('\"','').replace('$','').replace('\\\\','')
            print(f\"TRANS_SEED_NAMES+=(\\\"{name}\\\")\")
            print(f\"TRANS_SEED_RATIO+=({ratio})\")
print(f'trans_active_dl={dl_count}')
print(f'trans_active_seed={seed_count}')
" 2>/dev/null || true)"
fi

# SABnzbd data
sab_dl_speed=""
sab_active=0
declare -a SAB_DL_NAMES=() SAB_DL_PCT=() SAB_DL_LEFT=() SAB_DL_ETA=()

if [ -f "$TMPDIR/sab_queue" ] && [ -s "$TMPDIR/sab_queue" ]; then
    eval "$(python3 -c "
import sys,json
d=json.load(open('$TMPDIR/sab_queue'))
q=d.get('queue',{})
speed=q.get('speed','0 B')
print(f\"sab_dl_speed='{speed}'\")
slots=q.get('slots',[])
dl_count=0
for s in slots:
    if s.get('status')=='Downloading':
        dl_count+=1
        if dl_count<=2:
            name=s.get('filename','?')[:55]
            pct=int(float(s.get('percentage',0)))
            left=s.get('sizeleft','?')
            eta=s.get('timeleft','?')
            name=name.replace(\"'\",\"\").replace('\"','').replace('$','').replace('\\\\','')
            print(f\"SAB_DL_NAMES+=(\\\"{name}\\\")\")
            print(f\"SAB_DL_PCT+=({pct})\")
            print(f\"SAB_DL_LEFT+=('{left}')\")
            print(f\"SAB_DL_ETA+=('{eta}')\")
print(f'sab_active={dl_count}')
" 2>/dev/null || true)"
fi

# Recent imports
declare -a RECENT_NAMES=() RECENT_DATES=() RECENT_SOURCES=()
for histfile in "$TMPDIR/radarr_history" "$TMPDIR/sonarr_history"; do
    if [ -f "$histfile" ] && [ -s "$histfile" ]; then
        while IFS='|' read -r rname rdate rsource; do
            [ -z "$rname" ] && continue
            RECENT_NAMES+=("$rname")
            RECENT_DATES+=("$rdate")
            RECENT_SOURCES+=("$rsource")
        done < "$histfile"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 3: RENDER
# ══════════════════════════════════════════════════════════════════════════════

show_logo_static
show_header "Dashboard"

# ── Timestamp (right-aligned) ─────────────────────────────────────────────────

timestamp="Last updated: $(date '+%H:%M:%S')"
ts_len=${#timestamp}
ts_pad=$(( TERM_W - ts_len - 2 ))
(( ts_pad < 0 )) && ts_pad=0
printf "%*s${S_DIM}${C_OVERLAY0}%s${S_RESET}\n" "$ts_pad" "" "$timestamp"
echo ""

# ── System Bar ────────────────────────────────────────────────────────────────

# VPN segment
if $vpn_connected; then
    vpn_seg="${C_GREEN}●${S_RESET} ${C_TEXT}VPN: Connected${S_RESET} ${C_OVERLAY0}(${vpn_country})${S_RESET}"
else
    vpn_seg="${C_RED}●${S_RESET} ${C_RED}VPN: Down${S_RESET}"
fi

# Disk segment
disk_bar_w=10
if [ -n "$disk_pct" ] && [ "$disk_pct" -gt 0 ] 2>/dev/null; then
    disk_seg="$(smooth_bar "$disk_pct" "$disk_bar_w" "$C_SAPPHIRE" "$C_SURFACE0") ${C_TEXT}${disk_pct}%%${S_RESET} ${C_OVERLAY0}(${disk_free} free)${S_RESET}"
else
    disk_seg="${C_OVERLAY0}Disk: unavailable${S_RESET}"
fi

# Docker segment
if [ "$running_count" -eq "$total_expected" ]; then
    docker_color="$C_GREEN"
else
    docker_color="$C_YELLOW"
fi
docker_seg="${docker_color}${S_BOLD}${running_count}${S_RESET}${C_OVERLAY0}/${total_expected} up${S_RESET}"

sep="${C_SURFACE1} ${S_DIM}|${S_RESET} "

printf "  ${vpn_seg}${sep}${C_SUBTEXT0}Disk:${S_RESET} ${disk_seg}${sep}${C_SUBTEXT0}Docker:${S_RESET} ${docker_seg}\n"
echo ""

# ── Service Group Definitions ─────────────────────────────────────────────────

GROUP_ORDER=("network" "indexers" "media" "streaming" "books" "gaming")

declare -A GROUP_LABELS GROUP_COLORS GROUP_MEMBERS
GROUP_LABELS[network]="NETWORK & DOWNLOADS"
GROUP_LABELS[indexers]="INDEXERS"
GROUP_LABELS[media]="MEDIA MANAGERS"
GROUP_LABELS[streaming]="STREAMING"
GROUP_LABELS[books]="BOOKS & AUDIO"
GROUP_LABELS[gaming]="GAMING"

GROUP_COLORS[network]="$C_GREEN"
GROUP_COLORS[indexers]="$C_YELLOW"
GROUP_COLORS[media]="$C_BLUE"
GROUP_COLORS[streaming]="$C_MAUVE"
GROUP_COLORS[books]="$C_TEAL"
GROUP_COLORS[gaming]="$C_FLAMINGO"

GROUP_MEMBERS[network]="gluetun transmission sabnzbd"
GROUP_MEMBERS[indexers]="prowlarr flaresolverr"
GROUP_MEMBERS[media]="radarr sonarr lidarr bazarr"
GROUP_MEMBERS[streaming]="jellyfin seerr"
GROUP_MEMBERS[books]="lazylibrarian kavita audiobookshelf"
GROUP_MEMBERS[gaming]="questarr"

# Service label lookup
declare -A SVC_LABELS SVC_PORTS
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r sname sport slabel <<< "$entry"
    SVC_LABELS[$sname]="$slabel"
    SVC_PORTS[$sname]="$sport"
done

# ── Render Service Groups ────────────────────────────────────────────────────

render_group_header() {
    local label="$1" color="$2" state="${3:-neutral}"
    local dashes=""
    local label_len=${#label}
    local extra=0
    [ "$state" = "healthy" ] && extra=2
    local dash_count=$(( TERM_W - label_len - 8 - extra ))
    (( dash_count < 6 )) && dash_count=6
    local i
    for (( i=0; i<dash_count; i+=3 )); do
        dashes+="── "
    done
    case "$state" in
        healthy) printf "  ${color}${S_BOLD}▸ %s ✓${S_RESET}  ${C_SURFACE1}%s${S_RESET}\n" "$label" "$dashes" ;;
        mixed)   printf "  ${C_YELLOW}${S_BOLD}▸ %s${S_RESET}  ${C_SURFACE1}%s${S_RESET}\n" "$label" "$dashes" ;;
        down)    printf "  ${C_RED}${S_BOLD}▸ %s${S_RESET}  ${C_SURFACE1}%s${S_RESET}\n" "$label" "$dashes" ;;
        *)       printf "  ${color}${S_BOLD}▸ %s${S_RESET}  ${C_SURFACE1}%s${S_RESET}\n" "$label" "$dashes" ;;
    esac
}

# Compute group health state: "healthy" | "mixed" | "down"
# Usage: compute_group_state "svc1 svc2 svc3"
compute_group_state() {
    local members="$1"
    local g_total=0 g_healthy=0
    for svc in $members; do
        # Skip inactive profile services
        case "$svc" in
            lazylibrarian|kavita|audiobookshelf)
                profile_active "$svc" || continue
                ;;
            questarr)
                [ "${CTR_STATE[$svc]:-}" = "running" ] || continue
                ;;
        esac
        g_total=$((g_total + 1))
        local ctr="${CTR_STATE[$svc]:-not found}"
        local hc="${HC_STATUS[$svc]:-down}"
        if [ "$ctr" = "running" ] && { [ "$hc" = "healthy" ] || [ "$hc" = "slow" ]; }; then
            g_healthy=$((g_healthy + 1))
        fi
    done
    if [ "$g_total" -eq 0 ]; then
        echo "neutral"
    elif [ "$g_healthy" -eq "$g_total" ]; then
        echo "healthy"
    elif [ "$g_healthy" -eq 0 ]; then
        echo "down"
    else
        echo "mixed"
    fi
}

render_service_row() {
    local svc="$1"
    local label="${SVC_LABELS[$svc]:-$svc}"
    local port="${SVC_PORTS[$svc]:-}"
    local status="${HC_STATUS[$svc]:-down}"
    local ms="${HC_MS[$svc]:-0}"
    local ctr_state="${CTR_STATE[$svc]:-not found}"

    # Determine dot and status display
    local dot status_word status_color ms_str
    if [ "$ctr_state" != "running" ]; then
        dot="${C_RED}●${S_RESET}"
        status_word="down"
        status_color="$C_RED"
        ms_str=""
    elif [ "$status" = "healthy" ]; then
        dot="${C_GREEN}●${S_RESET}"
        status_word="healthy"
        status_color="$C_GREEN"
        ms_str="${C_OVERLAY0}${ms}ms${S_RESET}"
    elif [ "$status" = "slow" ]; then
        dot="${C_YELLOW}●${S_RESET}"
        status_word="slow"
        status_color="$C_YELLOW"
        ms_str="${C_YELLOW}${ms}ms${S_RESET}"
    else
        dot="${C_RED}●${S_RESET}"
        status_word="unreachable"
        status_color="$C_RED"
        ms_str=""
    fi

    local port_str=""
    if [ -n "$port" ]; then
        port_str="${C_OVERLAY0}:${port}${S_RESET}"
    fi

    # Calculate right-aligned ms position
    local ms_display=""
    if [ -n "$ms_str" ]; then
        ms_display="$ms_str"
    fi

    printf "    %b  ${C_TEXT}${S_BOLD}%-16s${S_RESET} ${C_SUBTEXT0}%-18s${S_RESET} %-8b ${status_color}%-10s${S_RESET}  %b\n" \
        "$dot" "$svc" "$label" "$port_str" "$status_word" "$ms_display"
}

render_context_line() {
    local text="$1"
    printf "    ${C_OVERLAY0}%-4s${S_RESET}${C_SUBTEXT0}%s${S_RESET}\n" "  ↳" "$text"
}

# ── GROUP: NETWORK & DOWNLOADS ───────────────────────────────────────────────

_state=$(compute_group_state "${GROUP_MEMBERS[network]}")
render_group_header "${GROUP_LABELS[network]}" "${GROUP_COLORS[network]}" "$_state"
for svc in ${GROUP_MEMBERS[network]}; do
    render_service_row "$svc"
done

# Context: download speeds
trans_dl_h=$(human_speed "$trans_dl_speed")
trans_ul_h=$(human_speed "$trans_ul_speed")
ctx_parts="▼ ${trans_dl_h}  ▲ ${trans_ul_h}"
active_parts=""
[ "$trans_active_dl" -gt 0 ] && active_parts="${trans_active_dl} torrent$([ "$trans_active_dl" -gt 1 ] && echo "s" || true)"
[ "$sab_active" -gt 0 ] && {
    [ -n "$active_parts" ] && active_parts+=", "
    active_parts+="${sab_active} usenet"
}
[ -n "$active_parts" ] && ctx_parts+="  |  Active: ${active_parts}"
render_context_line "$ctx_parts"
echo ""
sleep 0.05

# ── GROUP: INDEXERS ──────────────────────────────────────────────────────────

_state=$(compute_group_state "${GROUP_MEMBERS[indexers]}")
render_group_header "${GROUP_LABELS[indexers]}" "${GROUP_COLORS[indexers]}" "$_state"
for svc in ${GROUP_MEMBERS[indexers]}; do
    render_service_row "$svc"
done
render_context_line "${prowlarr_enabled}/${prowlarr_total} indexers active"
echo ""
sleep 0.05

# ── GROUP: MEDIA MANAGERS ────────────────────────────────────────────────────

_state=$(compute_group_state "${GROUP_MEMBERS[media]}")
render_group_header "${GROUP_LABELS[media]}" "${GROUP_COLORS[media]}" "$_state"
for svc in ${GROUP_MEMBERS[media]}; do
    render_service_row "$svc"
done

# Context: library counts + queue + missing
total_queue=$(( ${radarr_queue:-0} + ${sonarr_queue:-0} ))
lib_line="Library: ${C_TEXT}${radarr_movies}${C_SUBTEXT0} movies  ${C_TEXT}${sonarr_series}${C_SUBTEXT0} series  ${C_TEXT}${lidarr_artists}${C_SUBTEXT0} artists"
queue_part=""
[ "$total_queue" -gt 0 ] && queue_part="  |  Queue: ${C_PEACH}${total_queue}${C_SUBTEXT0}"
missing_parts=""
[ "${radarr_missing:-0}" -gt 0 ] && missing_parts="  |  Missing: ${C_YELLOW}${radarr_missing}${C_SUBTEXT0} movies"
[ "${sonarr_missing:-0}" -gt 0 ] && {
    if [ -n "$missing_parts" ]; then
        missing_parts+=", ${C_YELLOW}${sonarr_missing}${C_SUBTEXT0} episodes"
    else
        missing_parts="  |  Missing: ${C_YELLOW}${sonarr_missing}${C_SUBTEXT0} episodes"
    fi
}
printf "    ${C_OVERLAY0}  ↳${S_RESET} ${C_SUBTEXT0}${lib_line}${queue_part}${missing_parts}${S_RESET}\n"
echo ""
sleep 0.05

# ── GROUP: STREAMING ─────────────────────────────────────────────────────────

_state=$(compute_group_state "${GROUP_MEMBERS[streaming]}")
render_group_header "${GROUP_LABELS[streaming]}" "${GROUP_COLORS[streaming]}" "$_state"
for svc in ${GROUP_MEMBERS[streaming]}; do
    render_service_row "$svc"
done
# Context: Jellyfin version + subtitle backlog
stream_ctx="Jellyfin v${jellyfin_ver}"
if [ "${bazarr_ep:-0}" -gt 0 ] || [ "${bazarr_mov:-0}" -gt 0 ]; then
    stream_ctx+="  |  Subs needed: ${C_YELLOW}${bazarr_ep}${C_SUBTEXT0} episodes, ${C_YELLOW}${bazarr_mov}${C_SUBTEXT0} movies"
fi
printf "    ${C_OVERLAY0}  ↳${S_RESET} ${C_SUBTEXT0}${stream_ctx}${S_RESET}\n"
echo ""
sleep 0.05

# ── GROUP: BOOKS & AUDIO (if active) ────────────────────────────────────────

books_has_any=false
for svc in ${GROUP_MEMBERS[books]}; do
    if profile_active "$svc"; then
        books_has_any=true
        break
    fi
done

if $books_has_any; then
    _state=$(compute_group_state "${GROUP_MEMBERS[books]}")
    render_group_header "${GROUP_LABELS[books]}" "${GROUP_COLORS[books]}" "$_state"
    for svc in ${GROUP_MEMBERS[books]}; do
        profile_active "$svc" && render_service_row "$svc"
    done
    echo ""
    sleep 0.05
fi

# ── GROUP: GAMING (if running) ───────────────────────────────────────────────

if [ "${CTR_STATE[questarr]:-}" = "running" ]; then
    _state=$(compute_group_state "${GROUP_MEMBERS[gaming]}")
    render_group_header "${GROUP_LABELS[gaming]}" "${GROUP_COLORS[gaming]}" "$_state"
    for svc in ${GROUP_MEMBERS[gaming]}; do
        render_service_row "$svc"
    done
    echo ""
    sleep 0.05
fi

# ── ACTIVITY PANEL ───────────────────────────────────────────────────────────

render_group_header "ACTIVITY" "$C_PEACH" "neutral"

has_activity=false

# Active Transmission downloads
for (( i=0; i<${#TRANS_DL_NAMES[@]}; i++ )); do
    has_activity=true
    name="${TRANS_DL_NAMES[$i]}"
    pct="${TRANS_DL_PCT[$i]}"
    size="${TRANS_DL_SIZE[$i]}"
    eta="${TRANS_DL_ETA[$i]}"

    size_h=$(human_size "$size")
    eta_h=$(human_eta "$eta")

    # Truncate name for display
    dname="$name"
    if (( ${#dname} > 48 )); then
        dname="${dname:0:45}..."
    fi

    printf "    ${C_PEACH}▼${S_RESET} ${C_TEXT}%s${S_RESET}\n" "$dname"
    printf "      "
    smooth_bar "$pct" 20 "$C_SAPPHIRE" "$C_SURFACE0"
    printf "  ${C_TEXT}%3d%%${S_RESET}   ${C_SUBTEXT0}%s${S_RESET}   ${C_OVERLAY0}ETA %s${S_RESET}\n" "$pct" "$size_h" "$eta_h"
done

# Active SABnzbd downloads
for (( i=0; i<${#SAB_DL_NAMES[@]}; i++ )); do
    has_activity=true
    name="${SAB_DL_NAMES[$i]}"
    pct="${SAB_DL_PCT[$i]}"
    left="${SAB_DL_LEFT[$i]}"
    eta="${SAB_DL_ETA[$i]}"

    dname="$name"
    if (( ${#dname} > 48 )); then
        dname="${dname:0:45}..."
    fi

    printf "    ${C_PEACH}▼${S_RESET} ${C_TEXT}%s${S_RESET}\n" "$dname"
    printf "      "
    smooth_bar "$pct" 20 "$C_TEAL" "$C_SURFACE0"
    printf "  ${C_TEXT}%3d%%${S_RESET}   ${C_SUBTEXT0}%s left${S_RESET}   ${C_OVERLAY0}ETA %s${S_RESET}\n" "$pct" "$left" "$eta"
done

# Seeding
for (( i=0; i<${#TRANS_SEED_NAMES[@]}; i++ )); do
    has_activity=true
    name="${TRANS_SEED_NAMES[$i]}"
    ratio="${TRANS_SEED_RATIO[$i]}"
    dname="$name"
    if (( ${#dname} > 55 )); then
        dname="${dname:0:52}..."
    fi
    printf "    ${C_GREEN}▲${S_RESET} ${C_SUBTEXT0}%-58s${S_RESET} ${C_OVERLAY0}ratio %s${S_RESET}   ${C_GREEN}seeding${S_RESET}\n" "$dname" "$ratio"
done

# Recent imports
shown_recent=0
for (( i=0; i<${#RECENT_NAMES[@]}; i++ )); do
    (( shown_recent >= 2 )) && break
    has_activity=true
    name="${RECENT_NAMES[$i]}"
    rdate="${RECENT_DATES[$i]}"
    source="${RECENT_SOURCES[$i]}"

    # Compute relative time
    rel_time=""
    if [ -n "$rdate" ]; then
        # Parse ISO date
        import_epoch=$(date -d "${rdate}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${rdate%%.*}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [ "$import_epoch" -gt 0 ] 2>/dev/null; then
            diff_secs=$(( now_epoch - import_epoch ))
            if [ "$diff_secs" -lt 3600 ]; then
                rel_time="$(( diff_secs / 60 ))m ago"
            elif [ "$diff_secs" -lt 86400 ]; then
                rel_time="$(( diff_secs / 3600 ))h ago"
            else
                rel_time="$(( diff_secs / 86400 ))d ago"
            fi
        fi
    fi

    dname="$name"
    if (( ${#dname} > 48 )); then
        dname="${dname:0:45}..."
    fi

    printf "    ${C_SAPPHIRE}◆${S_RESET} ${C_SUBTEXT0}%-50s${S_RESET} ${C_OVERLAY0}%-10s${S_RESET}  ${C_BLUE}%s${S_RESET}\n" "$dname" "${rel_time:-recently}" "$source"
    shown_recent=$((shown_recent + 1))
done

if ! $has_activity; then
    printf "    ${S_DIM}${S_ITALIC}${C_OVERLAY0}No active transfers. Library is idle.${S_RESET}\n"
fi

echo ""

# ── Footer ────────────────────────────────────────────────────────────────────

printf "  ${C_SURFACE1}"
for (( i=0; i<TERM_W-4; i++ )); do printf "─"; done
printf "${S_RESET}\n"

printf "  ${C_OVERLAY0}${S_DIM}arr status${S_RESET}${C_SURFACE1} | ${S_RESET}${C_OVERLAY0}${S_DIM}arr downloads${S_RESET}${C_SURFACE1} | ${S_RESET}${C_OVERLAY0}${S_DIM}arr vpn${S_RESET}${C_SURFACE1} | ${S_RESET}${C_OVERLAY0}${S_DIM}arr logs <svc>${S_RESET}\n"
echo ""
