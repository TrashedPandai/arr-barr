#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
require_curl

show_logo_static
show_header "Arr Media Stack  —  Health Check"

# ── Health Endpoints ──────────────────────────────────────────────────────────
# Format: service|url|expected_http_code

HEALTH_ENDPOINTS=(
    "gluetun|http://localhost:8000/v1/openvpn/status|302"
    "transmission|http://localhost:9091/transmission/rpc|409"
    "sabnzbd|http://localhost:8080/api?mode=version&output=json|200"
    "prowlarr|http://localhost:9696/ping|200"
    "flaresolverr|http://localhost:8191/health|200"
    "radarr|http://localhost:7878/ping|200"
    "sonarr|http://localhost:8989/ping|200"
    "lidarr|http://localhost:8686/ping|200"
    "bazarr|http://localhost:6767/ping|200"
    "jellyfin|http://localhost:8096/System/Info/Public|200"
    "seerr|http://localhost:5055/api/v1/status|200"
    "lazylibrarian|http://localhost:5299/api?cmd=getVersion|200"
    "kavita|http://localhost:5004/api/health|200"
    "audiobookshelf|http://localhost:13378/healthcheck|200"
    "questarr|http://localhost:5002/|200"
)

# Build a lookup from SERVICES array for labels
declare -A SVC_LABELS
for entry in "${SERVICES[@]}"; do
    IFS="|" read -r sname sport slabel <<< "$entry"
    SVC_LABELS["$sname"]="$slabel"
done

# ── Parallel Health Checks ────────────────────────────────────────────────────

TMPDIR_HEALTH=$(mktemp -d /tmp/arr-health-XXXXXX)
cleanup_health() { rm -rf "$TMPDIR_HEALTH"; }
trap cleanup_health EXIT

section_header "SERVICE HEALTH" "$C_SAPPHIRE"
echo ""

# Header row
printf "    ${C_OVERLAY0}%-3s %-18s %-10s %s${S_RESET}\n" "" "SERVICE" "TIME" "ENDPOINT"
divider 58
echo ""

# Launch all curls in parallel, writing results to temp files
for ep in "${HEALTH_ENDPOINTS[@]}"; do
    IFS="|" read -r svc url expected <<< "$ep"
    (
        start_ms=$(date +%s%N 2>/dev/null || echo "0")
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 --max-time 2 "$url" 2>/dev/null || echo "000")
        end_ms=$(date +%s%N 2>/dev/null || echo "0")

        # Calculate elapsed ms
        if [ "$start_ms" != "0" ] && [ "$end_ms" != "0" ]; then
            elapsed_ns=$(( end_ms - start_ms ))
            elapsed_ms=$(( elapsed_ns / 1000000 ))
        else
            elapsed_ms=0
        fi

        echo "${svc}|${http_code}|${expected}|${elapsed_ms}|${url}" > "$TMPDIR_HEALTH/${svc}.result"
    ) &
done

# Wait for all background curls
wait

# ── Display Results ───────────────────────────────────────────────────────────

healthy=0
unhealthy=0
total=${#HEALTH_ENDPOINTS[@]}

for ep in "${HEALTH_ENDPOINTS[@]}"; do
    IFS="|" read -r svc url expected <<< "$ep"
    result_file="$TMPDIR_HEALTH/${svc}.result"

    if [ -f "$result_file" ]; then
        IFS="|" read -r r_svc r_code r_expected r_ms r_url < "$result_file"
        display_name="$svc"

        # Format response time
        if [ "$r_ms" -gt 0 ]; then
            time_str="${r_ms}ms"
        else
            time_str="--"
        fi

        # Determine status
        if [ "$r_code" = "$r_expected" ]; then
            healthy=$((healthy + 1))
            dot="$(dot_up)"
            time_color="$C_GREEN"
            if [ "$r_ms" -gt 1000 ]; then
                dot="$(dot_warn)"
                time_color="$C_YELLOW"
            fi
        elif [ "$r_code" = "000" ]; then
            unhealthy=$((unhealthy + 1))
            dot="$(dot_down)"
            time_str="timeout"
            time_color="$C_RED"
        else
            unhealthy=$((unhealthy + 1))
            dot="$(dot_down)"
            time_str="${time_str} (${r_code})"
            time_color="$C_RED"
        fi

        # Get port + path for display
        port_path="${r_url#http://localhost:}"

        printf "    %b  ${C_TEXT}%-18s${S_RESET} ${time_color}%-10s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" \
            "$dot" "$display_name" "$time_str" ":${port_path}"
    else
        unhealthy=$((unhealthy + 1))
        printf "    $(dot_down)  ${C_RED}%-18s${S_RESET} ${C_RED}%-10s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" \
            "$svc" "error" "$url"
    fi
    sleep 0.02
done

echo ""
divider 58
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────

if [ "$healthy" -eq "$total" ]; then
    msg_success "${healthy}/${total} services healthy"
elif [ "$unhealthy" -gt 0 ]; then
    printf "    ${C_GREEN}${S_BOLD}%d${S_RESET}${C_SUBTEXT0} healthy${S_RESET}" "$healthy"
    printf "    ${C_RED}${S_BOLD}%d${S_RESET}${C_SUBTEXT0} unreachable${S_RESET}\n" "$unhealthy"
    echo ""
    msg_dim "    Tip: Unreachable services may be disabled via profiles or stopped."
    msg_dim "    Run: arr status  for container-level detail."
fi
echo ""
