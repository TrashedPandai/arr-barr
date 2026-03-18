#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

show_logo_static
show_header "Arr Media Stack  —  VPN"

# ── VPN Status ───────────────────────────────────────────────────────────────

gluetun_state=$($DOCKER_CMD inspect -f '{{.State.Status}}' gluetun 2>/dev/null) || gluetun_state="not found"

if [ "$gluetun_state" != "running" ]; then
    echo ""
    section_header "TUNNEL" "$C_RED"
    echo ""
    echo -e "    $(dot_down)  ${S_BOLD}${C_RED}DISCONNECTED${S_RESET}"
    echo ""
    msg_dim "    Gluetun container is ${gluetun_state}."
    msg_dim "    Start it with: arr start"
    echo ""
    exit 0
fi

# Get public IP through the VPN tunnel
$DOCKER_CMD exec gluetun wget -qO- --timeout=5 http://ipinfo.io/json > /tmp/.arr-vpn-$$ 2>/dev/null &
if $HAS_GUM; then
    gum spin --spinner dot --title "  Checking tunnel..." -- wait $!
else
    spin_while $! "Checking tunnel..."
fi

vpn_info="$(cat /tmp/.arr-vpn-$$ 2>/dev/null)" || vpn_info=""
rm -f /tmp/.arr-vpn-$$

echo ""

if [ -n "$vpn_info" ]; then
    vpn_ip=""
    vpn_city=""
    vpn_region=""
    vpn_country=""
    vpn_org=""

    if command -v jq &>/dev/null; then
        vpn_ip=$(echo "$vpn_info" | jq -r '.ip // ""')
        vpn_city=$(echo "$vpn_info" | jq -r '.city // ""')
        vpn_region=$(echo "$vpn_info" | jq -r '.region // ""')
        vpn_country=$(echo "$vpn_info" | jq -r '.country // ""')
        vpn_org=$(echo "$vpn_info" | jq -r '.org // ""')
    elif command -v python3 &>/dev/null; then
        vpn_ip=$(echo "$vpn_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null) || true
        vpn_city=$(echo "$vpn_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('city',''))" 2>/dev/null) || true
        vpn_region=$(echo "$vpn_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('region',''))" 2>/dev/null) || true
        vpn_country=$(echo "$vpn_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('country',''))" 2>/dev/null) || true
        vpn_org=$(echo "$vpn_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('org',''))" 2>/dev/null) || true
    fi

    if [ -n "$vpn_ip" ]; then
        section_header "TUNNEL" "$C_GREEN"
        echo ""
        echo -e "    $(dot_up)  ${S_BOLD}${C_GREEN}CONNECTED${S_RESET}"
        echo ""
        kv_line "    Public IP" "$vpn_ip" "$C_SUBTEXT0" "${S_BOLD}${C_TEXT}"
        [ -n "$vpn_city" ] && kv_line "    Location" "${vpn_city}, ${vpn_region}, ${vpn_country}"
        [ -n "$vpn_org" ] && kv_line "    Provider" "$vpn_org" "$C_SUBTEXT0" "$C_OVERLAY0"
    else
        echo -e "    $(dot_down)  ${S_BOLD}${C_RED}DISCONNECTED${S_RESET}"
        echo ""
        msg_dim "    Gluetun is running but the tunnel may be down."
        msg_dim "    Check logs: arr logs gluetun"
        echo ""
        exit 0
    fi
else
    echo -e "    $(dot_down)  ${S_BOLD}${C_RED}DISCONNECTED${S_RESET}"
    echo ""
    msg_dim "    Could not reach ipinfo.io through the tunnel."
    msg_dim "    Check logs: arr logs gluetun"
    echo ""
    exit 0
fi

echo ""

# ── Port Accessibility ───────────────────────────────────────────────────────

section_header "SERVICES IN TUNNEL" "$C_SAPPHIRE"
echo ""

for entry in "transmission|9091|Torrents" "sabnzbd|8080|Usenet"; do
    IFS='|' read -r name port label <<< "$entry"
    if curl -s --max-time 3 -o /dev/null "http://localhost:${port}" 2>/dev/null; then
        printf "    $(dot_up)  ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_GREEN}accessible${S_RESET}\n" "$name" "$port"
    else
        printf "    $(dot_down)  ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_RED}unreachable${S_RESET}\n" "$name" "$port"
    fi
done

echo ""
msg_success "Your real IP is hidden. Download traffic is protected."
echo ""
