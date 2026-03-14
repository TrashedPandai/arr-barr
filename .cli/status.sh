#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

show_logo
show_header "Arr Media Stack  —  Status"

# ── Profiles ──────────────────────────────────────────────────────────────────

ALL_PROFILES=("lazylibrarian|Book Search" "kavita|Book Reader" "audiobookshelf|Audiobooks")
profiles="$(grep '^COMPOSE_PROFILES=' "$ARR_HOME/.env" 2>/dev/null | cut -d= -f2- || true)"

section_header "PROFILES" "$C_MAUVE"
echo ""
echo -e "    ${S_BOLD}${C_LAVENDER}CORE${S_RESET}  ${C_SUBTEXT0}VPN, Downloads, Radarr, Sonarr, Lidarr, Bazarr, Jellyfin, Seerr, QuestArr${S_RESET}"
echo ""
for entry in "${ALL_PROFILES[@]}"; do
    IFS='|' read -r pname pdesc <<< "$entry"
    if echo ",$profiles," | grep -q ",$pname,"; then
        printf "    $(dot_up)  ${S_BOLD}%-17s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "$pname" "$pdesc"
    else
        printf "    ${C_SURFACE2}○${S_RESET}  ${C_OVERLAY0}%-17s %s${S_RESET}\n" "$pname" "$pdesc"
    fi
done
echo ""
msg_dim "    Edit .env to change profiles, then run: arr update"
echo ""

# ── Container Status ─────────────────────────────────────────────────────────

section_header "CONTAINERS" "$C_SAPPHIRE"
echo ""

# Fetch container states with spinner
$DOCKER_CMD ps -a --format '{{.Names}}|{{.State}}' > /tmp/.arr-status-$$ 2>/dev/null &
spin_while $! "Checking containers..."

# Parse results
declare -A CONTAINER_STATES
while IFS='|' read -r cname cstate; do
    [ -z "$cname" ] && continue
    CONTAINER_STATES["$cname"]="$cstate"
done < /tmp/.arr-status-$$
rm -f /tmp/.arr-status-$$

up_count=0
down_count=0
down_names=()

for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name port label <<< "$entry"
    state="${CONTAINER_STATES[$name]:-not found}"

    if [[ "$state" == "running" ]]; then
        up_count=$((up_count + 1))
        if [ -n "$port" ]; then
            printf "    $(dot_up)  ${C_TEXT}%-16s${S_RESET} ${C_SUBTEXT0}%-18s${S_RESET} ${C_OVERLAY0}:${port}${S_RESET}\n" "$name" "$label"
        else
            printf "    $(dot_up)  ${C_TEXT}%-16s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "$name" "$label"
        fi
    elif [[ "$state" == "not found" ]]; then
        continue
    else
        down_count=$((down_count + 1))
        down_names+=("$name")
        printf "    $(dot_down)  ${C_RED}%-16s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "$name" "$label"
    fi
    sleep 0.03
done

echo ""
divider 58

echo ""
printf "    ${C_TEXT}${S_BOLD}%d${S_RESET} ${C_SUBTEXT0}running${S_RESET}" "$up_count"
if [ "$down_count" -gt 0 ]; then
    printf "    ${C_RED}${S_BOLD}%d${S_RESET} ${C_SUBTEXT0}down${S_RESET}" "$down_count"
fi
echo ""

# ── Troubleshooting ──────────────────────────────────────────────────────────

if [ "$down_count" -gt 0 ]; then
    echo ""
    section_header "TROUBLESHOOTING" "$C_RED"
    echo ""
    for name in "${down_names[@]}"; do
        echo -e "    ${C_RED}●${S_RESET} ${C_TEXT}${name}${S_RESET} is down"
        msg_dim "      arr logs $name"
    done
    echo ""
    msg_dim "    Tip: Run arr logs <service> and feed the output to an AI if stuck"
else
    echo ""
    msg_success "Everything looks good! Happy streaming."
fi
echo ""
