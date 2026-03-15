#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

SERVICE="${1:-}"
EXTRA="${2:-}"

if [ -z "$SERVICE" ]; then
    if $HAS_GUM; then
        # Interactive: pick a service, then pick log mode
        SERVICE=$(gum_choose_service "Which service?" "true") || exit 0
        if [ -z "$SERVICE" ]; then exit 0; fi

        MODE=$(gum choose --header "  Log mode" \
            "Last 100 lines" \
            "Follow live (-f)") || exit 0

        echo ""
        if [[ "$MODE" == *"Follow"* ]]; then
            msg_info "Following ${SERVICE} logs (Ctrl+C to stop)"
            echo ""
            compose_cmd logs -f --tail=50 "$SERVICE"
        else
            msg_info "Last 100 lines for ${SERVICE}"
            echo ""
            compose_cmd logs --tail=100 "$SERVICE"
        fi
    else
        echo ""
        msg_info "Showing last 50 lines across all services"
        msg_dim "Tip: arr logs <service> for a single service, add -f to follow"
        echo ""
        compose_cmd logs --tail=50
    fi
else
    if ! echo "$KNOWN_SERVICES" | grep -qw "$SERVICE"; then
        msg_error "Unknown service: ${SERVICE}"
        msg_dim "Available: ${KNOWN_SERVICES}"
        exit 1
    fi
    if [ "$EXTRA" = "-f" ]; then
        echo ""
        msg_info "Following ${SERVICE} logs (Ctrl+C to stop)"
        echo ""
        compose_cmd logs -f --tail=50 "$SERVICE"
    else
        echo ""
        msg_info "Last 100 lines for ${SERVICE}"
        msg_dim "Add -f to follow: arr logs ${SERVICE} -f"
        echo ""
        compose_cmd logs --tail=100 "$SERVICE"
    fi
fi
