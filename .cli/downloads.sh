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
        --live) LIVE_MODE=true ;;
    esac
done

# ── Constants ────────────────────────────────────────────────────────────────

BAR_WIDTH=30
FETCH_INTERVAL=5
NAME_MAX=55
MAX_T_DL=5
MAX_T_SEED=5
MAX_S_DL=5
MAX_S_QUEUE=3
MAX_S_HIST=3

# Unicode fractional blocks
BLOCKS=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")

# ── Bar cache ────────────────────────────────────────────────────────────────

declare -a BAR_FULL=()
_build_bar_cache() {
    local s=""
    BAR_FULL[0]=""
    for (( i=1; i<=BAR_WIDTH; i++ )); do
        s+="█"
        BAR_FULL[$i]="$s"
    done
}
_build_bar_cache

declare -a SPACE_PAD=()
_build_space_cache() {
    local s=""
    SPACE_PAD[0]=""
    for (( i=1; i<=BAR_WIDTH+10; i++ )); do
        s+=" "
        SPACE_PAD[$i]="$s"
    done
}
_build_space_cache

# ── SABnzbd API key ─────────────────────────────────────────────────────────

SAB_API_KEY=""
_get_sab_key() {
    local ini="$DATA_ROOT/config/sabnzbd/sabnzbd.ini"
    if [[ -f "$ini" ]]; then
        local line
        while IFS= read -r line; do
            if [[ "$line" == api_key* ]]; then
                SAB_API_KEY="${line##*= }"
                SAB_API_KEY="${SAB_API_KEY## }"
                SAB_API_KEY="${SAB_API_KEY%% }"
                break
            fi
        done < "$ini"
    fi
}
_get_sab_key

# ── Temp files + cleanup ────────────────────────────────────────────────────

FETCH_TMP=$(mktemp /tmp/arr-dl-data.XXXXXX)
FETCH_SIGNAL=$(mktemp /tmp/arr-dl-sig.XXXXXX)
rm -f "$FETCH_SIGNAL"
FETCH_BG_PID=""

cleanup() {
    rm -f "$FETCH_TMP" "${FETCH_TMP}.new" "$FETCH_SIGNAL"
    if $LIVE_MODE; then
        printf '\e[?25h'
        printf '\e[?1049l'
    fi
    [[ -n "${FETCH_BG_PID:-}" ]] && kill "$FETCH_BG_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── State arrays ─────────────────────────────────────────────────────────────

declare -a ITEM_NAMES=()
declare -a ITEM_DETAIL=()
declare -a ITEM_TYPE=()       # td=torrent dl, ts=seed, tp=stopped, sd=sab dl, sq=queued, sh=history
declare -a ITEM_PCT_X100=()   # 0-10000
declare -a ITEM_PREV_X100=()
declare -a DISPLAY_PCT_X100=()

T_HEADER_LINE=""
T_SPEED_LINE=""
S_HEADER_LINE=""
S_SPEED_LINE=""
SUMMARY_LINE=""
CURR_T_DL=0
CURR_T_SEED=0
CURR_T_STOP=0
CURR_S_DL=0
CURR_S_QUEUE=0
CURR_S_HIST=0
HAS_DATA=false

LAST_FETCH_MS=0
FETCH_RUNNING=false
FIRST_FETCH=true

# ── fetch_data (runs in background subshell) ────────────────────────────────

fetch_data() {
    local items_names=()
    local items_detail=()
    local items_type=()
    local items_pct=()
    local t_dl=0 t_seed=0 t_stop=0
    local s_dl=0 s_queue=0 s_hist=0
    local t_header="" t_speed=""
    local s_header="" s_speed=""
    local summary=""
    local t_dl_speed=0 t_ul_speed=0

    # ── Get Transmission session ID (must be sequential) ─────────────────

    local sid=""
    local headers
    headers=$(curl -s -o /dev/null -D - --max-time 3 \
        http://localhost:9091/transmission/rpc 2>/dev/null || true)
    while IFS= read -r hline; do
        if [[ "$hline" == X-Transmission-Session-Id:* ]]; then
            sid="${hline#X-Transmission-Session-Id: }"
            sid="${sid%%$'\r'}"
            sid="${sid%% }"
        fi
    done <<< "$headers"

    # ── Launch all 4 curls in parallel ───────────────────────────────────

    local t_stats_file t_torrents_file sab_queue_file sab_hist_file
    t_stats_file=$(mktemp /tmp/arr-dl-ts.XXXXXX)
    t_torrents_file=$(mktemp /tmp/arr-dl-tt.XXXXXX)
    sab_queue_file=$(mktemp /tmp/arr-dl-sq.XXXXXX)
    sab_hist_file=$(mktemp /tmp/arr-dl-sh.XXXXXX)

    local pids_to_wait=()

    if [[ -n "$sid" ]]; then
        curl -s --max-time 3 \
            -H "X-Transmission-Session-Id: $sid" \
            -d '{"method":"session-stats"}' \
            http://localhost:9091/transmission/rpc \
            > "$t_stats_file" 2>/dev/null &
        pids_to_wait+=($!)

        curl -s --max-time 3 \
            -H "X-Transmission-Session-Id: $sid" \
            -d '{"method":"torrent-get","arguments":{"fields":["name","status","percentDone","rateDownload","rateUpload","eta","uploadRatio","leftUntilDone"]}}' \
            http://localhost:9091/transmission/rpc \
            > "$t_torrents_file" 2>/dev/null &
        pids_to_wait+=($!)
    fi

    if [[ -n "$SAB_API_KEY" ]]; then
        curl -s --max-time 3 \
            "http://localhost:8080/api?mode=queue&apikey=${SAB_API_KEY}&output=json" \
            > "$sab_queue_file" 2>/dev/null &
        pids_to_wait+=($!)

        curl -s --max-time 3 \
            "http://localhost:8080/api?mode=history&apikey=${SAB_API_KEY}&output=json&limit=3" \
            > "$sab_hist_file" 2>/dev/null &
        pids_to_wait+=($!)
    fi

    # Wait for all parallel curls
    local pid
    for pid in "${pids_to_wait[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # ── Parse Transmission stats (single jq) ─────────────────────────────

    if [[ -n "$sid" && -s "$t_stats_file" ]]; then
        local stats_line
        stats_line=$(jq -r '"\(.arguments.downloadSpeed // 0)|\(.arguments.uploadSpeed // 0)"' \
            < "$t_stats_file" 2>/dev/null || echo "0|0")
        t_dl_speed="${stats_line%%|*}"
        t_ul_speed="${stats_line##*|}"
    fi

    # ── Parse Transmission torrents (single jq) ─────────────────────────

    if [[ -n "$sid" && -s "$t_torrents_file" ]]; then
        local torrent_lines
        torrent_lines=$(jq -r '[.arguments.torrents[]?] | sort_by(-.percentDone) | .[] | "\(.name)|\(.status)|\(.percentDone)|\(.rateDownload)|\(.rateUpload)|\(.eta // -1)|\(.uploadRatio)|\(.leftUntilDone)"' \
            < "$t_torrents_file" 2>/dev/null || true)

        if [[ -n "$torrent_lines" ]]; then
            while IFS='|' read -r tname tstatus tpct trate_dl trate_ul teta tratio tleft; do
                [[ -z "$tname" ]] && continue

                # Truncate name
                local dname="$tname"
                if (( ${#dname} > NAME_MAX )); then
                    dname="${dname:0:$((NAME_MAX - 3))}..."
                fi

                # Convert float 0.0-1.0 to integer *10000
                local pct_x100
                if [[ "$tpct" == *"."* ]]; then
                    local int_part="${tpct%%.*}"
                    local frac_str="${tpct#*.}"
                    frac_str="${frac_str}0000"
                    frac_str="${frac_str:0:4}"
                    pct_x100=$(( ${int_part:-0} * 10000 + 10#${frac_str} ))
                else
                    pct_x100=$(( ${tpct:-0} * 10000 ))
                fi
                (( pct_x100 > 10000 )) && pct_x100=10000

                case "$tstatus" in
                    4) # downloading
                        t_dl=$(( t_dl + 1 ))
                        local left_h speed_h eta_h
                        left_h=$(human_size "${tleft:-0}")
                        speed_h=$(human_speed "${trate_dl:-0}")
                        eta_h=$(human_eta "${teta:--1}")
                        items_names+=("$dname")
                        items_detail+=("${left_h} left   ETA ${eta_h}   ${speed_h}")
                        items_type+=("td")
                        items_pct+=("$pct_x100")
                        ;;
                    6) # seeding
                        t_seed=$(( t_seed + 1 ))
                        local ul_h
                        ul_h=$(human_speed "${trate_ul:-0}")
                        items_names+=("$dname")
                        items_detail+=("ratio ${tratio:-0}  ▲ ${ul_h}")
                        items_type+=("ts")
                        items_pct+=("10000")
                        ;;
                    0) # stopped
                        t_stop=$(( t_stop + 1 ))
                        items_names+=("$dname")
                        items_detail+=("stopped")
                        items_type+=("tp")
                        items_pct+=("$pct_x100")
                        ;;
                esac
            done <<< "$torrent_lines"
        fi
    fi

    local t_dl_h t_ul_h
    t_dl_h=$(human_speed "$t_dl_speed")
    t_ul_h=$(human_speed "$t_ul_speed")
    t_header="TORRENTS (Transmission)"
    t_speed="▼ ${t_dl_h}  ▲ ${t_ul_h}"

    # ── Parse SABnzbd queue (single jq) ──────────────────────────────────

    local s_dl_speed_h="" s_status_str=""

    if [[ -n "$SAB_API_KEY" && -s "$sab_queue_file" ]]; then
        local sab_meta
        sab_meta=$(jq -r '"\(.queue.speed // "0 B")|\(.queue.status // "Unknown")"' \
            < "$sab_queue_file" 2>/dev/null || echo "0 B|Unknown")
        s_dl_speed_h="${sab_meta%%|*}"
        s_status_str="${sab_meta##*|}"

        # Extract slots, sort downloading by percentage DESC (most complete first)
        local sab_dl_lines sab_queue_lines
        sab_dl_lines=$(jq -r '.queue.slots[]? | select(.status == "Downloading") | "\(.filename)|\(.percentage)|\(.sizeleft)|\(.timeleft)"' \
            < "$sab_queue_file" 2>/dev/null || true)
        sab_queue_lines=$(jq -r '.queue.slots[]? | select(.status != "Downloading") | "\(.filename)|\(.sizeleft)"' \
            < "$sab_queue_file" 2>/dev/null || true)

        # Count totals (all items)
        if [[ -n "$sab_dl_lines" ]]; then
            s_dl=$(echo "$sab_dl_lines" | wc -l)
        fi
        if [[ -n "$sab_queue_lines" ]]; then
            s_queue=$(echo "$sab_queue_lines" | wc -l)
        fi

        # Add downloading items (limited to MAX_S_DL, sorted most complete first)
        local s_dl_shown=0
        if [[ -n "$sab_dl_lines" ]]; then
            while IFS='|' read -r sname spct ssizeleft stimeleft; do
                [[ -z "$sname" ]] && continue
                (( s_dl_shown >= MAX_S_DL )) && continue

                local dname="$sname"
                if (( ${#dname} > NAME_MAX )); then
                    dname="${dname:0:$((NAME_MAX - 3))}..."
                fi
                local pct_x100=$(( spct * 100 ))
                items_names+=("$dname")
                items_detail+=("${ssizeleft} left   ETA ${stimeleft}")
                items_type+=("sd")
                items_pct+=("$pct_x100")
                s_dl_shown=$(( s_dl_shown + 1 ))
            done <<< "$sab_dl_lines"
        fi

        # Add queued items (limited to MAX_S_QUEUE)
        local s_queue_shown=0
        if [[ -n "$sab_queue_lines" ]]; then
            while IFS='|' read -r sname ssizeleft; do
                [[ -z "$sname" ]] && continue
                (( s_queue_shown >= MAX_S_QUEUE )) && continue

                local dname="$sname"
                if (( ${#dname} > NAME_MAX )); then
                    dname="${dname:0:$((NAME_MAX - 3))}..."
                fi
                items_names+=("$dname")
                items_detail+=("${ssizeleft}")
                items_type+=("sq")
                items_pct+=("0")
                s_queue_shown=$(( s_queue_shown + 1 ))
            done <<< "$sab_queue_lines"
        fi
    fi

    # ── Parse SABnzbd history (single jq) ────────────────────────────────

    if [[ -n "$SAB_API_KEY" && -s "$sab_hist_file" ]]; then
        local sab_hist_lines
        sab_hist_lines=$(jq -r '.history.slots[]? | "\(.name)|\(.size)|\(.status)"' \
            < "$sab_hist_file" 2>/dev/null || true)

        if [[ -n "$sab_hist_lines" ]]; then
            while IFS='|' read -r hname hsize hstatus; do
                [[ -z "$hname" ]] && continue

                local dname="$hname"
                if (( ${#dname} > NAME_MAX )); then
                    dname="${dname:0:$((NAME_MAX - 3))}..."
                fi

                s_hist=$(( s_hist + 1 ))
                items_names+=("$dname")
                items_detail+=("${hsize}|${hstatus}")
                items_type+=("sh")
                items_pct+=("10000")
            done <<< "$sab_hist_lines"
        fi
    fi

    # Cleanup temp curl files
    rm -f "$t_stats_file" "$t_torrents_file" "$sab_queue_file" "$sab_hist_file"

    s_header="USENET (SABnzbd)"
    s_speed="▼ ${s_dl_speed_h:-0 B}  ${s_status_str:-Unknown}"

    # Summary
    local parts=()
    (( t_dl + s_dl > 0 )) && parts+=("$(( t_dl + s_dl )) downloading")
    (( t_seed > 0 )) && parts+=("${t_seed} seeding")
    (( s_queue > 0 )) && parts+=("${s_queue} queued")
    (( t_stop > 0 )) && parts+=("${t_stop} stopped")

    if (( ${#parts[@]} > 0 )); then
        summary="Total: ${parts[0]}"
        local pi
        for (( pi=1; pi<${#parts[@]}; pi++ )); do
            summary+=", ${parts[$pi]}"
        done
    else
        summary="No active downloads"
    fi

    # Fetch timestamp
    local fetch_ms
    fetch_ms=$(date +%s%3N)

    # Serialize to temp file via declare -p
    {
        declare -p items_names
        declare -p items_detail
        declare -p items_type
        declare -p items_pct
        printf 't_header=%q\n' "$t_header"
        printf 't_speed=%q\n' "$t_speed"
        printf 's_header=%q\n' "$s_header"
        printf 's_speed=%q\n' "$s_speed"
        printf 'summary=%q\n' "$summary"
        echo "t_dl=$t_dl"
        echo "t_seed=$t_seed"
        echo "t_stop=$t_stop"
        echo "s_dl=$s_dl"
        echo "s_queue=$s_queue"
        echo "s_hist=$s_hist"
        echo "fetch_ms=$fetch_ms"
    } > "${FETCH_TMP}.new" 2>/dev/null
    mv -f "${FETCH_TMP}.new" "$FETCH_TMP"
    touch "$FETCH_SIGNAL"
}

# ── load_data — called from main loop when signal detected ──────────────────

load_data() {
    local items_names=() items_detail=() items_type=() items_pct=()
    local t_header="" t_speed="" s_header="" s_speed="" summary=""
    local t_dl=0 t_seed=0 t_stop=0 s_dl=0 s_queue=0 s_hist=0 fetch_ms=0

    source "$FETCH_TMP"

    # Save previous percentages for interpolation
    if $HAS_DATA; then
        ITEM_PREV_X100=("${ITEM_PCT_X100[@]}")
    fi

    ITEM_NAMES=("${items_names[@]}")
    ITEM_DETAIL=("${items_detail[@]}")
    ITEM_TYPE=("${items_type[@]}")
    ITEM_PCT_X100=("${items_pct[@]}")

    # If no previous data, set prev = curr (no interpolation on first load)
    if ! $HAS_DATA; then
        ITEM_PREV_X100=("${items_pct[@]}")
    fi

    DISPLAY_PCT_X100=("${items_pct[@]}")

    T_HEADER_LINE="$t_header"
    T_SPEED_LINE="$t_speed"
    S_HEADER_LINE="$s_header"
    S_SPEED_LINE="$s_speed"
    SUMMARY_LINE="$summary"
    CURR_T_DL=$t_dl
    CURR_T_SEED=$t_seed
    CURR_T_STOP=$t_stop
    CURR_S_DL=$s_dl
    CURR_S_QUEUE=$s_queue
    CURR_S_HIST=$s_hist
    LAST_FETCH_MS=$fetch_ms
    HAS_DATA=true
}

# ── render_bar — renders progress bar. Zero forks. ──────────────────────────

# Sets REPLY with the rendered bar string
render_bar() {
    local pct_x100=$1
    local fg="$2"
    (( pct_x100 > 10000 )) && pct_x100=10000
    (( pct_x100 < 0 )) && pct_x100=0

    local fill_scaled=$(( pct_x100 * BAR_WIDTH ))
    local fill_int=$(( fill_scaled / 10000 ))
    local frac=$(( (fill_scaled % 10000) * 8 / 10000 ))
    (( frac >= 8 )) && frac=7
    (( frac < 0 )) && frac=0

    local empty=$(( BAR_WIDTH - fill_int ))
    (( frac > 0 )) && (( empty-- ))
    (( empty < 0 )) && empty=0

    local bar="${BAR_FULL[$fill_int]}"
    if (( fill_int < BAR_WIDTH && frac > 0 )); then
        bar+="${BLOCKS[$frac]}"
    elif (( fill_int < BAR_WIDTH )); then
        bar+=" "
    fi

    if (( empty > 0 )); then
        bar+="${SPACE_PAD[$empty]}"
    fi

    local pct_int=$(( pct_x100 / 100 ))
    local pct_frac=$(( pct_x100 % 100 / 10 ))
    local pct_str
    if (( pct_int >= 100 )); then
        pct_str="100%"
    else
        printf -v pct_str '%d.%d%%' "$pct_int" "$pct_frac"
    fi

    REPLY="${fg}${bar}${S_RESET}  ${C_TEXT}${pct_str}${S_RESET}"
}

# ── interpolate — ease-out between prev and curr ────────────────────────────

interpolate() {
    local now_ms=$1
    local elapsed=$(( now_ms - LAST_FETCH_MS ))
    local interval_ms=$(( FETCH_INTERVAL * 1000 ))

    local t=$(( elapsed * 1000 / interval_ms ))
    (( t > 1000 )) && t=1000
    (( t < 0 )) && t=0

    # Ease-out quadratic: t*(2-t)
    local eased=$(( t * (2000 - t) / 1000 ))

    local i
    for i in "${!ITEM_PCT_X100[@]}"; do
        local curr=${ITEM_PCT_X100[$i]}
        local prev=${ITEM_PREV_X100[$i]:-$curr}
        DISPLAY_PCT_X100[$i]=$(( prev + (curr - prev) * eased / 1000 ))
    done
}

# ── render_frame — builds + flushes a complete frame ────────────────────────

render_frame() {
    local frame=""

    if $LIVE_MODE; then
        frame+='\e[H'
        frame+='\e[?2026h'
        frame+='\e[2J\e[H'
    fi

    if ! $HAS_DATA; then
        frame+="\n  ${C_SUBTEXT0}Fetching download data...${S_RESET}\n"
        printf '%b' "$frame"
        $LIVE_MODE && printf '\e[?2026l'
        return
    fi

    frame+="\n"

    # Divider line
    local div_line=""
    printf -v div_line '%*s' 46 ''
    div_line="${div_line// /─}"

    # ── Torrents section ─────────────────────────────────────────────────

    frame+="  ${S_BOLD}${C_SAPPHIRE}${T_HEADER_LINE}${S_RESET}\n"
    frame+="  ${C_SURFACE1}${div_line}${S_RESET}  ${C_SUBTEXT0}${T_SPEED_LINE}${S_RESET}\n"

    if (( CURR_T_DL > 0 )); then
        frame+="\n    ${C_PEACH}DOWNLOADING${S_RESET} ${C_OVERLAY0}(${CURR_T_DL})${S_RESET}\n"
    fi

    local i
    local t_dl_shown=0
    for i in "${!ITEM_TYPE[@]}"; do
        [[ "${ITEM_TYPE[$i]}" != "td" ]] && continue
        (( t_dl_shown >= MAX_T_DL )) && continue
        frame+="\n    ${C_TEXT}${ITEM_NAMES[$i]}${S_RESET}\n"
        render_bar "${DISPLAY_PCT_X100[$i]}" "$C_SAPPHIRE"
        frame+="    ${REPLY}   ${C_SUBTEXT0}${ITEM_DETAIL[$i]}${S_RESET}\n"
        t_dl_shown=$(( t_dl_shown + 1 ))
    done

    if (( CURR_T_DL > MAX_T_DL )); then
        local t_extra=$(( CURR_T_DL - MAX_T_DL ))
        frame+="\n    ${C_OVERLAY0}... and ${t_extra} more downloading${S_RESET}\n"
    fi

    if (( CURR_T_SEED > 0 )); then
        frame+="\n    ${C_GREEN}SEEDING${S_RESET} ${C_OVERLAY0}(${CURR_T_SEED})${S_RESET}\n"
    fi

    local t_seed_shown=0
    for i in "${!ITEM_TYPE[@]}"; do
        [[ "${ITEM_TYPE[$i]}" != "ts" ]] && continue
        (( t_seed_shown >= MAX_T_SEED )) && continue
        local sname="${ITEM_NAMES[$i]}"
        if (( ${#sname} > 40 )); then
            sname="${sname:0:37}..."
        fi
        frame+="\n    ${C_SUBTEXT0}${sname}${S_RESET}"
        local namelen=${#sname}
        local padlen=$(( 45 - namelen ))
        (( padlen < 2 )) && padlen=2
        (( padlen > BAR_WIDTH + 9 )) && padlen=$(( BAR_WIDTH + 9 ))
        frame+="${SPACE_PAD[$padlen]}${C_OVERLAY0}${ITEM_DETAIL[$i]}${S_RESET}\n"
        t_seed_shown=$(( t_seed_shown + 1 ))
    done

    if (( CURR_T_SEED > MAX_T_SEED )); then
        local ts_extra=$(( CURR_T_SEED - MAX_T_SEED ))
        frame+="\n    ${C_OVERLAY0}... and ${ts_extra} more seeding${S_RESET}\n"
    fi

    if (( CURR_T_STOP > 0 )); then
        frame+="\n    ${C_OVERLAY0}STOPPED${S_RESET} ${C_OVERLAY0}(${CURR_T_STOP})${S_RESET}\n"
    fi

    for i in "${!ITEM_TYPE[@]}"; do
        [[ "${ITEM_TYPE[$i]}" != "tp" ]] && continue
        local sname="${ITEM_NAMES[$i]}"
        if (( ${#sname} > 40 )); then
            sname="${sname:0:37}..."
        fi
        frame+="\n    ${C_OVERLAY0}${sname}${S_RESET}\n"
        render_bar "${DISPLAY_PCT_X100[$i]}" "$C_OVERLAY0"
        frame+="    ${REPLY}   ${C_OVERLAY0}stopped${S_RESET}\n"
    done

    # ── SABnzbd section ──────────────────────────────────────────────────

    frame+="\n  ${S_BOLD}${C_SAPPHIRE}${S_HEADER_LINE}${S_RESET}\n"
    frame+="  ${C_SURFACE1}${div_line}${S_RESET}  ${C_SUBTEXT0}${S_SPEED_LINE}${S_RESET}\n"

    if (( CURR_S_DL > 0 )); then
        frame+="\n    ${C_PEACH}DOWNLOADING${S_RESET} ${C_OVERLAY0}(${CURR_S_DL})${S_RESET}\n"
    fi

    for i in "${!ITEM_TYPE[@]}"; do
        [[ "${ITEM_TYPE[$i]}" != "sd" ]] && continue
        frame+="\n    ${C_TEXT}${ITEM_NAMES[$i]}${S_RESET}\n"
        render_bar "${DISPLAY_PCT_X100[$i]}" "$C_TEAL"
        frame+="    ${REPLY}   ${C_SUBTEXT0}${ITEM_DETAIL[$i]}${S_RESET}\n"
    done

    # Show overflow for SAB downloads
    if (( CURR_S_DL > MAX_S_DL )); then
        local s_extra=$(( CURR_S_DL - MAX_S_DL ))
        frame+="\n    ${C_OVERLAY0}... and ${s_extra} more downloading${S_RESET}\n"
    fi

    if (( CURR_S_QUEUE > 0 )); then
        frame+="\n    ${C_OVERLAY0}QUEUED${S_RESET} ${C_OVERLAY0}(${CURR_S_QUEUE})${S_RESET}\n"
    fi

    for i in "${!ITEM_TYPE[@]}"; do
        [[ "${ITEM_TYPE[$i]}" != "sq" ]] && continue
        local sname="${ITEM_NAMES[$i]}"
        frame+="\n    ${C_OVERLAY0}○${S_RESET} ${C_SUBTEXT0}${sname}${S_RESET}"
        local namelen=${#sname}
        local padlen=$(( 50 - namelen ))
        (( padlen < 2 )) && padlen=2
        (( padlen > BAR_WIDTH + 9 )) && padlen=$(( BAR_WIDTH + 9 ))
        frame+="${SPACE_PAD[$padlen]}${C_OVERLAY0}${ITEM_DETAIL[$i]}${S_RESET}\n"
    done

    # Show overflow for queued
    if (( CURR_S_QUEUE > MAX_S_QUEUE )); then
        local sq_extra=$(( CURR_S_QUEUE - MAX_S_QUEUE ))
        frame+="\n    ${C_OVERLAY0}... and ${sq_extra} more queued${S_RESET}\n"
    fi

    if (( CURR_S_HIST > 0 )); then
        frame+="\n    ${C_OVERLAY0}RECENT${S_RESET}\n"
    fi

    for i in "${!ITEM_TYPE[@]}"; do
        [[ "${ITEM_TYPE[$i]}" != "sh" ]] && continue
        local idetail="${ITEM_DETAIL[$i]}"
        local hsize="${idetail%%|*}"
        local hstatus="${idetail##*|}"
        local sname="${ITEM_NAMES[$i]}"
        if (( ${#sname} > 40 )); then
            sname="${sname:0:37}..."
        fi
        local icon color
        if [[ "$hstatus" == "Completed" ]]; then
            icon="✓"; color="$C_GREEN"
        else
            icon="✗"; color="$C_RED"
        fi
        frame+="\n    ${color}${icon}${S_RESET} ${C_SUBTEXT0}${sname}${S_RESET}"
        local namelen=${#sname}
        local padlen=$(( 45 - namelen ))
        (( padlen < 2 )) && padlen=2
        (( padlen > BAR_WIDTH + 9 )) && padlen=$(( BAR_WIDTH + 9 ))
        frame+="${SPACE_PAD[$padlen]}${C_OVERLAY0}${hsize}${S_RESET}\n"
    done

    # ── Summary ──────────────────────────────────────────────────────────

    frame+="\n  ${C_SURFACE1}${div_line}──────────────${S_RESET}\n"
    frame+="\n  ${C_TEXT}${SUMMARY_LINE}${S_RESET}\n"

    if $LIVE_MODE; then
        frame+="\n  ${C_OVERLAY0}Live${S_RESET} ${C_SURFACE1}•${S_RESET} ${C_OVERLAY0}q${S_RESET} ${C_SURFACE1}quit${S_RESET} ${C_SURFACE1}•${S_RESET} ${C_OVERLAY0}r${S_RESET} ${C_SURFACE1}refresh${S_RESET}\n"
    fi

    if $LIVE_MODE; then
        frame+='\e[?2026l'
    fi

    printf '%b' "$frame"
}

# ── run_once — synchronous single fetch + render ────────────────────────────

run_once() {
    show_logo
    show_header "Arr Media Stack  —  Downloads"

    fetch_data
    load_data
    DISPLAY_PCT_X100=("${ITEM_PCT_X100[@]}")
    render_frame
}

# ── run_live — async loop with background fetch ─────────────────────────────

run_live() {
    printf '\e[?1049h'
    printf '\e[?25l'

    show_logo
    show_header "Arr Media Stack  —  Downloads"

    # Start first fetch in background
    ( fetch_data ) &
    FETCH_BG_PID=$!
    FETCH_RUNNING=true

    local last_fetch_start_ms
    last_fetch_start_ms=$(date +%s%3N)

    while true; do
        # Get current time — ONE date fork per frame
        local now_ms
        now_ms=$(date +%s%3N)

        # Check for completed background fetch
        if [[ -f "$FETCH_SIGNAL" ]]; then
            load_data
            rm -f "$FETCH_SIGNAL"
            FETCH_RUNNING=false
            FIRST_FETCH=false
            last_fetch_start_ms=$now_ms
        fi

        # Interpolate display percentages
        if $HAS_DATA; then
            interpolate "$now_ms"
        fi

        render_frame

        # Start new fetch if interval elapsed and not running
        if ! $FETCH_RUNNING; then
            local elapsed_since=$(( now_ms - last_fetch_start_ms ))
            if (( elapsed_since >= FETCH_INTERVAL * 1000 )); then
                ( fetch_data ) &
                FETCH_BG_PID=$!
                FETCH_RUNNING=true
                last_fetch_start_ms=$now_ms
            fi
        fi

        # Wait 100ms + check for keypress
        local key=""
        read -s -n1 -t 0.1 key 2>/dev/null || true
        case "$key" in
            q|Q) break ;;
            r|R)
                if ! $FETCH_RUNNING; then
                    ( fetch_data ) &
                    FETCH_BG_PID=$!
                    FETCH_RUNNING=true
                    last_fetch_start_ms=$now_ms
                fi
                ;;
        esac
    done
}

# ── Entry point ──────────────────────────────────────────────────────────────

if $LIVE_MODE; then
    run_live
else
    run_once
fi
