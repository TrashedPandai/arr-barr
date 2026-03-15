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
        if $HAS_GUM; then
            # Interactive group menu
            choice=$(gum choose --header "  What to restart?" --height 8 \
                "Restart all containers" \
                "VPN + Downloads" \
                "Downloads only" \
                "Pick a service...") || { msg_dim "Cancelled."; echo ""; exit 0; }

            case "$choice" in
                "Restart all containers")
                    if ! gum_confirm "Restart all containers?"; then
                        msg_dim "Cancelled."; echo ""; exit 0
                    fi
                    echo ""
                    gum_spin "Restarting all containers..." compose_cmd restart
                    ;;
                "VPN + Downloads")
                    echo ""
                    gum_spin "Restarting VPN tunnel..." compose_cmd restart gluetun
                    echo ""
                    spin_start "Waiting for tunnel to establish..."
                    sleep 10
                    spin_stop "Tunnel ready"
                    gum_spin "Restarting download clients..." compose_cmd restart transmission sabnzbd
                    ;;
                "Downloads only")
                    echo ""
                    gum_spin "Restarting download clients..." compose_cmd restart transmission sabnzbd
                    ;;
                "Pick a service..."*)
                    # Build list with bookends, fully rendered
                    running=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | sort || true)
                    svc_count=$(echo "$running" | grep -c . || echo 0)
                    menu_height=$((svc_count + 4))

                    choices="Never mind"
                    while IFS= read -r name; do
                        [ -n "$name" ] && choices+=$'\n'"$name"
                    done <<< "$running"
                    choices+=$'\n'"Restart ALL containers"

                    SERVICE=$(echo "$choices" | gum choose --header "  Restart which service?" --height "$menu_height") || { msg_dim "Cancelled."; echo ""; exit 0; }

                    case "$SERVICE" in
                        "Never mind")
                            msg_dim "Cancelled."; echo ""; exit 0
                            ;;
                        "Restart ALL containers")
                            if ! gum_confirm "Restart all containers?"; then
                                msg_dim "Cancelled."; echo ""; exit 0
                            fi
                            echo ""
                            gum_spin "Restarting all containers..." compose_cmd restart
                            ;;
                        *)
                            echo ""
                            gum_spin "Restarting ${SERVICE}..." compose_cmd restart "$SERVICE"
                            ;;
                    esac
                    ;;
            esac
        else
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
        fi
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
