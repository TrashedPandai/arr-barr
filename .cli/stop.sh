#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

SERVICE="${1:-}"

# ══════════════════════════════════════════════════════════════════════════════
#  VISUAL SHUTDOWN SEQUENCE (stop-all only)
# ══════════════════════════════════════════════════════════════════════════════

stop_all_visual() {
    echo ""
    section_header "SHUTDOWN SEQUENCE" "$C_RED"
    echo ""

    # ── Service-to-group mapping (mirrors start.sh) ──────────────────────────

    declare -A SVC_GROUP
    SVC_GROUP[gluetun]="network"
    SVC_GROUP[transmission]="network"
    SVC_GROUP[sabnzbd]="network"
    SVC_GROUP[prowlarr]="indexers"
    SVC_GROUP[flaresolverr]="indexers"
    SVC_GROUP[radarr]="media"
    SVC_GROUP[sonarr]="media"
    SVC_GROUP[lidarr]="media"
    SVC_GROUP[bazarr]="media"
    SVC_GROUP[jellyfin]="streaming"
    SVC_GROUP[seerr]="streaming"
    SVC_GROUP[lazylibrarian]="books"
    SVC_GROUP[kavita]="books"
    SVC_GROUP[audiobookshelf]="books"
    SVC_GROUP[questarr]="games"

    GROUP_ORDER=("network" "indexers" "media" "streaming" "books" "games")

    declare -A GROUP_LABEL GROUP_COLOR
    GROUP_LABEL[network]="NETWORK & DOWNLOADS"
    GROUP_LABEL[indexers]="INDEXERS"
    GROUP_LABEL[media]="MEDIA MANAGERS"
    GROUP_LABEL[streaming]="STREAMING"
    GROUP_LABEL[books]="BOOKS & AUDIO"
    GROUP_LABEL[games]="GAMING"

    GROUP_COLOR[network]="$C_GREEN"
    GROUP_COLOR[indexers]="$C_YELLOW"
    GROUP_COLOR[media]="$C_BLUE"
    GROUP_COLOR[streaming]="$C_MAUVE"
    GROUP_COLOR[books]="$C_TEAL"
    GROUP_COLOR[games]="$C_FLAMINGO"

    # ── Build active service list ────────────────────────────────────────────

    active_services=()
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name port label <<< "$entry"
        active_services+=("$name|$port|$label")
    done
    total=${#active_services[@]}

    # ── Build display lines ──────────────────────────────────────────────────

    DISPLAY_LINES=()
    declare -A SVC_DISPLAY_IDX GRP_DISPLAY_IDX GRP_TOTAL GRP_DOWN

    first_group=true
    for gid in "${GROUP_ORDER[@]}"; do
        has_svc=false
        grp_count=0
        for entry in "${active_services[@]}"; do
            IFS='|' read -r sname _ _ <<< "$entry"
            if [ "${SVC_GROUP[$sname]:-}" = "$gid" ]; then
                has_svc=true
                grp_count=$((grp_count + 1))
            fi
        done
        $has_svc || continue

        if $first_group; then
            first_group=false
        else
            DISPLAY_LINES+=("spacer|")
        fi

        GRP_DISPLAY_IDX[$gid]=${#DISPLAY_LINES[@]}
        GRP_TOTAL[$gid]=$grp_count
        GRP_DOWN[$gid]=0
        DISPLAY_LINES+=("header|$gid")

        for entry in "${active_services[@]}"; do
            IFS='|' read -r sname sport slabel <<< "$entry"
            if [ "${SVC_GROUP[$sname]:-}" = "$gid" ]; then
                SVC_DISPLAY_IDX[$sname]=${#DISPLAY_LINES[@]}
                DISPLAY_LINES+=("service|$sname|$sport|$slabel")
            fi
        done
    done

    # ── Render initial state: all GREEN (running) ────────────────────────────

    printf "\033[?25l"

    LOGFILE="/tmp/.arr-stop-log-$$"
    MARKERDIR="/tmp/.arr-stop-markers-$$"
    SVCLIST="/tmp/.arr-stop-svclist-$$"

    cleanup_stop() {
        printf "\033[?25h"
        rm -f "$LOGFILE" "$SVCLIST"
        rm -rf "$MARKERDIR"
    }
    trap cleanup_stop EXIT

    for dl in "${DISPLAY_LINES[@]}"; do
        IFS='|' read -r dtype rest <<< "$dl"
        if [ "$dtype" = "spacer" ]; then
            echo ""
        elif [ "$dtype" = "header" ]; then
            gid="$rest"
            printf "    ${GROUP_COLOR[$gid]}${S_BOLD}▸ ${GROUP_LABEL[$gid]} ✓${S_RESET}\n"
        else
            IFS='|' read -r _ sname sport slabel <<< "$dl"
            local port_str=""
            [ -n "$sport" ] && port_str=" ${C_OVERLAY0}:${sport}${S_RESET}"
            printf "    ${C_GREEN}●${S_RESET}  ${C_TEXT}%-16s${S_RESET} ${C_SUBTEXT0}%-18s${S_RESET}${port_str}\n" "$sname" "$slabel"
        fi
        sleep 0.02
    done

    # ── Wave bar setup (drain direction) ─────────────────────────────────────

    WAVE_W=36
    WAVE_CHARS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" "▇" "▆" "▅" "▄" "▃" "▂")
    WAVE_LEN=${#WAVE_CHARS[@]}

    WAVE_COLORS=(
        "243;139;168"   # red
        "235;160;172"   # maroon
        "250;179;135"   # peach
        "245;194;231"   # pink
        "242;205;205"   # flamingo
        "245;224;220"   # rosewater
        "203;166;247"   # mauve
        "249;226;175"   # yellow
        "250;179;135"   # peach
        "243;139;168"   # red
        "235;160;172"   # maroon
    )
    WAVE_NUM_COLORS=${#WAVE_COLORS[@]}

    render_wave_drain() {
        local pct=$1
        local frame=$2
        local filled=$(( pct * WAVE_W / 100 ))
        [ "$filled" -gt "$WAVE_W" ] && filled=$WAVE_W

        printf "    "
        for (( i=0; i<WAVE_W; i++ )); do
            if [ "$i" -lt "$filled" ]; then
                local cidx=$(( (i + frame) % WAVE_NUM_COLORS ))
                local widx=$(( (i + frame * 2) % WAVE_LEN ))
                printf "\033[38;2;%sm%s" "${WAVE_COLORS[$cidx]}" "${WAVE_CHARS[$widx]}"
            elif [ "$i" -eq "$filled" ] && [ "$pct" -gt 0 ]; then
                local widx=$(( (frame * 3) % WAVE_LEN ))
                printf "\033[38;2;69;71;90m%s" "${WAVE_CHARS[$widx]}"
            else
                printf "\033[38;2;49;50;68m▁"
            fi
        done
        printf "${S_RESET}"
    }

    # Blank line + wave + counter
    echo ""
    render_wave_drain 100 0
    printf "  ${C_SUBTEXT0}0/${total} stopped${S_RESET}\033[K"
    echo ""
    echo ""

    num_display=${#DISPLAY_LINES[@]}
    total_rendered=$((num_display + 3))

    # ── Helper functions ─────────────────────────────────────────────────────

    overwrite_line_at() {
        local idx="$1"
        local content="$2"
        local up=$(( total_rendered - idx ))
        printf "\033[${up}A\r"
        printf "%s\033[K" "$content"
        local down=$((up - 1))
        [ "$down" -gt 0 ] && printf "\n\033[${down}B" || printf "\n"
        printf "\r"
    }

    overwrite_service_stopped() {
        local sname="$1" slabel="$2"
        local idx="${SVC_DISPLAY_IDX[$sname]:-}"
        [ -z "$idx" ] && return

        local content
        content=$(printf "    ${C_SURFACE2}○${S_RESET}  ${C_OVERLAY0}%-16s %-18s${S_RESET}" "$sname" "$slabel")
        overwrite_line_at "$idx" "$content"
    }

    update_group_header() {
        local gid="$1" state="$2"
        local idx="${GRP_DISPLAY_IDX[$gid]:-}"
        [ -z "$idx" ] && return

        local label="${GROUP_LABEL[$gid]}"
        local color="${GROUP_COLOR[$gid]}"
        local content
        case "$state" in
            healthy)
                content=$(printf "    ${color}${S_BOLD}▸ ${label} ✓${S_RESET}")
                ;;
            mixed)
                content=$(printf "    ${C_YELLOW}${S_BOLD}▸ ${label}${S_RESET}")
                ;;
            down)
                content=$(printf "    ${C_RED}${S_BOLD}▸ ${label}${S_RESET}")
                ;;
        esac
        overwrite_line_at "$idx" "$content"
    }

    declare -A ANNOUNCED
    stopped_count=0
    wave_frame=0

    update_wave_drain() {
        local remaining=$(( total - stopped_count ))
        local pct=0
        [ "$total" -gt 0 ] && pct=$(( remaining * 100 / total ))
        local up=$(( total_rendered - num_display - 1 ))
        printf "\033[${up}A\r"
        render_wave_drain "$pct" "$wave_frame"
        printf "  ${C_TEXT}${S_BOLD}${stopped_count}${S_RESET}${C_SUBTEXT0}/${total} stopped${S_RESET}\033[K"
        local down=$((up))
        [ "$down" -gt 0 ] && printf "\033[${down}B"
        printf "\r"
        wave_frame=$((wave_frame + 1))
    }

    SPIN_FRAMES=("◉" "◎" "○" "◎" "◉" "●" "◉" "◎" "○" "◎")
    SPIN_LEN=${#SPIN_FRAMES[@]}
    spin_tick=0

    animate_shutting_down() {
        local frame_idx=$((spin_tick % SPIN_LEN))
        local spin_char="${SPIN_FRAMES[$frame_idx]}"

        for entry in "${active_services[@]}"; do
            IFS='|' read -r sname sport slabel <<< "$entry"
            [ -n "${ANNOUNCED[$sname]:-}" ] && continue
            local idx="${SVC_DISPLAY_IDX[$sname]:-}"
            [ -z "$idx" ] && continue

            local grp="${SVC_GROUP[$sname]:-}"
            local grp_color="${GROUP_COLOR[$grp]:-$C_OVERLAY0}"
            local content
            content=$(printf "    ${grp_color}%s${S_RESET}  ${C_SUBTEXT0}%-16s %-18s${S_RESET} ${C_OVERLAY0}shutting down${S_RESET}" "$spin_char" "$sname" "$slabel")
            overwrite_line_at "$idx" "$content"
        done
        spin_tick=$((spin_tick + 1))
    }

    try_announce_stop() {
        local target="$1"
        [ -n "${ANNOUNCED[$target]:-}" ] && return
        ANNOUNCED[$target]=1
        stopped_count=$((stopped_count + 1))

        local tgt_group="${SVC_GROUP[$target]:-}"
        for entry in "${active_services[@]}"; do
            IFS='|' read -r sname sport slabel <<< "$entry"
            if [ "$sname" = "$target" ]; then
                overwrite_service_stopped "$sname" "$slabel"
                break
            fi
        done

        if [ -n "$tgt_group" ] && [ -n "${GRP_DOWN[$tgt_group]+x}" ]; then
            GRP_DOWN[$tgt_group]=$(( ${GRP_DOWN[$tgt_group]} + 1 ))
            if [ "${GRP_DOWN[$tgt_group]}" -ge "${GRP_TOTAL[$tgt_group]}" ]; then
                update_group_header "$tgt_group" "down"
            elif [ "${GRP_DOWN[$tgt_group]}" -gt 0 ]; then
                update_group_header "$tgt_group" "mixed"
            fi
        fi
    }

    # ── Background: compose stop + log watcher ───────────────────────────────

    : > "$LOGFILE"
    mkdir -p "$MARKERDIR"

    # Write service names for watcher subshell
    : > "$SVCLIST"
    for entry in "${active_services[@]}"; do
        IFS='|' read -r sname _ _ <<< "$entry"
        echo "$sname" >> "$SVCLIST"
    done

    # Background process 1: run compose stop
    (
        $DOCKER_CMD compose -f "$ARR_HOME/compose.yaml" --env-file "$ARR_HOME/.env" stop >> "$LOGFILE" 2>&1
        echo "$?" > "$MARKERDIR/__exit__"
    ) &
    COMPOSE_PID=$!

    # Background process 2: parse log for stopped services
    (
        prev_size=0
        while [ ! -f "$MARKERDIR/__exit__" ]; do
            [ ! -f "$LOGFILE" ] && sleep 0.15 && continue
            cur_size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
            cur_size=${cur_size##* }
            if [ "$cur_size" -gt "$prev_size" ]; then
                tail -c +"$((prev_size + 1))" "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
                    while IFS= read -r svc; do
                        [ -z "$svc" ] && continue
                        case "$line" in
                            *"$svc"*[Ss]topped*)
                                touch "$MARKERDIR/$svc"
                                ;;
                        esac
                    done < "$SVCLIST"
                done
                prev_size=$cur_size
            fi
            sleep 0.15
        done
        # Final pass on complete log
        if [ -f "$LOGFILE" ]; then
            while IFS= read -r line; do
                while IFS= read -r svc; do
                    [ -z "$svc" ] && continue
                    case "$line" in
                        *"$svc"*[Ss]topped*)
                            touch "$MARKERDIR/$svc"
                            ;;
                    esac
                done < "$SVCLIST"
            done < "$LOGFILE"
        fi
        # Verify: anything NOT in docker ps is stopped
        running=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null || true)
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            if ! echo "$running" | grep -qw "$svc" 2>/dev/null; then
                touch "$MARKERDIR/$svc"
            fi
        done < "$SVCLIST"
        touch "$MARKERDIR/__verified__"
    ) &
    WATCHER_PID=$!

    # ── Foreground: PURE RENDER at 33fps ─────────────────────────────────────
    # This loop NEVER calls docker, compose, grep, wc, or any blocking command.
    # It only checks file existence (kernel-cached, ~0ms) and writes to terminal.

    while true; do
        # Check for newly stopped services via marker files
        for entry in "${active_services[@]}"; do
            IFS='|' read -r sname _ _ <<< "$entry"
            if [ -z "${ANNOUNCED[$sname]:-}" ] && [ -f "$MARKERDIR/$sname" ]; then
                try_announce_stop "$sname"
            fi
        done

        # Check if background is fully done
        if [ -f "$MARKERDIR/__verified__" ]; then
            for entry in "${active_services[@]}"; do
                IFS='|' read -r sname _ _ <<< "$entry"
                if [ -z "${ANNOUNCED[$sname]:-}" ] && [ -f "$MARKERDIR/$sname" ]; then
                    try_announce_stop "$sname"
                fi
            done
            break
        fi

        animate_shutting_down
        update_wave_drain
        sleep 0.03
    done

    # Wait for background processes
    wait "$COMPOSE_PID" 2>/dev/null
    compose_exit=0
    if [ -f "$MARKERDIR/__exit__" ]; then
        compose_exit=$(cat "$MARKERDIR/__exit__" 2>/dev/null || echo 0)
    fi
    wait "$WATCHER_PID" 2>/dev/null || true

    # Final wave frame
    update_wave_drain

    # Restore cursor
    printf "\033[?25h"

    # ── Results ──────────────────────────────────────────────────────────────

    echo ""
    divider 58
    echo ""

    if [ "$compose_exit" -eq 0 ] && [ "$stopped_count" -ge "$total" ]; then
        printf "    "
        gradient_text "ALL SYSTEMS STOPPED" 243 139 168 203 166 247
        echo ""
        echo ""
        printf "    ${C_RED}${S_BOLD}${stopped_count}${S_RESET}${C_SUBTEXT0} containers shut down safely${S_RESET}\n"
        echo ""
        msg_dim "    arr start — bring them back"
    elif [ "$compose_exit" -eq 0 ]; then
        printf "    ${C_RED}${S_BOLD}${stopped_count}${S_RESET}${C_SUBTEXT0}/${total} containers stopped${S_RESET}\n"
        local still_up=$((total - stopped_count))
        if [ "$still_up" -gt 0 ]; then
            echo ""
            msg_warn "${still_up} service(s) may still be running. Run ${S_BOLD}arr status${S_RESET}${C_TEXT} to check."
        fi
    else
        msg_error "Shutdown encountered errors (exit code: ${compose_exit})"
        echo ""
        if [ -f "$LOGFILE" ]; then
            msg_dim "    Compose output:"
            tail -8 "$LOGFILE" | while IFS= read -r l; do
                msg_dim "      $l"
            done
        fi
        echo ""
        msg_dim "    arr logs <service>  — check individual logs"
    fi

    echo ""
    cleanup_stop
    trap - EXIT
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN ROUTING
# ══════════════════════════════════════════════════════════════════════════════

if [ -z "$SERVICE" ]; then
    show_logo
    show_header "Arr Media Stack  —  Stop"

    if $HAS_GUM; then
        choice=$(gum choose --header "  What to stop?" --height 5 \
            "Stop all containers" \
            "Stop a single service") || { msg_dim "Cancelled."; echo ""; exit 0; }

        case "$choice" in
            "Stop all containers")
                if ! gum_confirm "Stop all containers?"; then
                    msg_dim "Cancelled."; echo ""; exit 0
                fi
                stop_all_visual
                ;;
            "Stop a single service")
                running=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | sort || true)
                svc_count=$(echo "$running" | grep -c . || echo 0)
                menu_height=$((svc_count + 4))

                choices="Never mind"
                while IFS= read -r name; do
                    [ -n "$name" ] && choices+=$'\n'"$name"
                done <<< "$running"
                choices+=$'\n'"Stop ALL containers"

                SERVICE=$(echo "$choices" | gum choose --header "  Stop which service?" --height "$menu_height") || { msg_dim "Cancelled."; echo ""; exit 0; }

                case "$SERVICE" in
                    "Never mind")
                        msg_dim "Cancelled."; echo ""; exit 0
                        ;;
                    "Stop ALL containers")
                        if ! gum_confirm "Stop all containers?"; then
                            msg_dim "Cancelled."; echo ""; exit 0
                        fi
                        stop_all_visual
                        ;;
                    *)
                        echo ""
                        gum_spin "Stopping ${SERVICE}..." compose_cmd stop "$SERVICE"
                        msg_success "${SERVICE} stopped."
                        ;;
                esac
                ;;
        esac
    else
        msg_warn "This will stop all containers."
        echo ""
        if ! confirm "Continue?"; then
            msg_dim "Cancelled."
            echo ""
            exit 0
        fi
        stop_all_visual
    fi
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
echo ""
