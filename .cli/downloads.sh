#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env
require_curl
require_jq || exit 1

source "$CLI_DIR/branding.sh"

DATA_ROOT="$(get_data_root)"

# ── Parse flags ──────────────────────────────────────────────────────────────

LIVE_MODE=true
for arg in "$@"; do
    case "$arg" in
        --once) LIVE_MODE=false ;;
        --watch|--live) LIVE_MODE=true ;;
        *)
            echo "Usage: arr downloads [--once]"
            echo "  Default: live dashboard (refreshes every 3s)"
            echo "  --once   Single snapshot, then exit"
            exit 1
            ;;
    esac
done

# ── Constants ────────────────────────────────────────────────────────────────

FETCH_INTERVAL=3          # Seconds between API fetches
RENDER_INTERVAL=0.1       # Seconds between render frames (10 Hz)
BAR_WIDTH=30              # Progress bar character width
MAX_TORRENT_DL=5          # Max downloading torrents to show
MAX_TORRENT_SEED=5        # Max seeding torrents to show
MAX_SAB_DL=6              # Max SABnzbd items (downloading + queued)
MAX_SAB_HISTORY=3         # Max recent history items

# Unicode fractional blocks for sub-character smooth progress (8x resolution)
BLOCKS=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")

# ── State arrays ─────────────────────────────────────────────────────────────
# We store previous + current snapshots for interpolation.
# Each "item" is: name|percent_float|left_bytes|eta_secs|speed_bps|type
# type: td=torrent downloading, ts=torrent seeding, sd=sab downloading, sq=sab queued, sh=sab history

declare -a PREV_ITEMS=()
declare -a CURR_ITEMS=()
declare -a DISPLAY_PCT=()    # Current interpolated percentage for each item

# Global stats
PREV_T_DL_SPEED=0; CURR_T_DL_SPEED=0
PREV_T_UL_SPEED=0; CURR_T_UL_SPEED=0
PREV_S_SPEED="0"; CURR_S_SPEED="0"
CURR_S_STATUS="Idle"
CURR_T_DL_COUNT=0; CURR_T_SEED_COUNT=0; CURR_T_STOP_COUNT=0; CURR_T_TOTAL=0
CURR_S_DL_COUNT=0; CURR_S_QUEUE_COUNT=0; CURR_S_TOTAL=0
LAST_FETCH_TS=0

# Layout tracking
HEADER_ROWS=0              # Rows used by logo + header (set after first render)
TERM_COLS=80

# ── Graceful cleanup ────────────────────────────────────────────────────────

cleanup() {
    printf '\e[?25h'       # Show cursor
    if $LIVE_MODE; then
        printf '\e[?1049l' # Leave alternate screen
    fi
    exit 0
}

trap cleanup INT TERM EXIT
trap 'read -r _ TERM_COLS < <(stty size 2>/dev/null) || TERM_COLS=80' WINCH

# ── Smooth progress bar ─────────────────────────────────────────────────────
# Renders a bar at exact float percentage with fractional Unicode blocks

smooth_bar() {
    local pct_float=${1:-0}   # e.g. 42.7
    local width=${2:-$BAR_WIDTH}

    # Calculate filled portion with sub-character precision
    local fill_exact
    fill_exact=$(awk "BEGIN { printf \"%.4f\", $pct_float * $width / 100 }")
    local fill_int=${fill_exact%%.*}
    fill_int=${fill_int:-0}

    # Fractional block index (0-7)
    local frac_idx
    frac_idx=$(awk "BEGIN { f = $fill_exact - $fill_int; printf \"%d\", int(f * 8) }")
    [ "$frac_idx" -ge 8 ] && frac_idx=7
    [ "$frac_idx" -lt 0 ] && frac_idx=0

    local empty=$(( width - fill_int - 1 ))
    [ "$empty" -lt 0 ] && empty=0

    # Full blocks
    local bar=""
    if [ "$fill_int" -gt 0 ]; then
        bar=$(printf '%0.s█' $(seq 1 "$fill_int"))
    fi

    # Fractional block (only if not 100%)
    if [ "$fill_int" -lt "$width" ]; then
        bar="${bar}${BLOCKS[$frac_idx]}"
    fi

    # Empty space
    if [ "$empty" -gt 0 ]; then
        bar="${bar}$(printf '%0.s ' $(seq 1 "$empty"))"
    fi

    printf "\e[36m%s\e[0m" "$bar"
}

# ── Data fetching ────────────────────────────────────────────────────────────

fetch_data() {
    # Save previous state for interpolation
    PREV_ITEMS=("${CURR_ITEMS[@]}")
    PREV_T_DL_SPEED=$CURR_T_DL_SPEED
    PREV_T_UL_SPEED=$CURR_T_UL_SPEED
    PREV_S_SPEED="$CURR_S_SPEED"

    CURR_ITEMS=()
    DISPLAY_PCT=()

    # ── Transmission ──

    local session_id
    session_id=$( curl -s --max-time 3 -o /dev/null -D - http://localhost:9091/transmission/rpc 2>/dev/null \
        | grep -i "^X-Transmission-Session-Id:" | head -1 | sed 's/.*: *//;s/[[:space:]]//g' ) || true

    CURR_T_DL_COUNT=0; CURR_T_SEED_COUNT=0; CURR_T_STOP_COUNT=0; CURR_T_TOTAL=0
    CURR_T_DL_SPEED=0; CURR_T_UL_SPEED=0

    if [ -n "$session_id" ]; then
        local stats_json torrents_json
        stats_json=$(curl -s --max-time 3 \
            -H "X-Transmission-Session-Id: $session_id" \
            -d '{"method":"session-stats"}' \
            http://localhost:9091/transmission/rpc 2>/dev/null) || stats_json=""

        torrents_json=$(curl -s --max-time 3 \
            -H "X-Transmission-Session-Id: $session_id" \
            -d '{"method":"torrent-get","arguments":{"fields":["name","status","percentDone","rateDownload","rateUpload","totalSize","sizeWhenDone","eta","uploadRatio","leftUntilDone"]}}' \
            http://localhost:9091/transmission/rpc 2>/dev/null) || torrents_json=""

        if [ -n "$stats_json" ] && echo "$stats_json" | jq -e '.arguments' &>/dev/null; then
            CURR_T_DL_SPEED=$(echo "$stats_json" | jq -r '.arguments.downloadSpeed // 0')
            CURR_T_UL_SPEED=$(echo "$stats_json" | jq -r '.arguments.uploadSpeed // 0')
        fi

        if [ -n "$torrents_json" ] && echo "$torrents_json" | jq -e '.arguments.torrents' &>/dev/null; then
            CURR_T_DL_COUNT=$(echo "$torrents_json" | jq '[.arguments.torrents[] | select(.status == 4)] | length')
            CURR_T_SEED_COUNT=$(echo "$torrents_json" | jq '[.arguments.torrents[] | select(.status == 6)] | length')
            CURR_T_STOP_COUNT=$(echo "$torrents_json" | jq '[.arguments.torrents[] | select(.status == 0)] | length')
            CURR_T_TOTAL=$(echo "$torrents_json" | jq '.arguments.torrents | length')

            # Downloading torrents (max 5)
            while IFS='|' read -r name pct left eta speed; do
                [ -z "$name" ] && continue
                local pct_f
                pct_f=$(awk "BEGIN { printf \"%.2f\", $pct * 100 }")
                CURR_ITEMS+=("${name}|${pct_f}|${left}|${eta}|${speed}|td")
            done < <(echo "$torrents_json" | jq -r "[.arguments.torrents[] | select(.status == 4)][:$MAX_TORRENT_DL][] | \"\(.name)|\(.percentDone)|\(.leftUntilDone)|\(.eta)|\(.rateDownload)\"" 2>/dev/null)

            # Seeding torrents (max 5, sorted by upload speed)
            while IFS='|' read -r name ratio speed; do
                [ -z "$name" ] && continue
                CURR_ITEMS+=("${name}|100|0|0|${speed}|ts:${ratio}")
            done < <(echo "$torrents_json" | jq -r '.arguments.torrents[] | select(.status == 6) | "\(.name)|\(.uploadRatio)|\(.rateUpload)"' 2>/dev/null | sort -t'|' -k3 -rn | head -$MAX_TORRENT_SEED)
        fi
    fi

    # ── SABnzbd ──

    local sab_api_key=""
    if [ -n "$DATA_ROOT" ] && [ -f "$DATA_ROOT/config/sabnzbd/sabnzbd.ini" ]; then
        sab_api_key=$(grep '^api_key' "$DATA_ROOT/config/sabnzbd/sabnzbd.ini" 2>/dev/null | head -1 | awk -F' = ' '{print $2}' | tr -d '[:space:]') || true
    fi

    CURR_S_DL_COUNT=0; CURR_S_QUEUE_COUNT=0; CURR_S_TOTAL=0
    CURR_S_SPEED="0"; CURR_S_STATUS="Idle"

    if [ -n "$sab_api_key" ]; then
        local queue_json
        queue_json=$(curl -s --max-time 3 \
            "http://localhost:8080/api?mode=queue&apikey=${sab_api_key}&output=json" 2>/dev/null) || queue_json=""

        if [ -n "$queue_json" ] && echo "$queue_json" | jq -e '.queue' &>/dev/null; then
            CURR_S_SPEED=$(echo "$queue_json" | jq -r '.queue.speed // "0"' | sed 's/ //g')
            CURR_S_STATUS=$(echo "$queue_json" | jq -r '.queue.status // "Idle"')
            CURR_S_TOTAL=$(echo "$queue_json" | jq -r '.queue.noofslots // 0')

            # Active downloads
            CURR_S_DL_COUNT=$(echo "$queue_json" | jq '[.queue.slots[] | select(.status == "Downloading")] | length')
            while IFS='|' read -r name pct left timeleft; do
                [ -z "$name" ] && continue
                CURR_ITEMS+=("${name}|${pct}|${left}|0|0|sd:${timeleft}")
            done < <(echo "$queue_json" | jq -r '.queue.slots[] | select(.status == "Downloading") | "\(.filename)|\(.percentage)|\(.sizeleft)|\(.timeleft)"' 2>/dev/null)

            # Queued (next 5)
            CURR_S_QUEUE_COUNT=$(echo "$queue_json" | jq '[.queue.slots[] | select(.status != "Downloading")] | length')
            while IFS='|' read -r name size status; do
                [ -z "$name" ] && continue
                CURR_ITEMS+=("${name}|0|0|0|0|sq:${size}")
            done < <(echo "$queue_json" | jq -r "[.queue.slots[] | select(.status != \"Downloading\")][:5][] | \"\(.filename)|\(.size)|\(.status)\"" 2>/dev/null)
        fi

        # Recent history
        local hist_json
        hist_json=$(curl -s --max-time 3 \
            "http://localhost:8080/api?mode=history&apikey=${sab_api_key}&output=json&limit=$MAX_SAB_HISTORY" 2>/dev/null) || hist_json=""

        if [ -n "$hist_json" ] && echo "$hist_json" | jq -e '.history.slots[0]' &>/dev/null; then
            while IFS='|' read -r name size status; do
                [ -z "$name" ] && continue
                CURR_ITEMS+=("${name}|100|0|0|0|sh:${size}:${status}")
            done < <(echo "$hist_json" | jq -r ".history.slots[:$MAX_SAB_HISTORY][] | \"\(.name)|\(.size)|\(.status)\"" 2>/dev/null | sed 's/|/|/g')
        fi
    fi

    # Init display percentages from current data
    for i in "${!CURR_ITEMS[@]}"; do
        local pct
        pct=$(echo "${CURR_ITEMS[$i]}" | cut -d'|' -f2)
        DISPLAY_PCT[$i]="$pct"
    done

    LAST_FETCH_TS=$(date +%s%N 2>/dev/null || date +%s)
}

# ── Frame rendering ──────────────────────────────────────────────────────────
# Builds entire data frame into a buffer, flushes once (single-write)

render_frame() {
    local buf=""
    local row=$((HEADER_ROWS + 1))

    # ── Torrents header ──

    buf+="\e[${row};1H\e[K  \e[1m\e[36mTORRENTS\e[0m \e[2m(Transmission)\e[0m"
    row=$((row + 1))

    if [ "$CURR_T_TOTAL" -eq 0 ] && [ "$CURR_T_DL_SPEED" -eq 0 ]; then
        buf+="\e[${row};1H\e[K  \e[2m──────────────────────────────────────────────────────────────\e[0m"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K    \e[33mNo torrent data available.\e[0m"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
    else
        # Speed line
        local t_dl_h t_ul_h
        t_dl_h=$(human_speed "$CURR_T_DL_SPEED")
        t_ul_h=$(human_speed "$CURR_T_UL_SPEED")
        buf+="\e[${row};1H\e[K  \e[2m──────────────────────────────────────────────\e[0m  \e[32m▼ ${t_dl_h}\e[0m  \e[35m▲ ${t_ul_h}\e[0m"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))

        # Downloading torrents
        if [ "$CURR_T_DL_COUNT" -gt 0 ]; then
            buf+="\e[${row};1H\e[K    \e[1mDOWNLOADING\e[0m \e[2m($CURR_T_DL_COUNT)\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))

            local idx=0
            for i in "${!CURR_ITEMS[@]}"; do
                local item="${CURR_ITEMS[$i]}"
                local type="${item##*|}"
                [ "$type" != "td" ] && continue

                IFS='|' read -r name pct left eta speed tp <<< "$item"
                local name_short="${name:0:55}"
                local pct_disp="${DISPLAY_PCT[$i]:-$pct}"
                local pct_int
                pct_int=$(printf "%.0f" "$pct_disp" 2>/dev/null || echo "0")

                buf+="\e[${row};1H\e[K    ${name_short}"
                row=$((row + 1))

                # Progress bar line — this is the line that gets smooth updates
                local left_h eta_h speed_h
                left_h=$(human_size "${left%%.*}")
                eta_h=$(human_eta "${eta%%.*}")
                speed_h=$(human_speed "${speed%%.*}")

                buf+="\e[${row};1H\e[K    "
                # Bar will be rendered inline
                buf+="BAR_PLACEHOLDER_${i} "
                buf+=$(printf " %3d%%   %s left   ETA %s   %s" "$pct_int" "$left_h" "$eta_h" "$speed_h")
                row=$((row + 1))
                buf+="\e[${row};1H\e[K"
                row=$((row + 1))

                idx=$((idx + 1))
            done
            if [ "$CURR_T_DL_COUNT" -gt "$MAX_TORRENT_DL" ]; then
                buf+="\e[${row};1H\e[K    \e[2m... and $((CURR_T_DL_COUNT - MAX_TORRENT_DL)) more downloading\e[0m"
                row=$((row + 1))
                buf+="\e[${row};1H\e[K"
                row=$((row + 1))
            fi
        fi

        # Seeding torrents
        if [ "$CURR_T_SEED_COUNT" -gt 0 ]; then
            buf+="\e[${row};1H\e[K    \e[1mSEEDING\e[0m \e[2m($CURR_T_SEED_COUNT)\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))

            for i in "${!CURR_ITEMS[@]}"; do
                local item="${CURR_ITEMS[$i]}"
                local type="${item##*|}"
                [[ "$type" != ts:* ]] && continue

                IFS='|' read -r name pct left eta speed tp <<< "$item"
                local ratio="${tp#ts:}"
                local name_short="${name:0:40}"
                local ratio_fmt
                ratio_fmt=$(printf "%.2f" "$ratio" 2>/dev/null || echo "0.00")
                local speed_h
                speed_h=$(human_speed "${speed%%.*}")
                buf+="\e[${row};1H\e[K    \e[2m$(printf '%-42s' "$name_short")\e[0m ratio \e[1m${ratio_fmt}\e[0m  \e[35m▲ ${speed_h}\e[0m"
                row=$((row + 1))
            done
            if [ "$CURR_T_SEED_COUNT" -gt "$MAX_TORRENT_SEED" ]; then
                buf+="\e[${row};1H\e[K    \e[2m... and $((CURR_T_SEED_COUNT - MAX_TORRENT_SEED)) more\e[0m"
                row=$((row + 1))
            fi
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))
        fi

        # Stopped
        if [ "$CURR_T_STOP_COUNT" -gt 0 ] && [ "$CURR_T_DL_COUNT" -eq 0 ] && [ "$CURR_T_SEED_COUNT" -eq 0 ]; then
            buf+="\e[${row};1H\e[K    \e[2m$CURR_T_STOP_COUNT paused torrents\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))
        fi

        if [ "$CURR_T_TOTAL" -eq 0 ]; then
            buf+="\e[${row};1H\e[K    \e[2mNo torrents.\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))
        fi
    fi

    # ── Usenet header ──

    buf+="\e[${row};1H\e[K  \e[1m\e[36mUSENET\e[0m \e[2m(SABnzbd)\e[0m"
    row=$((row + 1))

    if [ "$CURR_S_TOTAL" -eq 0 ] && [ "$CURR_S_SPEED" = "0" ]; then
        buf+="\e[${row};1H\e[K  \e[2m──────────────────────────────────────────────\e[0m  \e[32m▼ 0\e[0m  \e[2m${CURR_S_STATUS}\e[0m"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K    \e[2mNo downloads.\e[0m"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
    else
        buf+="\e[${row};1H\e[K  \e[2m──────────────────────────────────────────────\e[0m  \e[32m▼ ${CURR_S_SPEED}\e[0m  \e[2m${CURR_S_STATUS}\e[0m"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))

        # SAB Downloading
        if [ "$CURR_S_DL_COUNT" -gt 0 ]; then
            buf+="\e[${row};1H\e[K    \e[1mDOWNLOADING\e[0m \e[2m($CURR_S_DL_COUNT)\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))

            for i in "${!CURR_ITEMS[@]}"; do
                local item="${CURR_ITEMS[$i]}"
                local type="${item##*|}"
                [[ "$type" != sd:* ]] && continue

                IFS='|' read -r name pct left eta speed tp <<< "$item"
                local timeleft="${tp#sd:}"
                local name_short="${name:0:55}"
                local pct_disp="${DISPLAY_PCT[$i]:-$pct}"
                local pct_int
                pct_int=$(printf "%.0f" "$pct_disp" 2>/dev/null || echo "0")

                buf+="\e[${row};1H\e[K    ${name_short}"
                row=$((row + 1))
                buf+="\e[${row};1H\e[K    BAR_PLACEHOLDER_${i} "
                buf+=$(printf " %3d%%   %s left   ETA %s" "$pct_int" "$left" "$timeleft")
                row=$((row + 1))
                buf+="\e[${row};1H\e[K"
                row=$((row + 1))
            done
        fi

        # SAB Queued
        if [ "$CURR_S_QUEUE_COUNT" -gt 0 ]; then
            local show_q=$(( CURR_S_QUEUE_COUNT < 5 ? CURR_S_QUEUE_COUNT : 5 ))
            buf+="\e[${row};1H\e[K    \e[1mQUEUED\e[0m \e[2m($CURR_S_QUEUE_COUNT total, showing $show_q)\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))

            for i in "${!CURR_ITEMS[@]}"; do
                local item="${CURR_ITEMS[$i]}"
                local type="${item##*|}"
                [[ "$type" != sq:* ]] && continue

                IFS='|' read -r name pct left eta speed tp <<< "$item"
                local size="${tp#sq:}"
                local name_short="${name:0:48}"
                buf+="\e[${row};1H\e[K    \e[2m○\e[0m $(printf '%-50s' "$name_short") $size"
                row=$((row + 1))
            done
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))
        fi

        if [ "$CURR_S_TOTAL" -eq 0 ] && [ "$CURR_S_DL_COUNT" -eq 0 ]; then
            buf+="\e[${row};1H\e[K    \e[2mNo downloads.\e[0m"
            row=$((row + 1))
            buf+="\e[${row};1H\e[K"
            row=$((row + 1))
        fi
    fi

    # SAB Recent history
    local has_history=false
    for i in "${!CURR_ITEMS[@]}"; do
        local type="${CURR_ITEMS[$i]##*|}"
        if [[ "$type" == sh:* ]]; then
            if ! $has_history; then
                buf+="\e[${row};1H\e[K    \e[1mRECENT\e[0m"
                row=$((row + 1))
                buf+="\e[${row};1H\e[K"
                row=$((row + 1))
                has_history=true
            fi
            IFS='|' read -r name pct left eta speed tp <<< "${CURR_ITEMS[$i]}"
            # tp is sh:SIZE:STATUS
            local rest="${tp#sh:}"
            local size="${rest%%:*}"
            local status="${rest#*:}"
            local name_short="${name:0:42}"
            if [ "$status" = "Completed" ]; then
                buf+="\e[${row};1H\e[K    \e[32m✓\e[0m $(printf '%-44s' "$name_short") $size"
            elif [ "$status" = "Failed" ]; then
                buf+="\e[${row};1H\e[K    \e[31m✗\e[0m $(printf '%-44s' "$name_short") $size"
            else
                buf+="\e[${row};1H\e[K    \e[2m○\e[0m $(printf '%-44s' "$name_short") $size"
            fi
            row=$((row + 1))
        fi
    done
    if $has_history; then
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
    fi

    # ── Summary ──

    buf+="\e[${row};1H\e[K  \e[2m──────────────────────────────────────────────────────────────\e[0m"
    row=$((row + 1))
    buf+="\e[${row};1H\e[K"
    row=$((row + 1))

    local total_active=$((CURR_T_DL_COUNT + CURR_S_DL_COUNT))
    buf+="\e[${row};1H\e[K  \e[1mTotal:\e[0m ${total_active} downloading, ${CURR_T_SEED_COUNT} seeding, ${CURR_S_QUEUE_COUNT} queued, ${CURR_T_STOP_COUNT} paused"
    row=$((row + 1))

    if $LIVE_MODE; then
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
        buf+="\e[${row};1H\e[K  \e[2mLive • Ctrl+C to exit\e[0m"
        row=$((row + 1))
    fi

    # Clear any leftover lines from previous longer frame
    local clear_to=$((row + 5))
    while [ "$row" -le "$clear_to" ]; do
        buf+="\e[${row};1H\e[K"
        row=$((row + 1))
    done

    # Now replace BAR_PLACEHOLDER_N with actual rendered bars
    # We do this by printing the buffer and letting the bars render inline
    # Actually, let's just output the buffer and render bars with separate cursor jumps

    # First pass: output everything except bar placeholders
    printf '\e[?2026h'  # Begin synchronized update

    # We need to handle bars specially - output buffer line by line
    local IFS_BAK="$IFS"
    local line_row=$((HEADER_ROWS + 1))

    # Just output the whole buffer - bars get rendered separately after
    printf '%b' "$buf"

    # Second pass: render actual progress bars at their positions
    for i in "${!CURR_ITEMS[@]}"; do
        local item="${CURR_ITEMS[$i]}"
        local type="${item##*|}"
        if [ "$type" = "td" ] || [[ "$type" == sd:* ]]; then
            local pct_disp="${DISPLAY_PCT[$i]:-0}"
            # Find the BAR_PLACEHOLDER row - search for it in buffer
            # We marked them, now just overwrite at the correct position
            # The placeholder text "BAR_PLACEHOLDER_N " is at column 5
            # Find which output line has this placeholder
            local placeholder="BAR_PLACEHOLDER_${i}"
            # Count which line of the rendered output has this placeholder
            local found_row=""
            local scan_row=$((HEADER_ROWS + 1))
            # We'll use a simpler approach: track bar positions during render
        fi
    done

    printf '\e[?2026l'  # End synchronized update
}

# ── Simpler but premium approach ─────────────────────────────────────────────
# Instead of the complex placeholder system, we render to a buffer with
# cursor positioning, and separately render bars at known positions.

render_full_frame() {
    local buf=""
    local row=$((HEADER_ROWS + 1))
    local bar_rows=()       # Array of "row_number:item_index" for bar positions

    # Helper to add a line
    addln() {
        buf+="\e[${row};1H\e[K${1}"
        row=$((row + 1))
    }

    # ── TORRENTS ──
    addln "  \e[1m\e[36mTORRENTS\e[0m \e[2m(Transmission)\e[0m"

    if [ "$CURR_T_TOTAL" -eq 0 ] && [ "$CURR_T_DL_SPEED" -eq 0 ]; then
        addln "  \e[2m──────────────────────────────────────────────────────────────\e[0m"
        addln ""
        addln "    \e[33mNo torrent data available.\e[0m"
        addln ""
    else
        local t_dl_h t_ul_h
        t_dl_h=$(human_speed "$CURR_T_DL_SPEED")
        t_ul_h=$(human_speed "$CURR_T_UL_SPEED")
        addln "  \e[2m──────────────────────────────────────────────\e[0m  \e[32m▼ ${t_dl_h}\e[0m  \e[35m▲ ${t_ul_h}\e[0m"
        addln ""

        if [ "$CURR_T_DL_COUNT" -gt 0 ]; then
            addln "    \e[1mDOWNLOADING\e[0m \e[2m($CURR_T_DL_COUNT)\e[0m"
            addln ""

            for i in "${!CURR_ITEMS[@]}"; do
                local item="${CURR_ITEMS[$i]}"
                local type="${item##*|}"
                [ "$type" != "td" ] && continue

                IFS='|' read -r name pct left eta speed tp <<< "$item"
                addln "    ${name:0:55}"

                # Record this row for bar rendering
                bar_rows+=("${row}:${i}")

                local pct_disp="${DISPLAY_PCT[$i]:-$pct}"
                local pct_int
                pct_int=$(printf "%.0f" "$pct_disp" 2>/dev/null || echo "0")
                local left_h eta_h speed_h
                left_h=$(human_size "${left%%.*}")
                eta_h=$(human_eta "${eta%%.*}")
                speed_h=$(human_speed "${speed%%.*}")

                # Leave space for bar (rendered separately), then stats
                buf+="\e[${row};1H\e[K    "
                # Bar placeholder - 30 chars wide, will be overwritten
                buf+="$(printf '%*s' $BAR_WIDTH '')"
                buf+=$(printf "  %3d%%   %s left   ETA %s   %s" "$pct_int" "$left_h" "$eta_h" "$speed_h")
                row=$((row + 1))

                addln ""
            done

            if [ "$CURR_T_DL_COUNT" -gt "$MAX_TORRENT_DL" ]; then
                addln "    \e[2m... and $((CURR_T_DL_COUNT - MAX_TORRENT_DL)) more downloading\e[0m"
                addln ""
            fi
        fi

        if [ "$CURR_T_SEED_COUNT" -gt 0 ]; then
            addln "    \e[1mSEEDING\e[0m \e[2m($CURR_T_SEED_COUNT)\e[0m"
            addln ""
            for i in "${!CURR_ITEMS[@]}"; do
                local item="${CURR_ITEMS[$i]}"
                local type="${item##*|}"
                [[ "$type" != ts:* ]] && continue
                IFS='|' read -r name pct left eta speed tp <<< "$item"
                local ratio="${tp#ts:}"
                local ratio_fmt
                ratio_fmt=$(printf "%.2f" "$ratio" 2>/dev/null || echo "0.00")
                local speed_h
                speed_h=$(human_speed "${speed%%.*}")
                addln "    \e[2m$(printf '%-42s' "${name:0:40}")\e[0m ratio \e[1m${ratio_fmt}\e[0m  \e[35m▲ ${speed_h}\e[0m"
            done
            if [ "$CURR_T_SEED_COUNT" -gt "$MAX_TORRENT_SEED" ]; then
                addln "    \e[2m... and $((CURR_T_SEED_COUNT - MAX_TORRENT_SEED)) more\e[0m"
            fi
            addln ""
        fi

        if [ "$CURR_T_STOP_COUNT" -gt 0 ] && [ "$CURR_T_DL_COUNT" -eq 0 ] && [ "$CURR_T_SEED_COUNT" -eq 0 ]; then
            addln "    \e[2m$CURR_T_STOP_COUNT paused torrents\e[0m"
            addln ""
        fi
        if [ "$CURR_T_TOTAL" -eq 0 ]; then
            addln "    \e[2mNo torrents.\e[0m"
            addln ""
        fi
    fi

    # ── USENET ──
    addln "  \e[1m\e[36mUSENET\e[0m \e[2m(SABnzbd)\e[0m"
    addln "  \e[2m──────────────────────────────────────────────\e[0m  \e[32m▼ ${CURR_S_SPEED}\e[0m  \e[2m${CURR_S_STATUS}\e[0m"
    addln ""

    if [ "$CURR_S_DL_COUNT" -gt 0 ]; then
        addln "    \e[1mDOWNLOADING\e[0m \e[2m($CURR_S_DL_COUNT)\e[0m"
        addln ""
        for i in "${!CURR_ITEMS[@]}"; do
            local item="${CURR_ITEMS[$i]}"
            local type="${item##*|}"
            [[ "$type" != sd:* ]] && continue
            IFS='|' read -r name pct left eta speed tp <<< "$item"
            local timeleft="${tp#sd:}"
            addln "    ${name:0:55}"
            bar_rows+=("${row}:${i}")
            local pct_disp="${DISPLAY_PCT[$i]:-$pct}"
            local pct_int
            pct_int=$(printf "%.0f" "$pct_disp" 2>/dev/null || echo "0")
            buf+="\e[${row};1H\e[K    $(printf '%*s' $BAR_WIDTH '')$(printf "  %3d%%   %s left   ETA %s" "$pct_int" "$left" "$timeleft")"
            row=$((row + 1))
            addln ""
        done
    fi

    if [ "$CURR_S_QUEUE_COUNT" -gt 0 ]; then
        local show_q=$(( CURR_S_QUEUE_COUNT < 5 ? CURR_S_QUEUE_COUNT : 5 ))
        addln "    \e[1mQUEUED\e[0m \e[2m($CURR_S_QUEUE_COUNT total, showing $show_q)\e[0m"
        addln ""
        for i in "${!CURR_ITEMS[@]}"; do
            local item="${CURR_ITEMS[$i]}"
            local type="${item##*|}"
            [[ "$type" != sq:* ]] && continue
            IFS='|' read -r name pct left eta speed tp <<< "$item"
            local size="${tp#sq:}"
            addln "    \e[2m○\e[0m $(printf '%-50s' "${name:0:48}") $size"
        done
        addln ""
    fi

    if [ "$CURR_S_TOTAL" -eq 0 ] && [ "$CURR_S_DL_COUNT" -eq 0 ]; then
        addln "    \e[2mNo downloads.\e[0m"
        addln ""
    fi

    # History
    local has_hist=false
    for i in "${!CURR_ITEMS[@]}"; do
        local type="${CURR_ITEMS[$i]##*|}"
        if [[ "$type" == sh:* ]]; then
            if ! $has_hist; then
                addln "    \e[1mRECENT\e[0m"
                addln ""
                has_hist=true
            fi
            IFS='|' read -r name pct left eta speed tp <<< "${CURR_ITEMS[$i]}"
            local rest="${tp#sh:}"
            local size="${rest%%:*}"
            local status="${rest#*:}"
            if [ "$status" = "Completed" ]; then
                addln "    \e[32m✓\e[0m $(printf '%-44s' "${name:0:42}") $size"
            elif [ "$status" = "Failed" ]; then
                addln "    \e[31m✗\e[0m $(printf '%-44s' "${name:0:42}") $size"
            else
                addln "    \e[2m○\e[0m $(printf '%-44s' "${name:0:42}") $size"
            fi
        fi
    done
    $has_hist && addln ""

    # Summary
    addln "  \e[2m──────────────────────────────────────────────────────────────\e[0m"
    addln ""
    local total_active=$((CURR_T_DL_COUNT + CURR_S_DL_COUNT))
    addln "  \e[1mTotal:\e[0m ${total_active} downloading, ${CURR_T_SEED_COUNT} seeding, ${CURR_S_QUEUE_COUNT} queued, ${CURR_T_STOP_COUNT} paused"
    if $LIVE_MODE; then
        addln ""
        addln "  \e[2mLive • Ctrl+C to exit\e[0m"
    fi
    addln ""

    # Clear leftover lines
    for _ in 1 2 3 4 5; do addln ""; done

    # ── Flush frame atomically ──
    printf '\e[?2026h'  # Begin synchronized update
    printf '%b' "$buf"

    # Render smooth bars at recorded positions
    for br in "${bar_rows[@]}"; do
        local brow="${br%%:*}"
        local bidx="${br#*:}"
        local pct_disp="${DISPLAY_PCT[$bidx]:-0}"
        printf "\e[${brow};5H"
        smooth_bar "$pct_disp" "$BAR_WIDTH"
    done

    printf '\e[?2026l'  # End synchronized update

    # Export bar_rows for interpolation updates
    BAR_POSITIONS=("${bar_rows[@]}")
}

# ── Interpolation-only update (between fetches) ─────────────────────────────
# Only touches progress bars and their stats — everything else stays untouched

update_bars_only() {
    local now
    now=$(date +%s%N 2>/dev/null || date +%s)
    local elapsed
    elapsed=$(awk "BEGIN { printf \"%.3f\", ($now - $LAST_FETCH_TS) / 1000000000 }" 2>/dev/null || echo "0")
    local t
    t=$(awk "BEGIN { v = $elapsed / $FETCH_INTERVAL; if (v > 1) v = 1; print v }" 2>/dev/null || echo "1")

    # Ease-out quadratic for smooth deceleration: t * (2 - t)
    local eased
    eased=$(awk "BEGIN { printf \"%.4f\", $t * (2 - $t) }" 2>/dev/null || echo "$t")

    local any_change=false

    for i in "${!CURR_ITEMS[@]}"; do
        local item="${CURR_ITEMS[$i]}"
        local type="${item##*|}"
        [ "$type" != "td" ] && [[ "$type" != sd:* ]] && continue

        local curr_pct
        curr_pct=$(echo "$item" | cut -d'|' -f2)

        # Find matching previous item for interpolation
        local prev_pct="$curr_pct"
        if [ "${#PREV_ITEMS[@]}" -gt 0 ]; then
            # Try to match by name
            local curr_name
            curr_name=$(echo "$item" | cut -d'|' -f1)
            for pi in "${!PREV_ITEMS[@]}"; do
                local prev_name
                prev_name=$(echo "${PREV_ITEMS[$pi]}" | cut -d'|' -f1)
                if [ "$prev_name" = "$curr_name" ]; then
                    prev_pct=$(echo "${PREV_ITEMS[$pi]}" | cut -d'|' -f2)
                    break
                fi
            done
        fi

        # Interpolate: prev + (curr - prev) * eased_t
        local interp
        interp=$(awk "BEGIN { printf \"%.2f\", $prev_pct + ($curr_pct - $prev_pct) * $eased }" 2>/dev/null || echo "$curr_pct")

        if [ "${DISPLAY_PCT[$i]:-}" != "$interp" ]; then
            DISPLAY_PCT[$i]="$interp"
            any_change=true
        fi
    done

    if $any_change && [ "${#BAR_POSITIONS[@]}" -gt 0 ]; then
        printf '\e[?2026h'  # Synchronized update

        for br in "${BAR_POSITIONS[@]}"; do
            local brow="${br%%:*}"
            local bidx="${br#*:}"
            local pct_disp="${DISPLAY_PCT[$bidx]:-0}"
            local pct_int
            pct_int=$(printf "%.0f" "$pct_disp" 2>/dev/null || echo "0")

            # Update bar
            printf "\e[${brow};5H"
            smooth_bar "$pct_disp" "$BAR_WIDTH"

            # Update percentage number (column after bar)
            printf "  %3d%%" "$pct_int"
        done

        printf '\e[?2026l'
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

BAR_POSITIONS=()

if $LIVE_MODE; then
    # Enter alternate screen, clear, hide cursor
    printf '\e[?1049h'
    printf '\e[2J\e[H'
    printf '\e[?25l'

    # Show logo and header once
    show_logo
    show_header "Arr Media Stack  —  Downloads"
    echo ""

    # Calculate header height
    HEADER_ROWS=$(stty size 2>/dev/null | awk '{print 0}')
    # Actually measure by cursor position
    HEADER_ROWS=$(printf '\e[6n' > /dev/tty 2>/dev/null; read -s -d R -t 1 pos < /dev/tty 2>/dev/null; echo "${pos#*[}" | cut -d';' -f1)
    if [ -z "$HEADER_ROWS" ] || ! [[ "$HEADER_ROWS" =~ ^[0-9]+$ ]]; then
        HEADER_ROWS=10
    fi
    HEADER_ROWS=$((HEADER_ROWS - 1))

    # Initial data fetch and render
    fetch_data
    render_full_frame

    # Main loop: fast render for interpolation, slow fetch for data
    FRAME_COUNT=0
    FRAMES_PER_FETCH=$(awk "BEGIN { printf \"%d\", $FETCH_INTERVAL / $RENDER_INTERVAL }" 2>/dev/null || echo 30)

    while true; do
        sleep "$RENDER_INTERVAL"
        FRAME_COUNT=$((FRAME_COUNT + 1))

        if [ "$FRAME_COUNT" -ge "$FRAMES_PER_FETCH" ]; then
            FRAME_COUNT=0
            fetch_data
            render_full_frame
        else
            update_bars_only
        fi
    done
else
    show_logo
    show_header "Arr Media Stack  —  Downloads"
    echo ""
    fetch_data
    # For --once mode, set display pcts directly and render
    for i in "${!CURR_ITEMS[@]}"; do
        DISPLAY_PCT[$i]=$(echo "${CURR_ITEMS[$i]}" | cut -d'|' -f2)
    done
    render_full_frame
fi
