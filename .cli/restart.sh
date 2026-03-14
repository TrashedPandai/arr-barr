#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

SERVICE="${1:-}"

show_logo
show_header "Arr Media Stack  —  Restart"

case "$SERVICE" in
    "")
        msg_warn "This will restart all containers."
        echo ""
        if ! confirm "Continue?"; then
            msg_dim "Cancelled."
            echo ""
            exit 0
        fi
        echo ""
        compose_cmd restart > /tmp/.arr-restart-$$ 2>&1 &
        spin_while $! "Restarting all containers..."
        ;;
    vpn)
        compose_cmd restart gluetun > /tmp/.arr-restart-$$ 2>&1 &
        spin_while $! "Restarting VPN tunnel..."

        echo ""
        spin_start "Waiting for tunnel to establish..."
        sleep 10
        spin_stop "Tunnel ready"

        compose_cmd restart transmission sabnzbd > /tmp/.arr-restart-$$ 2>&1 &
        spin_while $! "Restarting download clients..."
        ;;
    downloads)
        compose_cmd restart transmission sabnzbd > /tmp/.arr-restart-$$ 2>&1 &
        spin_while $! "Restarting download clients..."
        ;;
    *)
        if ! echo "$KNOWN_SERVICES" | grep -qw "$SERVICE"; then
            msg_error "Unknown service: ${SERVICE}"
            echo ""
            msg_dim "Available: ${KNOWN_SERVICES}"
            msg_dim "Aliases:   vpn, downloads"
            echo ""
            exit 1
        fi
        compose_cmd restart "$SERVICE" > /tmp/.arr-restart-$$ 2>&1 &
        spin_while $! "Restarting ${SERVICE}..."
        ;;
esac

rm -f /tmp/.arr-restart-$$
echo ""
msg_success "Done. Use ${S_BOLD}arr status${S_RESET}${C_TEXT} to verify."
echo ""
