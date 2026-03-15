#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

SERVICE="${1:-}"

# ── Single service start (keep simple) ───────────────────────────────────────

if [ -n "$SERVICE" ]; then
    if ! echo "$KNOWN_SERVICES" | grep -qw "$SERVICE"; then
        msg_error "Unknown service: ${SERVICE}"
        msg_dim "Available: ${KNOWN_SERVICES}"
        exit 1
    fi
    svc_label="$SERVICE"
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r sname sport slabel <<< "$entry"
        if [ "$sname" = "$SERVICE" ]; then
            svc_label="$slabel"
            break
        fi
    done
    compose_cmd start "$SERVICE" > /tmp/.arr-start-$$ 2>&1 &
    spin_while $! "Starting ${SERVICE}..."
    msg_success "${S_BOLD}${SERVICE}${S_RESET}${C_TEXT} (${svc_label}) is up."
    rm -f /tmp/.arr-start-$$
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  FULL STACK LAUNCH
# ══════════════════════════════════════════════════════════════════════════════

show_logo
show_header "Arr Media Stack  —  Launch"

# ── Phase 1: Pre-flight ─────────────────────────────────────────────────────

section_header "PRE-FLIGHT" "$C_MAUVE"

# Build active service list
active_services=()
for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name port label <<< "$entry"
    active_services+=("$name|$port|$label")
done
total=${#active_services[@]}

# Check what is already running
$DOCKER_CMD ps --format '{{.Names}}' > /tmp/.arr-running-$$ 2>/dev/null || true
already_running=0
while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    for entry in "${active_services[@]}"; do
        IFS='|' read -r sname _ _ <<< "$entry"
        [ "$cname" = "$sname" ] && already_running=$((already_running + 1))
    done
done < /tmp/.arr-running-$$
rm -f /tmp/.arr-running-$$

printf "    ${C_TEXT}${S_BOLD}${total}${S_RESET}${C_SUBTEXT0} services in manifest${S_RESET}\n"
if [ "$already_running" -gt 0 ]; then
    printf "    ${C_YELLOW}${S_BOLD}${already_running}${S_RESET}${C_SUBTEXT0} already running (will be refreshed)${S_RESET}\n"
fi

# Quick VPN config check
if grep -q "your_private_key_here" "$ARR_HOME/.env" 2>/dev/null; then
    echo ""
    msg_warn "VPN credentials are still placeholder — gluetun may fail"
fi

echo ""
sleep 0.3

# ── Phase 2: Ignition ───────────────────────────────────────────────────────

section_header "LAUNCH SEQUENCE" "$C_SAPPHIRE"
echo ""

# Service-to-group mapping
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

# Build ordered list of lines for display
DISPLAY_LINES=()
declare -A SVC_DISPLAY_IDX  # service name -> index in DISPLAY_LINES
declare -A GRP_DISPLAY_IDX  # group id -> index in DISPLAY_LINES
declare -A GRP_TOTAL        # group id -> total services in group
declare -A GRP_UP           # group id -> count of services up so far

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
    GRP_UP[$gid]=0
    DISPLAY_LINES+=("header|$gid")

    for entry in "${active_services[@]}"; do
        IFS='|' read -r sname sport slabel <<< "$entry"
        if [ "${SVC_GROUP[$sname]:-}" = "$gid" ]; then
            SVC_DISPLAY_IDX[$sname]=${#DISPLAY_LINES[@]}
            DISPLAY_LINES+=("service|$sname|$sport|$slabel")
        fi
    done
done

# Render initial state — everything pending
printf "\033[?25l"  # hide cursor

LOGFILE="/tmp/.arr-start-log-$$"
MARKERDIR="/tmp/.arr-markers-$$"
SVCLIST="/tmp/.arr-svclist-$$"

cleanup_start() {
    printf "\033[?25h"
    rm -f "$LOGFILE" "$SVCLIST"
    rm -rf "$MARKERDIR"
}
trap cleanup_start EXIT

for dl in "${DISPLAY_LINES[@]}"; do
    IFS='|' read -r dtype rest <<< "$dl"
    if [ "$dtype" = "spacer" ]; then
        echo ""
    elif [ "$dtype" = "header" ]; then
        gid="$rest"
        printf "    ${GROUP_COLOR[$gid]}${S_DIM}▸ ${GROUP_LABEL[$gid]}${S_RESET}\n"
    else
        IFS='|' read -r _ sname sport slabel <<< "$dl"
        printf "    ${C_SURFACE2}○${S_RESET}  ${C_OVERLAY0}%-16s %-18s${S_RESET}\n" "$sname" "$slabel"
    fi
    sleep 0.02
done

# ── Wave bar setup ───────────────────────────────────────────────────────────

WAVE_W=36
WAVE_CHARS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" "▇" "▆" "▅" "▄" "▃" "▂")
WAVE_LEN=${#WAVE_CHARS[@]}

WAVE_COLORS=(
    "116;199;236"   # sapphire
    "137;180;250"   # blue
    "180;190;254"   # lavender
    "203;166;247"   # mauve
    "245;194;231"   # pink
    "242;205;205"   # flamingo
    "245;224;220"   # rosewater
    "249;226;175"   # yellow
    "166;227;161"   # green
    "148;226;213"   # teal
    "137;220;235"   # sky
)
WAVE_NUM_COLORS=${#WAVE_COLORS[@]}

render_wave() {
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
        elif [ "$i" -eq "$filled" ] && [ "$pct" -lt 100 ]; then
            local widx=$(( (frame * 3) % WAVE_LEN ))
            printf "\033[38;2;69;71;90m%s" "${WAVE_CHARS[$widx]}"
        else
            printf "\033[38;2;49;50;68m▁"
        fi
    done
    printf "${S_RESET}"
}

SPIN_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPIN_LEN=${#SPIN_FRAMES[@]}
spin_tick=0

# Blank line + wave + counter
echo ""
render_wave 0 0
printf "  ${C_SUBTEXT0}0/${total}${S_RESET}\033[K"
echo ""
echo ""

num_display=${#DISPLAY_LINES[@]}
total_rendered=$((num_display + 3))

# ── Helper functions ─────────────────────────────────────────────────────────

declare -A ANNOUNCED
declare -A FAILED
started_count=0
wave_frame=0

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

overwrite_service_line() {
    local sname="$1" sport="$2" slabel="$3"
    local idx="${SVC_DISPLAY_IDX[$sname]:-}"
    [ -z "$idx" ] && return

    local port_str=""
    [ -n "$sport" ] && port_str=" ${C_OVERLAY0}:${sport}${S_RESET}"
    local content
    content=$(printf "    ${C_GREEN}●${S_RESET}  ${C_TEXT}%-16s${S_RESET} ${C_SUBTEXT0}%-18s${S_RESET}${port_str}" "$sname" "$slabel")
    overwrite_line_at "$idx" "$content"
}

light_up_group() {
    local gid="$1"
    local idx="${GRP_DISPLAY_IDX[$gid]:-}"
    [ -z "$idx" ] && return

    local color="${GROUP_COLOR[$gid]}"
    local label="${GROUP_LABEL[$gid]}"
    local content
    content=$(printf "    ${color}${S_BOLD}▸ ${label} ✓${S_RESET}")
    overwrite_line_at "$idx" "$content"
}

animate_pending() {
    local frame_idx=$((spin_tick % SPIN_LEN))
    local spin_char="${SPIN_FRAMES[$frame_idx]}"

    for entry in "${active_services[@]}"; do
        IFS='|' read -r sname sport slabel <<< "$entry"
        [ -n "${ANNOUNCED[$sname]:-}" ] && continue
        [ -n "${FAILED[$sname]:-}" ] && continue
        local idx="${SVC_DISPLAY_IDX[$sname]:-}"
        [ -z "$idx" ] && continue

        local grp="${SVC_GROUP[$sname]:-}"
        local grp_color="${GROUP_COLOR[$grp]:-$C_OVERLAY0}"
        local content
        content=$(printf "    ${grp_color}%s${S_RESET}  ${C_OVERLAY0}%-16s %-18s${S_RESET}" "$spin_char" "$sname" "$slabel")
        overwrite_line_at "$idx" "$content"
    done
    spin_tick=$((spin_tick + 1))
}

mark_failed() {
    local sname="$1"
    [ -n "${FAILED[$sname]:-}" ] && return
    FAILED[$sname]=1
    local idx="${SVC_DISPLAY_IDX[$sname]:-}"
    [ -z "$idx" ] && return

    local slabel=""
    for entry in "${active_services[@]}"; do
        IFS='|' read -r sn sp sl <<< "$entry"
        [ "$sn" = "$sname" ] && slabel="$sl" && break
    done
    local content
    content=$(printf "    ${C_RED}✗${S_RESET}  ${C_RED}%-16s${S_RESET} ${C_OVERLAY0}%-18s${S_RESET} ${C_RED}failed${S_RESET}" "$sname" "$slabel")
    overwrite_line_at "$idx" "$content"
}

update_wave() {
    local pct=$(( started_count * 100 / total ))
    local up=$(( total_rendered - num_display - 1 ))
    printf "\033[${up}A\r"
    render_wave "$pct" "$wave_frame"
    printf "  ${C_TEXT}${S_BOLD}${started_count}${S_RESET}${C_SUBTEXT0}/${total}${S_RESET}\033[K"
    local down=$((up))
    [ "$down" -gt 0 ] && printf "\033[${down}B"
    printf "\r"
    wave_frame=$((wave_frame + 1))
}

try_announce() {
    local target="$1"
    [ -n "${ANNOUNCED[$target]:-}" ] && return
    ANNOUNCED[$target]=1
    started_count=$((started_count + 1))

    local tgt_group="${SVC_GROUP[$target]:-}"
    for entry in "${active_services[@]}"; do
        IFS='|' read -r sname sport slabel <<< "$entry"
        if [ "$sname" = "$target" ]; then
            overwrite_service_line "$sname" "$sport" "$slabel"
            break
        fi
    done

    if [ -n "$tgt_group" ] && [ -n "${GRP_UP[$tgt_group]+x}" ]; then
        GRP_UP[$tgt_group]=$(( ${GRP_UP[$tgt_group]} + 1 ))
        if [ "${GRP_UP[$tgt_group]}" -ge "${GRP_TOTAL[$tgt_group]}" ]; then
            light_up_group "$tgt_group"
        fi
    fi
}

# ── Background: compose + log watcher ────────────────────────────────────────

: > "$LOGFILE"
mkdir -p "$MARKERDIR"

# Write service names list for the watcher subshell
: > "$SVCLIST"
for entry in "${active_services[@]}"; do
    IFS='|' read -r sname _ _ <<< "$entry"
    echo "$sname" >> "$SVCLIST"
done

# Background process 1: run compose
(
    $DOCKER_CMD compose -f "$ARR_HOME/compose.yaml" --env-file "$ARR_HOME/.env" up -d >> "$LOGFILE" 2>&1
    echo "$?" > "$MARKERDIR/__exit__"
) &
COMPOSE_PID=$!

# Background process 2: parse log for started services
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
                        *"$svc"*[Ss]tarted*|*"$svc"*[Rr]unning*)
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
                    *"$svc"*[Ss]tarted*|*"$svc"*[Rr]unning*)
                        touch "$MARKERDIR/$svc"
                        ;;
                esac
            done < "$SVCLIST"
        done < "$LOGFILE"
    fi
    # Also verify with docker ps
    $DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | while IFS= read -r cname; do
        [ -n "$cname" ] && touch "$MARKERDIR/$cname"
    done
    touch "$MARKERDIR/__verified__"
) &
WATCHER_PID=$!

# ── Foreground: PURE RENDER at 33fps ────────────────────────────────────────
# This loop NEVER calls docker, compose, grep, wc, or any blocking command.
# It only checks file existence (kernel-cached, ~0ms) and writes to terminal.

while true; do
    # Check for newly started services via marker files
    for entry in "${active_services[@]}"; do
        IFS='|' read -r sname _ _ <<< "$entry"
        if [ -z "${ANNOUNCED[$sname]:-}" ] && [ -f "$MARKERDIR/$sname" ]; then
            try_announce "$sname"
        fi
    done

    # Check if background is fully done
    if [ -f "$MARKERDIR/__verified__" ]; then
        # One final marker sweep
        for entry in "${active_services[@]}"; do
            IFS='|' read -r sname _ _ <<< "$entry"
            if [ -z "${ANNOUNCED[$sname]:-}" ] && [ -f "$MARKERDIR/$sname" ]; then
                try_announce "$sname"
            fi
        done
        break
    fi

    animate_pending
    update_wave
    sleep 0.03
done

# Wait for background processes
wait "$COMPOSE_PID" 2>/dev/null
compose_exit=0
if [ -f "$MARKERDIR/__exit__" ]; then
    compose_exit=$(cat "$MARKERDIR/__exit__" 2>/dev/null || echo 0)
fi
wait "$WATCHER_PID" 2>/dev/null || true

# Mark any remaining unstarted services as failed
for entry in "${active_services[@]}"; do
    IFS='|' read -r sname _ _ <<< "$entry"
    [ -z "${ANNOUNCED[$sname]:-}" ] && mark_failed "$sname"
done

# Final wave frame
update_wave

# Restore cursor
printf "\033[?25h"

# ── Phase 3: Results ────────────────────────────────────────────────────────

echo ""
divider 58
echo ""

if [ "$compose_exit" -eq 0 ] && [ "$started_count" -ge "$total" ]; then
    printf "    "
    gradient_text "ALL SYSTEMS OPERATIONAL" 166 227 161 137 220 235
    echo ""
    echo ""
    printf "    ${C_GREEN}${S_BOLD}${started_count}${S_RESET}${C_SUBTEXT0} containers launched successfully${S_RESET}\n"
    echo ""
    msg_dim "    arr status   — detailed health check"
    msg_dim "    arr logs     — view container logs"
elif [ "$compose_exit" -eq 0 ]; then
    printf "    ${C_GREEN}${S_BOLD}${started_count}${S_RESET}${C_SUBTEXT0}/${total} containers launched${S_RESET}\n"
    local_down=$((total - started_count))
    if [ "$local_down" -gt 0 ]; then
        echo ""
        msg_warn "${local_down} service(s) may not have started. Run ${S_BOLD}arr status${S_RESET}${C_TEXT} to check."
    fi
else
    msg_error "Launch encountered errors (exit code: ${compose_exit})"
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
cleanup_start
trap - EXIT
