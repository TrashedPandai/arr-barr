#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

SERVICE="${1:-}"

if [ -z "$SERVICE" ]; then
    show_logo
    show_header "Arr Media Stack  —  Stop"

    msg_warn "This will stop all containers."
    echo ""
    if ! confirm "Continue?"; then
        msg_dim "Cancelled."
        echo ""
        exit 0
    fi
    echo ""
    compose_cmd stop > /tmp/.arr-stop-$$ 2>&1 &
    spin_while $! "Stopping all containers..."
    msg_success "Stopped. Use ${S_BOLD}arr start${S_RESET}${C_TEXT} to bring them back."
    echo ""
else
    if ! echo "$KNOWN_SERVICES" | grep -qw "$SERVICE"; then
        msg_error "Unknown service: ${SERVICE}"
        msg_dim "Available: ${KNOWN_SERVICES}"
        exit 1
    fi
    compose_cmd stop "$SERVICE" > /tmp/.arr-stop-$$ 2>&1 &
    spin_while $! "Stopping ${SERVICE}..."
    msg_success "${SERVICE} stopped."
fi
rm -f /tmp/.arr-stop-$$
