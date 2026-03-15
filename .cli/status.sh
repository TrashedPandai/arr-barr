#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env
require_curl

# ══════════════════════════════════════════════════════════════════════════════
#  arr status — quick pulse check (merged health + container states)
# ══════════════════════════════════════════════════════════════════════════════

section_header "STATUS" "$C_SAPPHIRE"
echo ""

# ── Profiles ──────────────────────────────────────────────────────────────────

profiles="$(grep '^COMPOSE_PROFILES=' "$ARR_HOME/.env" 2>/dev/null | cut -d= -f2- || true)"

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

# ── Health Endpoints ──────────────────────────────────────────────────────────

declare -A HEALTH_URLS
HEALTH_URLS[gluetun]="http://localhost:8000/v1/openvpn/status|302"
HEALTH_URLS[transmission]="http://localhost:9091/transmission/rpc|409"
HEALTH_URLS[sabnzbd]="http://localhost:8080/api?mode=version&output=json|200"
HEALTH_URLS[prowlarr]="http://localhost:9696/ping|200"
HEALTH_URLS[flaresolverr]="http://localhost:8191/health|200"
HEALTH_URLS[radarr]="http://localhost:7878/ping|200"
HEALTH_URLS[sonarr]="http://localhost:8989/ping|200"
HEALTH_URLS[lidarr]="http://localhost:8686/ping|200"
HEALTH_URLS[bazarr]="http://localhost:6767/ping|200"
HEALTH_URLS[jellyfin]="http://localhost:8096/System/Info/Public|200"
HEALTH_URLS[seerr]="http://localhost:5055/api/v1/status|200"
HEALTH_URLS[lazylibrarian]="http://localhost:5299/api?cmd=getVersion|200"
HEALTH_URLS[kavita]="http://localhost:5004/api/health|200"
HEALTH_URLS[audiobookshelf]="http://localhost:13378/healthcheck|200"
HEALTH_URLS[questarr]="http://localhost:5002/|200"

# ── Parallel data fetch ──────────────────────────────────────────────────────

TMPDIR_STATUS=$(mktemp -d /tmp/arr-status-XXXXXX)
cleanup() { rm -rf "$TMPDIR_STATUS"; }
trap cleanup EXIT INT TERM

# Container states
$DOCKER_CMD ps -a --format '{{.Names}}|{{.State}}' > "$TMPDIR_STATUS/containers" 2>/dev/null &

# Launch all health checks in parallel
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
        echo "${code}|${expected}|${ms}" > "$TMPDIR_STATUS/health_${svc}"
    ) &
done

wait

# ── Parse container states ────────────────────────────────────────────────────

declare -A CTR_STATE
if [ -f "$TMPDIR_STATUS/containers" ]; then
    while IFS='|' read -r cname cstate; do
        [ -z "$cname" ] && continue
        CTR_STATE["$cname"]="$cstate"
    done < "$TMPDIR_STATUS/containers"
fi

# ── Parse health results ─────────────────────────────────────────────────────

declare -A HC_STATUS HC_MS
for svc in "${!HEALTH_URLS[@]}"; do
    if [ -f "$TMPDIR_STATUS/health_${svc}" ]; then
        IFS='|' read -r code expected ms < "$TMPDIR_STATUS/health_${svc}"
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

# ── Render by group ──────────────────────────────────────────────────────────

healthy_count=0
total_checked=0
down_names=()

# Service label lookup
declare -A SVC_LABELS SVC_PORTS
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r sname sport slabel <<< "$entry"
    SVC_LABELS[$sname]="$slabel"
    SVC_PORTS[$sname]="$sport"
done

for gid in "${GROUP_ORDER[@]}"; do
    # Check if any service in group is relevant
    has_svc=false
    for svc in ${GROUP_MEMBERS[$gid]}; do
        case "$svc" in
            lazylibrarian|kavita|audiobookshelf)
                echo ",$profiles," | grep -q ",$svc," && has_svc=true
                [ "${CTR_STATE[$svc]:-}" = "running" ] && has_svc=true
                ;;
            questarr)
                [ "${CTR_STATE[$svc]:-}" = "running" ] && has_svc=true
                ;;
            *)
                has_svc=true
                ;;
        esac
        $has_svc && break
    done
    $has_svc || continue

    printf "  ${GROUP_COLORS[$gid]}${S_DIM}▸ ${GROUP_LABELS[$gid]}${S_RESET}\n"

    for svc in ${GROUP_MEMBERS[$gid]}; do
        # Skip inactive profile services
        case "$svc" in
            lazylibrarian|kavita|audiobookshelf)
                echo ",$profiles," | grep -q ",$svc," || { [ "${CTR_STATE[$svc]:-}" = "running" ] || continue; }
                ;;
            questarr)
                [ "${CTR_STATE[$svc]:-}" = "running" ] || continue
                ;;
        esac

        total_checked=$((total_checked + 1))
        local_status="${HC_STATUS[$svc]:-down}"
        local_ms="${HC_MS[$svc]:-0}"
        local_ctr="${CTR_STATE[$svc]:-not found}"
        local_port="${SVC_PORTS[$svc]:-}"

        # Determine display
        if [ "$local_ctr" != "running" ]; then
            dot="${C_RED}●${S_RESET}"
            word="${C_RED}down${S_RESET}"
            ms_str=""
            down_names+=("$svc")
        elif [ "$local_status" = "healthy" ]; then
            dot="${C_GREEN}●${S_RESET}"
            word="${C_GREEN}healthy${S_RESET}"
            ms_str="${C_OVERLAY0}${local_ms}ms${S_RESET}"
            healthy_count=$((healthy_count + 1))
        elif [ "$local_status" = "slow" ]; then
            dot="${C_YELLOW}●${S_RESET}"
            word="${C_YELLOW}slow${S_RESET}"
            ms_str="${C_YELLOW}${local_ms}ms${S_RESET}"
            healthy_count=$((healthy_count + 1))
        else
            dot="${C_RED}●${S_RESET}"
            word="${C_RED}unreachable${S_RESET}"
            ms_str=""
            down_names+=("$svc")
        fi

        printf "    %b  ${C_TEXT}%-16s${S_RESET}  %b  %b\n" "$dot" "$svc" "$word" "$ms_str"
    done
    echo ""
done

# ── Summary ───────────────────────────────────────────────────────────────────

if [ "$healthy_count" -eq "$total_checked" ]; then
    printf "  ${C_GREEN}${S_BOLD}${healthy_count}/${total_checked}${S_RESET} ${C_SUBTEXT0}healthy${S_RESET}\n"
else
    unhealthy=$((total_checked - healthy_count))
    printf "  ${C_GREEN}${S_BOLD}${healthy_count}/${total_checked}${S_RESET} ${C_SUBTEXT0}healthy${S_RESET}"
    printf "  ${C_RED}${S_BOLD}${unhealthy}${S_RESET} ${C_SUBTEXT0}down:${S_RESET} "
    printf "${C_RED}%s${S_RESET}" "$(IFS=', '; echo "${down_names[*]}")"
    echo ""
    echo ""
    for name in "${down_names[@]}"; do
        msg_dim "    arr logs $name"
    done
fi
echo ""
