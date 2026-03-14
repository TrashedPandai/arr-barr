#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

SERVICE="${1:-}"

if [ -z "$SERVICE" ]; then
    show_logo
    show_header "Arr Media Stack  —  Start"

    compose_cmd up -d > /tmp/.arr-start-$$ 2>&1 &
    spin_while $! "Starting all containers..."
    msg_success "Running. Use ${S_BOLD}arr status${S_RESET}${C_TEXT} to check health."
    echo ""
else
    if ! echo "$KNOWN_SERVICES" | grep -qw "$SERVICE"; then
        msg_error "Unknown service: ${SERVICE}"
        msg_dim "Available: ${KNOWN_SERVICES}"
        exit 1
    fi
    compose_cmd start "$SERVICE" > /tmp/.arr-start-$$ 2>&1 &
    spin_while $! "Starting ${SERVICE}..."
    msg_success "${SERVICE} started."
fi
rm -f /tmp/.arr-start-$$
