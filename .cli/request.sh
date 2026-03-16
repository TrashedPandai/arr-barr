#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env
require_curl
require_jq || exit 1

DATA_ROOT="$(get_data_root)"

# ── Parse global flags ──────────────────────────────────────────────────────

WATCH=false
WATCH_TIMEOUT=1800  # 30 min default

ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=true; shift ;;
        --timeout)
            shift
            WATCH_TIMEOUT="${1:-1800}"
            shift
            ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# ── Helper Functions ─────────────────────────────────────────────────────────

_get_api_key() {
    local service="$1"
    case "$service" in
        radarr|sonarr|lidarr|prowlarr)
            grep -oP '<ApiKey>\K[^<]+' "$DATA_ROOT/config/$service/config.xml" 2>/dev/null || true
            ;;
        lazylibrarian)
            grep '^api_key' "$DATA_ROOT/config/lazylibrarian/config.ini" 2>/dev/null | cut -d'=' -f2- | tr -d ' ' || true
            ;;
    esac
}

_check_running() {
    local service="$1"
    if ! $DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -qw "$service"; then
        msg_error "${service} is not running."
        msg_dim "Start it with: arr start ${service}"
        exit 1
    fi
}

_api_get() {
    local url="$1" api_key="${2:-}"
    local response http_code
    if [ -n "$api_key" ]; then
        response=$(curl -s --max-time 15 -w "\n%{http_code}" -H "X-Api-Key: $api_key" "$url" 2>/dev/null) || {
            msg_error "Could not reach service."

            return 1
        }
    else
        response=$(curl -s --max-time 15 -w "\n%{http_code}" "$url" 2>/dev/null) || {
            msg_error "Could not reach service."

            return 1
        }
    fi
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')
    if [ "$http_code" != "200" ] && [ "$http_code" != "302" ]; then
        msg_error "API returned HTTP ${http_code}"
        msg_dim "  Check the service logs or try the web UI."
        return 1
    fi
    echo "$response"
}

_api_post() {
    local url="$1" api_key="$2" body="$3"
    local response http_code
    response=$(curl -s --max-time 15 -w "\n%{http_code}" \
        -X POST -H "Content-Type: application/json" -H "X-Api-Key: $api_key" \
        -d "$body" "$url" 2>/dev/null) || {
        msg_error "Could not reach service."
        msg_dim "  Check the service logs or try the web UI."
        return 1
    }
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        # Check for "already exists" type errors
        if echo "$response" | grep -qi "already.*exist\|already.*added\|already.*in.*library\|MovieExistsValidator\|SeriesExistsValidator\|ArtistExistsValidator"; then
            msg_warn "Already in your library!"
            return 2
        fi
        msg_error "API returned HTTP ${http_code}"
        echo "$response" | jq -r '.[] | .errorMessage // empty' 2>/dev/null | while read -r err; do
            msg_dim "  $err"
        done
        msg_dim "  Check the service logs or try the web UI."
        return 1
    fi
    echo "$response"
}

# ── Detail Card — clean movie/TV/music detail display ──────────────────────

_detail_card() {
    # Usage: _detail_card "Title" "(Year)" "meta line" "overview" "link_url" "link_label"
    local title="$1" year_tag="$2" meta="$3" overview="${4:-}" link_url="${5:-}" link_label="${6:-}"

    echo ""
    echo -e "  ${S_BOLD}${C_TEXT}${title}${S_RESET}  ${C_OVERLAY0}${year_tag}${S_RESET}"
    [ -n "$meta" ] && echo -e "  ${C_SUBTEXT0}${meta}${S_RESET}"

    # Overview — word-wrapped to 78 chars, max 3 lines, truncate with link
    if [ -n "$overview" ]; then
        echo ""
        local max_w=78 max_l=3
        local cur_line="" l_count=0 output=""
        for word in $overview; do
            local test="${cur_line:+${cur_line} }${word}"
            if [ ${#test} -gt $max_w ]; then
                l_count=$(( l_count + 1 ))
                if [ $l_count -ge $max_l ]; then
                    cur_line="${cur_line}..."
                    break
                fi
                output="${output}  ${C_OVERLAY0}${cur_line}${S_RESET}\n"
                cur_line="$word"
            else
                cur_line="$test"
            fi
        done
        [ -n "$cur_line" ] && output="${output}  ${C_OVERLAY0}${cur_line}${S_RESET}\n"
        printf "%b" "$output"
        [ -n "$link_url" ] && echo -e "  ${C_SAPPHIRE}${link_url}${S_RESET}"
    fi

    echo ""
    local _div=""
    for (( _i=0; _i<70; _i++ )); do _div+="─"; done
    echo -e "  ${C_SURFACE1}${_div}${S_RESET}"
}

# ── Release Picker — browse and pick from available releases ───────────────

_release_preview() {
    local search_query="$1"
    local categories="${2:-2000}"  # movie=2000, tv=5000, music=3000
    local service="${3:-}"        # radarr|sonarr|lidarr — for cutoff + browse link

    # Globals for caller
    RP_PICKED=false
    RP_BELOW_CUTOFF=false
    RP_CUTOFF_NAME=""

    # Check if Prowlarr is running
    if ! $DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null | grep -qw prowlarr; then
        return 0  # silently skip
    fi

    local prowlarr_key
    prowlarr_key=$(_get_api_key prowlarr)
    [ -z "$prowlarr_key" ] && return 0

    # ── Fetch quality cutoff from the service's profile ──
    local cutoff_name="" cutoff_tier=0
    if [ -n "$service" ]; then
        local svc_key svc_port svc_api
        svc_key=$(_get_api_key "$service")
        case "$service" in
            radarr)  svc_port=7878; svc_api="v3" ;;
            sonarr)  svc_port=8989; svc_api="v3" ;;
            lidarr)  svc_port=8686; svc_api="v1" ;;
        esac
        if [ -n "$svc_key" ]; then
            local profile_json
            profile_json=$(curl -s --max-time 5 -H "X-Api-Key: $svc_key" \
                "http://localhost:${svc_port}/api/${svc_api}/qualityprofile/1" 2>/dev/null) || true
            if [ -n "$profile_json" ]; then
                local cutoff_id
                cutoff_id=$(echo "$profile_json" | jq -r '.cutoff // empty' 2>/dev/null) || true
                if [ -n "$cutoff_id" ]; then
                    cutoff_name=$(echo "$profile_json" | jq -r \
                        "[.items[] | select(.quality.id > 0)] | map(select(.quality.id == $cutoff_id)) | .[0].quality.name // empty" 2>/dev/null) || true
                    if [ -z "$cutoff_name" ]; then
                        cutoff_name=$(echo "$profile_json" | jq -r \
                            "[.items[] | select(.id > 0)] | map(select(.id == $cutoff_id)) | .[0].name // empty" 2>/dev/null) || true
                    fi
                fi
            fi
        fi
        RP_CUTOFF_NAME="$cutoff_name"

        # Map cutoff to a resolution tier for coloring
        case "$cutoff_name" in
            Remux-2160*) cutoff_tier=4 ;;
            *2160*|*4K*) cutoff_tier=3 ;;
            Remux-1080*) cutoff_tier=3 ;;
            *1080*)      cutoff_tier=2 ;;
            *720*)       cutoff_tier=1 ;;
            *)           cutoff_tier=0 ;;
        esac
    fi

    local release_tmp
    release_tmp=$(mktemp /tmp/arr-releases.XXXXXX)

    # Build categories as repeated params (&categories=X&categories=Y)
    local cat_params=""
    IFS=',' read -ra cats <<< "$categories"
    for c in "${cats[@]}"; do
        cat_params+="&categories=${c}"
    done

    # Fetch releases, annotate with quality tier, group by tier (top 2 each)
    curl -s --max-time 25 -H "X-Api-Key: $prowlarr_key" \
        "http://localhost:9696/api/v1/search?query=$(printf '%s' "$search_query" | jq -sRr @uri)${cat_params}&type=search" 2>/dev/null \
        | jq -c '[.[] | select(type == "object" and .title != null) |
            . + {tier: (
                if ((.title | test("2160p|4[Kk]|UHD")) and (.title | test("[Rr]emux|REMUX"))) then 4
                elif (.title | test("2160p|4[Kk]|UHD")) then 3
                elif (.title | test("[Rr]emux|REMUX")) then 3
                elif (.title | test("1080[pPiI]")) then 2
                elif (.title | test("720[pP]")) then 1
                else 0
                end
            )}
        ] | {
            total: length,
            torrents: [.[] | select(.protocol == "torrent")] | length,
            usenet: [.[] | select(.protocol == "usenet")] | length,
            indexers: [.[].indexer] | unique | length,
            top: (group_by(.tier) | [.[] | sort_by(-((.seeders // 0) + (.grabs // 0))) | .[0:2]] | add // [] | sort_by(-((.tier * 100000) + ((.seeders // 0) + (.grabs // 0)))) | .[0:10])
        }' > "$release_tmp" 2>/dev/null &
    local pid=$!

    if $HAS_GUM; then
        gum spin --spinner dot --title "  Checking available releases..." -- bash -c "while kill -0 $pid 2>/dev/null; do sleep 0.1; done"
        wait $pid 2>/dev/null || true
    else
        spin_while $pid "Checking available releases..."
    fi

    local releases
    releases=$(cat "$release_tmp" 2>/dev/null)
    rm -f "$release_tmp"

    [ -z "$releases" ] && return 0

    local total torrent_count usenet_count indexer_count
    total=$(echo "$releases" | jq -r '.total // 0' 2>/dev/null) || true
    [[ ! "${total:-0}" =~ ^[0-9]+$ ]] && total=0
    [[ "$total" -eq 0 ]] && { msg_warn "No releases found on indexers"; return 0; }

    torrent_count=$(echo "$releases" | jq -r '.torrents // 0' 2>/dev/null) || true
    usenet_count=$(echo "$releases" | jq -r '.usenet // 0' 2>/dev/null) || true
    indexer_count=$(echo "$releases" | jq -r '.indexers // 0' 2>/dev/null) || true
    [[ ! "${torrent_count:-0}" =~ ^[0-9]+$ ]] && torrent_count=0
    [[ ! "${usenet_count:-0}" =~ ^[0-9]+$ ]] && usenet_count=0
    [[ ! "${indexer_count:-0}" =~ ^[0-9]+$ ]] && indexer_count=0

    # ── Summary + cutoff ──
    local summary="${total} releases across ${indexer_count} indexers"
    if [[ "$torrent_count" -gt 0 ]] && [[ "$usenet_count" -gt 0 ]]; then
        summary+=" (${torrent_count} torrent, ${usenet_count} usenet)"
    fi
    echo -e "  ${C_GREEN}✓${S_RESET} ${C_TEXT}${summary}${S_RESET}"
    if [ -n "$cutoff_name" ]; then
        echo -e "  ${C_SUBTEXT0}Upgrade target${S_RESET}  ${C_SAPPHIRE}${cutoff_name}${S_RESET}"
    fi
    echo ""

    # ── Build table data with tier as first field ──
    local table_data
    table_data=$(echo "$releases" | jq -r '
        .top[] |
        ((.tier // 0) | tostring) + "\t" +
        (
            (.title // "?") | if length > 42 then .[0:39] + "..." else . end
        ) + "\t" +
        (
            (.size // 0) as $s |
            if $s > 1073741824 then
                (($s / 1073741824 * 10 | floor) / 10 | tostring) + " GB"
            elif $s > 1048576 then
                (($s / 1048576 | floor) | tostring) + " MB"
            else "?"
            end
        ) + "\t" +
        (
            if (.protocol // "") == "torrent" then
                "\u25BC " + ((.seeders // 0) | tostring)
            else
                ((.grabs // 0) | tostring) + " grabs"
            end
        ) + "\t" +
        ((.indexer // "?") | if length > 14 then .[0:11] + "..." else . end) + "\t" +
        (
            (.age // 0) as $a |
            if $a <= 1 then "today"
            elif $a < 30 then ($a | tostring) + "d"
            elif $a < 365 then (($a / 30 | floor) | tostring) + "mo"
            else (($a / 365 | floor) | tostring) + "y"
            end
        )
    ' 2>/dev/null)

    [ -z "$table_data" ] && return 0

    # ── Build interactive release picker lines ──
    # Each line is prefixed with a unique index for reliable matching
    # Format: "IDX|display_line" — IDX stripped before display, used for tier lookup
    local row_count=0
    local row_tiers=()
    local picker_lines=()    # "IDX|formatted_line" for internal tracking
    local display_lines=()   # clean lines for gum filter display

    while IFS=$'\t' read -r tier rel size peers indexer age; do
        [[ -z "$tier" && -z "$rel" ]] && continue
        [[ ! "$tier" =~ ^[0-9]+$ ]] && tier=0
        row_count=$(( row_count + 1 ))
        row_tiers+=("$tier")

        local line
        line=$(printf "%-44s  %-7s  %-8s  %-14s  %s" "$rel" "$size" "$peers" "$indexer" "$age")
        picker_lines+=("${row_count}|${line}")
        display_lines+=("$line")
    done <<< "$table_data"

    [[ "$row_count" -eq 0 ]] && return 0

    # ── Browse link URL ──
    local browse_url=""
    local remaining=$(( total - row_count ))
    if [[ "$remaining" -gt 0 ]]; then
        local encoded_query
        encoded_query=$(printf '%s' "$search_query" | jq -sRr @uri 2>/dev/null) || true
        case "${service:-}" in
            radarr)  browse_url="http://radarr:7878/add/new?term=${encoded_query}" ;;
            sonarr)  browse_url="http://sonarr:8989/add/new?term=${encoded_query}" ;;
            lidarr)  browse_url="http://lidarr:8686/add/search?term=${encoded_query}" ;;
        esac
    fi

    # ── Interactive picker via gum filter ──
    local selected="" selected_idx=""
    local svc_label
    svc_label=$(echo "${service:-arr}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') || svc_label="Arr"

    if $HAS_GUM; then
        local skip_line="Skip -- let ${svc_label} choose automatically"
        local header_line
        header_line=$(printf "%-44s  %-7s  %-8s  %-14s  %s" "Release" "Size" "Seeds" "Indexer" "Age")

        selected=$( (echo "$skip_line"; printf '%s\n' "${display_lines[@]}") | \
            gum filter \
                --header "$header_line" \
                --header.foreground "#a6adc8" \
                --placeholder "Type to search (e.g. 1080, remux) or select Skip" \
                --indicator "▸" \
                --indicator.foreground "#f5c2e7" \
                --match.foreground "#f9e2af" \
                --text.foreground "#cdd6f4" \
                --prompt "> " \
                --prompt.foreground "#89b4fa" \
                --height 14 \
                --width 95) || selected=""

        # Map selected display line back to index (handles duplicates by first match)
        if [ -n "$selected" ] && [[ "$selected" != Skip* ]]; then
            local _m
            for _m in "${picker_lines[@]}"; do
                if [ "${_m#*|}" = "$selected" ]; then
                    selected_idx="${_m%%|*}"
                    break
                fi
            done
        fi
    else
        # Fallback: static table + number picker
        printf "  ${C_SUBTEXT0}     %-44s  %-7s  %-8s  %-14s  %s${S_RESET}\n" \
            "Release" "Size" "Seeds" "Indexer" "Age"
        local sep="─"
        local rule=""
        for (( _i=0; _i<93; _i++ )); do rule+="$sep"; done
        echo -e "  ${C_SURFACE1}${rule}${S_RESET}"
        local _idx=0
        for line in "${display_lines[@]}"; do
            _idx=$(( _idx + 1 ))
            if [[ "${row_tiers[$((_idx-1))]:-0}" -ge "$cutoff_tier" ]]; then
                printf "  ${C_SAPPHIRE}%2d)${S_RESET} ${C_TEXT}%s${S_RESET}\n" "$_idx" "$line"
            else
                printf "  ${C_OVERLAY0}%2d) %s${S_RESET}\n" "$_idx" "$line"
            fi
        done
        echo ""
        local pick_input=""
        read -rp "  Pick a release [1-${row_count}] or Enter to skip: " pick_input || true
        if [[ "$pick_input" =~ ^[0-9]+$ ]] && [[ "$pick_input" -ge 1 ]] && [[ "$pick_input" -le "$row_count" ]]; then
            selected_idx="$pick_input"
        fi
    fi

    # ── Browse link (shown after picker closes) ──
    if [[ "$remaining" -gt 0 ]] && [ -n "$browse_url" ]; then
        echo ""
        echo -e "  ${C_OVERLAY0}...and ${remaining} more${S_RESET}  ${C_SUBTEXT0}Browse all →${S_RESET} ${C_SAPPHIRE}${browse_url}${S_RESET}"
    fi

    # ── Resolve selection by index ──
    if [ -n "$selected_idx" ]; then
        RP_PICKED=true
        local picked_tier="${row_tiers[$((selected_idx - 1))]:-0}"
        if [[ "$picked_tier" -lt "$cutoff_tier" ]]; then
            RP_BELOW_CUTOFF=true
        fi
    fi
}

_search_prompt() {
    local header="$1"
    if $HAS_GUM; then
        gum input \
            --header "  $header" \
            --header.foreground "#f9e2af" \
            --placeholder "Type a name..." \
            --prompt "▸ " \
            --prompt.foreground "#89b4fa" \
            --cursor.foreground "#f5c2e7" \
            --width 50 || true
    else
        local term
        echo ""
        read -rp "  $header: " term
        echo "$term"
    fi
}

_pick_result() {
    local header="$1"
    shift
    local lines=("$@")

    if [ ${#lines[@]} -eq 0 ]; then
        return 1
    fi

    if $HAS_GUM; then
        # Build display lines (strip ID prefix) and keep originals for mapping
        local display_lines=()
        for line in "${lines[@]}"; do
            display_lines+=("${line#*|}")
        done
        local selected_display
        selected_display=$(printf '%s\n' "${display_lines[@]}" | gum filter \
            --header "  $header" \
            --header.foreground "#f9e2af" \
            --placeholder "Type to search..." \
            --indicator "▸" \
            --indicator.foreground "#f5c2e7" \
            --match.foreground "#a6e3a1" \
            --text.foreground "#cdd6f4" \
            --prompt "▸ " \
            --prompt.foreground "#89b4fa" \
            --height 15 \
            --width 85) || return 1
        # Map back to full ID|display line
        for line in "${lines[@]}"; do
            if [ "${line#*|}" = "$selected_display" ]; then
                echo "$line"
                return 0
            fi
        done
        return 1
    else
        echo ""
        echo -e "  ${S_BOLD}${C_TEXT}${header}${S_RESET}"
        echo ""
        local i=1
        for line in "${lines[@]}"; do
            # Strip the ID prefix for display
            local display="${line#*|}"
            printf "  ${C_SAPPHIRE}%2d)${S_RESET} ${C_TEXT}%s${S_RESET}\n" "$i" "$display"
            i=$(( i + 1 ))
        done
        echo ""
        local choice
        read -rp "  Select [1-${#lines[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#lines[@]}" ]; then
            echo "${lines[$((choice-1))]}"
        else
            return 1
        fi
    fi
}

# ── LazyLibrarian API Key Bootstrap ──────────────────────────────────────────

_ll_ensure_apikey() {
    local key
    key=$(_get_api_key lazylibrarian)
    if [ -n "$key" ]; then
        echo "$key"
        return 0
    fi

    msg_warn "LazyLibrarian has no API key configured."
    echo ""
    if ! gum_confirm "Generate one and restart LazyLibrarian?"; then
        msg_dim "Cancelled. Set api_key manually in LazyLibrarian config."
        return 1
    fi

    # Generate a random API key
    key=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)

    # Insert into config.ini under [API] section
    local config="$DATA_ROOT/config/lazylibrarian/config.ini"
    if grep -q '^\[API\]' "$config" 2>/dev/null; then
        sed -i "/^\[API\]/a api_key = $key" "$config"
    else
        echo -e "\n[API]\napi_key = $key" >> "$config"
    fi

    msg_dim "  Generated API key and added to config.ini"

    # Restart LazyLibrarian
    compose_cmd restart lazylibrarian > /dev/null 2>&1 &
    if $HAS_GUM; then
        gum spin --spinner dot --title "  Restarting LazyLibrarian..." -- wait $!
    else
        spin_while $! "Restarting LazyLibrarian..."
    fi

    # Wait for it to come back
    sleep 3
    msg_success "LazyLibrarian restarted with API key"
    echo ""
    echo "$key"
}

# ── QuestArr JWT Authentication ──────────────────────────────────────────────

_qa_get_token() {
    local cache="/tmp/arr-questarr-jwt"

    # Check cached token
    if [ -f "$cache" ]; then
        local token
        token=$(cat "$cache")
        # Verify it's still valid
        local check
        check=$(curl -s --max-time 5 -w "%{http_code}" -o /dev/null \
            -H "Authorization: Bearer $token" "http://localhost:5002/api/auth/me" 2>/dev/null) || true
        if [ "$check" = "200" ]; then
            echo "$token"
            return 0
        fi
        rm -f "$cache"
    fi

    # Need to login
    msg_dim "  QuestArr requires authentication."
    local password
    if $HAS_GUM; then
        password=$(gum input --header "  QuestArr password (user: root)" --password --placeholder "Password..." --width 40) || return 1
    else
        read -rsp "  QuestArr password (user: root): " password
        echo ""
    fi

    [ -z "$password" ] && return 1

    local response
    response=$(curl -s --max-time 10 -X POST -H "Content-Type: application/json" \
        -d "{\"username\":\"root\",\"password\":\"$password\"}" \
        "http://localhost:5002/api/auth/login" 2>/dev/null) || {
        msg_error "Could not reach QuestArr."
        return 1
    }

    local token
    token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null)
    if [ -z "$token" ]; then
        msg_error "Authentication failed. Check your password."
        return 1
    fi

    echo "$token" > "$cache"
    chmod 600 "$cache"
    echo "$token"
}

# ── Watch Journey — follow a file from search to playback ────────────────────

# Progress bar matching downloads.sh style (zero forks)
BAR_WIDTH=30
BLOCKS_W=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")

_render_watch_bar() {
    local pct_x100=$1  # 0-10000
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

    local bar=""
    for (( i=0; i<fill_int; i++ )); do bar+="█"; done
    if (( fill_int < BAR_WIDTH && frac > 0 )); then
        bar+="${BLOCKS_W[$frac]}"
    elif (( fill_int < BAR_WIDTH )); then
        bar+=" "
    fi
    for (( i=0; i<empty; i++ )); do bar+="░"; done

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

# ── Quality Color — color the quality name by tier ─────────────────────────

_quality_color() {
    # Returns the quality name colored by its tier
    local quality="$1"
    local color

    case "$quality" in
        Remux-2160p|Remux-1080p|Bluray-2160p|Bluray-1080p)
            color="$C_GREEN" ;;
        WEBDL-2160p|WEBRip-2160p|WEBDL-1080p|WEBRip-1080p|HDTV-2160p|HDTV-1080p)
            color="$C_SAPPHIRE" ;;
        Bluray-720p|WEBDL-720p|WEBRip-720p|HDTV-720p)
            color="$C_YELLOW" ;;
        BR-DISK)
            color="$C_PEACH" ;;
        Raw-HD|DVD|SDTV|WEBDL-480p|WEBRip-480p|Bluray-480p)
            color="$C_RED" ;;
        FLAC|Lossless|"CD FLAC")
            color="$C_GREEN" ;;
        MP3*|AAC*|WMA*|Ogg*|Unknown)
            color="$C_YELLOW" ;;
        *)
            color="$C_OVERLAY0" ;;
    esac

    echo -e "${color}${quality}${S_RESET}"
}

# ── Unreleased Detection — check if content is available yet ──────────────

_check_unreleased() {
    # Returns 0 (true) if unreleased, 1 if available
    # Sets UNRELEASED_MSG and UNRELEASED_DATE for the caller
    local service="$1" item_json="$2"

    UNRELEASED_MSG=""
    UNRELEASED_DATE=""

    case "$service" in
        radarr)
            local status digital_release in_cinemas physical_release
            status=$(echo "$item_json" | jq -r '.status // "released"' 2>/dev/null) || true
            digital_release=$(echo "$item_json" | jq -r '.digitalRelease // empty' 2>/dev/null) || true
            in_cinemas=$(echo "$item_json" | jq -r '.inCinemas // empty' 2>/dev/null) || true
            physical_release=$(echo "$item_json" | jq -r '.physicalRelease // empty' 2>/dev/null) || true

            # "announced" or "tba" = definitely unreleased
            if [ "$status" = "announced" ] || [ "$status" = "tba" ]; then
                UNRELEASED_MSG="Not yet released"
                if [ -n "$in_cinemas" ] && [ "$in_cinemas" != "null" ]; then
                    UNRELEASED_DATE="Theaters: $(echo "$in_cinemas" | cut -dT -f1)"
                fi
                return 0
            fi

            # "inCinemas" = in theaters but no digital release yet
            if [ "$status" = "inCinemas" ]; then
                UNRELEASED_MSG="In theaters — not available digitally yet"
                if [ -n "$digital_release" ] && [ "$digital_release" != "null" ]; then
                    UNRELEASED_DATE="Digital: $(echo "$digital_release" | cut -dT -f1)"
                fi
                return 0
            fi

            # "released" but digital release is in the future
            if [ -n "$digital_release" ] && [ "$digital_release" != "null" ]; then
                local dr_epoch today_epoch
                dr_epoch=$(date -d "$(echo "$digital_release" | cut -dT -f1)" +%s 2>/dev/null) || true
                today_epoch=$(date +%s 2>/dev/null) || true
                if [ -n "$dr_epoch" ] && [ -n "$today_epoch" ] && [ "$dr_epoch" -gt "$today_epoch" ]; then
                    UNRELEASED_MSG="In theaters — digital release upcoming"
                    UNRELEASED_DATE="Digital: $(echo "$digital_release" | cut -dT -f1)"
                    return 0
                fi
            fi
            ;;
        sonarr)
            local status next_airing
            status=$(echo "$item_json" | jq -r '.status // "continuing"' 2>/dev/null) || true
            next_airing=$(echo "$item_json" | jq -r '.nextAiring // empty' 2>/dev/null) || true

            # Check total episode count — if 0, nothing has aired
            local total_eps
            total_eps=$(echo "$item_json" | jq -r '.statistics.totalEpisodeCount // 0' 2>/dev/null) || true
            if [ "$total_eps" = "0" ]; then
                UNRELEASED_MSG="No episodes have aired yet"
                if [ -n "$next_airing" ] && [ "$next_airing" != "null" ]; then
                    UNRELEASED_DATE="Premieres: $(echo "$next_airing" | cut -dT -f1)"
                fi
                return 0
            fi
            ;;
    esac

    return 1
}

# ── Already Owned — rich display when media exists ────────────────────────

_already_owned() {
    local service="$1"
    local item_id="$2"
    local title="$3"
    local api_key="$4"

    _watch_api_config "$service"
    local base_url="http://localhost:${W_PORT}/api/${W_API_VER}"

    # Fetch the full item details from the service
    local item_json
    item_json=$(curl -s --max-time 10 -H "X-Api-Key: $api_key" \
        "${base_url}/${W_ITEM_EP}/${item_id}" 2>/dev/null) || true

    if [ -z "$item_json" ] || [ "$item_json" = "null" ]; then
        msg_warn "${title} is already in your library!"
        return
    fi

    local has_file item_path monitored
    has_file=$(echo "$item_json" | jq -r "${W_HAS_FILE_JQ}" 2>/dev/null) || true
    item_path=$(echo "$item_json" | jq -r "${W_PATH_JQ}" 2>/dev/null) || true
    monitored=$(echo "$item_json" | jq -r '.monitored // false' 2>/dev/null) || true

    # Check if it's currently in the download queue
    local queue_json in_queue queue_status queue_progress queue_release queue_size queue_sizeleft
    in_queue=false
    queue_size=0
    queue_sizeleft=0
    queue_json=$(curl -s --max-time 10 -H "X-Api-Key: $api_key" \
        "${base_url}/queue?${W_QUEUE_FILTER}=${item_id}&pageSize=50" 2>/dev/null) || true

    if [ -n "$queue_json" ]; then
        local record
        record=$(echo "$queue_json" | jq -c "[.records[]? | select(.${W_QUEUE_FILTER} == $item_id)] | .[0] // empty" 2>/dev/null) || true
        if [ -n "$record" ] && [ "$record" != "null" ]; then
            in_queue=true
            queue_status=$(echo "$record" | jq -r '.trackedDownloadState // .status // "unknown"' 2>/dev/null) || true
            queue_release=$(echo "$record" | jq -r '.title // "Unknown release"' 2>/dev/null) || true
            queue_size=$(echo "$record" | jq -r '.size // 0' 2>/dev/null) || true
            queue_sizeleft=$(echo "$record" | jq -r '.sizeleft // 0' 2>/dev/null) || true
            if [ -n "$queue_size" ] && [ "$queue_size" != "0" ] && [ "$queue_size" != "null" ]; then
                local downloaded=$(( queue_size - queue_sizeleft ))
                (( downloaded < 0 )) && downloaded=0
                queue_progress=$(( downloaded * 10000 / queue_size ))
            else
                queue_progress=0
            fi
        fi
    fi

    # ── Build the card ──

    echo ""

    # Title header
    local emoji
    case "$service" in
        radarr) emoji="🎬" ;;
        sonarr) emoji="📺" ;;
        lidarr) emoji="🎵" ;;
    esac

    if $HAS_GUM; then
        echo "  ${emoji} ${title}" | gum style \
            --border rounded \
            --border-foreground "#f9e2af" \
            --foreground "#cdd6f4" \
            --padding "0 2" \
            --margin "0 2" \
            --bold
    else
        echo ""
        echo -e "  ${C_YELLOW}${S_BOLD}${emoji} ${title}${S_RESET}"
        echo ""
    fi

    # ── State: Downloading ──
    if $in_queue; then
        echo ""
        echo -e "  ${C_YELLOW}▸ DOWNLOADING${S_RESET}"
        echo ""

        # Status
        local status_label status_color
        case "$queue_status" in
            downloading)    status_label="Downloading";  status_color="$C_SAPPHIRE" ;;
            importPending|importBlocked) status_label="Waiting to Import"; status_color="$C_PEACH" ;;
            imported)       status_label="Imported";     status_color="$C_GREEN" ;;
            *)              status_label="${queue_status}"; status_color="$C_OVERLAY0" ;;
        esac

        echo -e "  ${C_SUBTEXT0}Status${S_RESET}     ${status_color}●${S_RESET} ${C_TEXT}${status_label}${S_RESET}"

        # Release name (truncated)
        if [ -n "$queue_release" ]; then
            local dname="$queue_release"
            (( ${#dname} > 60 )) && dname="${dname:0:57}..."
            echo -e "  ${C_SUBTEXT0}Release${S_RESET}    ${C_TEXT}${dname}${S_RESET}"
        fi

        # Size info
        if [ -n "$queue_size" ] && [ "$queue_size" != "0" ] && [ "$queue_size" != "null" ]; then
            local dl_done=$(( queue_size - queue_sizeleft ))
            (( dl_done < 0 )) && dl_done=0
            echo -e "  ${C_SUBTEXT0}Size${S_RESET}       ${C_TEXT}$(human_size "$dl_done") / $(human_size "$queue_size")${S_RESET}"
        fi

        # Progress bar
        echo ""
        if [ "${queue_progress:-0}" -gt 0 ]; then
            _render_watch_bar "$queue_progress" "$C_SAPPHIRE"
            echo -e "    ${REPLY}"
        else
            _render_watch_bar 0 "$C_SAPPHIRE"
            echo -e "    ${REPLY}"
        fi

        echo ""

        if $WATCH; then
            echo -e "  ${C_SAPPHIRE}●${S_RESET} ${C_TEXT}Attaching to download...${S_RESET}"
            echo ""
            sleep 1
            _watch_journey "$service" "$item_id" "$title" "$api_key" "$WATCH_TIMEOUT"
        else
            if gum_confirm "Watch the download journey?"; then
                echo ""
                _watch_journey "$service" "$item_id" "$title" "$api_key" "$WATCH_TIMEOUT"
            else
                echo ""
                msg_dim "  Check progress anytime: arr downloads"
            fi
        fi

    # ── State: On Disk ──
    elif [ "$has_file" = "true" ]; then
        echo ""
        echo -e "  ${C_GREEN}▸ IN YOUR LIBRARY${S_RESET}"
        echo ""

        # Service-specific file details
        case "$service" in
            radarr)
                local file_quality file_size file_codec file_audio file_channels file_res
                file_quality=$(echo "$item_json" | jq -r '.movieFile.quality.quality.name // "Unknown"' 2>/dev/null) || true
                file_size=$(echo "$item_json" | jq -r '.movieFile.size // 0' 2>/dev/null) || true
                file_codec=$(echo "$item_json" | jq -r '.movieFile.mediaInfo.videoCodec // empty' 2>/dev/null) || true
                file_audio=$(echo "$item_json" | jq -r '.movieFile.mediaInfo.audioCodec // empty' 2>/dev/null) || true
                file_channels=$(echo "$item_json" | jq -r '.movieFile.mediaInfo.audioChannels // empty' 2>/dev/null) || true
                file_res=$(echo "$item_json" | jq -r '.movieFile.mediaInfo.resolution // empty' 2>/dev/null) || true

                echo -e "  ${C_SUBTEXT0}Quality${S_RESET}    $(_quality_color "$file_quality")"

                if [ -n "$file_codec" ] && [ "$file_codec" != "null" ]; then
                    local media_line="${file_codec}"
                    [ -n "$file_res" ] && [ "$file_res" != "null" ] && media_line+="  ${file_res}"
                    [ -n "$file_audio" ] && [ "$file_audio" != "null" ] && media_line+="  ${file_audio}"
                    [ -n "$file_channels" ] && [ "$file_channels" != "null" ] && media_line+=" ${file_channels}"
                    echo -e "  ${C_SUBTEXT0}Media${S_RESET}      ${C_TEXT}${media_line}${S_RESET}"
                fi

                if [ -n "$file_size" ] && [ "$file_size" != "0" ] && [ "$file_size" != "null" ]; then
                    echo -e "  ${C_SUBTEXT0}Size${S_RESET}       ${C_TEXT}$(human_size "$file_size")${S_RESET}"
                fi
                ;;
            sonarr)
                local ep_count ep_file_count pct season_count
                ep_count=$(echo "$item_json" | jq -r '.statistics.episodeCount // 0' 2>/dev/null) || true
                ep_file_count=$(echo "$item_json" | jq -r '.statistics.episodeFileCount // 0' 2>/dev/null) || true
                season_count=$(echo "$item_json" | jq -r '.statistics.seasonCount // 0' 2>/dev/null) || true

                if [ "$ep_count" != "0" ] && [ "$ep_count" != "null" ]; then
                    pct=$(( ep_file_count * 100 / ep_count ))
                    local ep_color="$C_GREEN"
                    (( pct < 100 )) && ep_color="$C_YELLOW"
                    (( pct < 50 )) && ep_color="$C_PEACH"
                    echo -e "  ${C_SUBTEXT0}Episodes${S_RESET}   ${ep_color}${ep_file_count}${S_RESET}${C_TEXT} / ${ep_count} episodes${S_RESET} ${C_OVERLAY0}(${pct}%)${S_RESET}"
                fi
                if [ -n "$season_count" ] && [ "$season_count" != "0" ] && [ "$season_count" != "null" ]; then
                    echo -e "  ${C_SUBTEXT0}Seasons${S_RESET}    ${C_TEXT}${season_count}${S_RESET}"
                fi
                ;;
            lidarr)
                local track_pct album_count track_count
                track_pct=$(echo "$item_json" | jq -r '.statistics.percentOfTracks // 0' 2>/dev/null) || true
                album_count=$(echo "$item_json" | jq -r '.statistics.albumCount // 0' 2>/dev/null) || true
                track_count=$(echo "$item_json" | jq -r '.statistics.trackCount // 0' 2>/dev/null) || true

                if [ -n "$album_count" ] && [ "$album_count" != "0" ] && [ "$album_count" != "null" ]; then
                    echo -e "  ${C_SUBTEXT0}Albums${S_RESET}     ${C_TEXT}${album_count}${S_RESET}"
                fi
                if [ -n "$track_count" ] && [ "$track_count" != "0" ] && [ "$track_count" != "null" ]; then
                    local trk_color="$C_GREEN"
                    local trk_pct_int="${track_pct%.*}"
                    (( trk_pct_int < 100 )) && trk_color="$C_YELLOW"
                    (( trk_pct_int < 50 )) && trk_color="$C_PEACH"
                    echo -e "  ${C_SUBTEXT0}Tracks${S_RESET}     ${trk_color}${track_pct}%${S_RESET} ${C_TEXT}collected${S_RESET} ${C_OVERLAY0}(${track_count} tracks)${S_RESET}"
                fi
                ;;
        esac

        # File location
        if [ -n "$item_path" ] && [ "$item_path" != "null" ]; then
            echo -e "  ${C_SUBTEXT0}Location${S_RESET}   ${C_TEAL}${item_path}${S_RESET}"
        fi

        # Jellyfin link
        echo ""
        echo -e "  ${C_GREEN}●${S_RESET} ${S_BOLD}${C_TEXT}Ready on Jellyfin${S_RESET} ${C_OVERLAY0}→${S_RESET} ${C_SAPPHIRE}http://jellyfin:8096${S_RESET}"

    # ── State: Waiting / Unreleased ──
    else
        echo ""

        # Check if it's unreleased
        if _check_unreleased "$service" "$item_json"; then
            echo -e "  ${C_PEACH}▸ NOT YET RELEASED${S_RESET}"
            echo ""
            echo -e "  ${C_SUBTEXT0}Status${S_RESET}     ${C_PEACH}${UNRELEASED_MSG}${S_RESET}"
            if [ -n "$UNRELEASED_DATE" ]; then
                echo -e "  ${C_SUBTEXT0}Expected${S_RESET}   ${C_TEXT}${UNRELEASED_DATE}${S_RESET}"
            fi
            echo ""
            if [ "$monitored" = "true" ]; then
                echo -e "  ${C_GREEN}✓${S_RESET} ${C_TEXT}Monitored — will download automatically when available${S_RESET}"
            else
                echo -e "  ${C_YELLOW}!${S_RESET} ${C_TEXT}Not monitored — enable monitoring to auto-grab${S_RESET}"
            fi
        else
            echo -e "  ${C_YELLOW}▸ WAITING FOR DOWNLOADS${S_RESET}"
            echo ""
            if [ "$monitored" = "true" ]; then
                echo -e "  ${C_GREEN}✓${S_RESET} ${C_TEXT}Monitored — searching for releases${S_RESET}"
            else
                echo -e "  ${C_YELLOW}!${S_RESET} ${C_TEXT}Not monitored — enable monitoring to search${S_RESET}"
            fi
        fi

        echo ""

        if $WATCH; then
            echo -e "  ${C_SAPPHIRE}●${S_RESET} ${C_TEXT}Watching for downloads...${S_RESET}"
            echo ""
            sleep 1
            _watch_journey "$service" "$item_id" "$title" "$api_key" "$WATCH_TIMEOUT"
        else
            if gum_confirm "Watch for downloads?"; then
                echo ""
                _watch_journey "$service" "$item_id" "$title" "$api_key" "$WATCH_TIMEOUT"
            else
                echo ""
                msg_dim "  Check progress anytime: arr downloads"
            fi
        fi
    fi
    echo ""
}

# Service-specific API details
_watch_api_config() {
    local service="$1"
    case "$service" in
        radarr)
            W_PORT=7878; W_API_VER="v3"
            W_QUEUE_FILTER="movieId"; W_ITEM_EP="movie"
            W_HAS_FILE_JQ='.hasFile'
            W_PATH_JQ='.movieFile.path // .path // ""'
            W_MEDIA_LABEL="Movies"
            ;;
        sonarr)
            W_PORT=8989; W_API_VER="v3"
            W_QUEUE_FILTER="seriesId"; W_ITEM_EP="series"
            W_HAS_FILE_JQ='(.statistics.episodeFileCount // 0) > 0'
            W_PATH_JQ='.path // ""'
            W_MEDIA_LABEL="TV Shows"
            ;;
        lidarr)
            W_PORT=8686; W_API_VER="v1"
            W_QUEUE_FILTER="artistId"; W_ITEM_EP="artist"
            W_HAS_FILE_JQ='(.statistics.percentOfTracks // 0) > 0'
            W_PATH_JQ='.path // ""'
            W_MEDIA_LABEL="Music"
            ;;
    esac
}

_watch_journey() {
    local service="$1"
    local item_id="$2"
    local title="$3"
    local api_key="$4"
    local timeout="$5"

    _watch_api_config "$service"

    local base_url="http://localhost:${W_PORT}/api/${W_API_VER}"

    # State tracking
    local stage="searching"  # searching -> grabbed -> downloading -> importing -> complete
    local release_name=""
    local dl_client=""
    local dl_progress=0       # 0-10000
    local dl_prev_progress=0
    local dl_size=""
    local dl_sizeleft=""
    local dl_timeleft=""
    local dl_speed=""
    local file_path=""
    local start_time elapsed_secs remaining_secs
    local frame_count=0

    start_time=$(date +%s)

    # Temp files for background fetch
    local fetch_tmp=$(mktemp /tmp/arr-watch.XXXXXX)
    local fetch_signal=$(mktemp /tmp/arr-watch-sig.XXXXXX)
    rm -f "$fetch_signal"
    local fetch_bg_pid=""

    # Cleanup
    _watch_cleanup() {
        rm -f "$fetch_tmp" "${fetch_tmp}.new" "$fetch_signal"
        printf '\e[?25h'
        printf '\e[?1049l'
        [[ -n "${fetch_bg_pid:-}" ]] && kill "$fetch_bg_pid" 2>/dev/null || true
        wait 2>/dev/null || true
    }
    trap _watch_cleanup EXIT INT TERM

    # Background fetch function
    _watch_fetch() {
        local w_stage="$stage"
        local w_release="" w_client="" w_progress=0 w_size="" w_sizeleft="" w_timeleft="" w_speed=""
        local w_has_file=false w_file_path=""

        # Check queue for this item
        local queue_json
        queue_json=$(curl -s --max-time 10 \
            -H "X-Api-Key: $api_key" \
            "${base_url}/queue?${W_QUEUE_FILTER}=${item_id}&includeUnknownSeriesItems=true" 2>/dev/null) || true

        # Find our item in the queue (extract first matching record)
        local record=""
        if [ -n "$queue_json" ]; then
            record=$(echo "$queue_json" | jq -c "[.records[]? | select(.${W_QUEUE_FILTER} == $item_id)] | .[0] // empty" 2>/dev/null) || true
        fi

        if [ -n "$record" ] && [ "$record" != "null" ]; then
            w_release=$(echo "$record" | jq -r '.title // ""' 2>/dev/null)
            w_client=$(echo "$record" | jq -r '.downloadClient // ""' 2>/dev/null)
            local status
            status=$(echo "$record" | jq -r '.trackedDownloadState // .status // ""' 2>/dev/null)

            w_size=$(echo "$record" | jq -r '.size // 0' 2>/dev/null)
            w_sizeleft=$(echo "$record" | jq -r '.sizeleft // 0' 2>/dev/null)
            w_timeleft=$(echo "$record" | jq -r '.timeleft // ""' 2>/dev/null)

            # Calculate progress from size/sizeleft (API doesn't provide progress directly)
            if [ -n "$w_size" ] && [ "$w_size" != "0" ] && [ "$w_size" != "null" ]; then
                local downloaded=$(( w_size - w_sizeleft ))
                (( downloaded < 0 )) && downloaded=0
                w_progress=$(( downloaded * 10000 / w_size ))
            else
                w_progress=0
            fi
            (( w_progress > 10000 )) && w_progress=10000

            case "$status" in
                downloading)
                    w_stage="downloading"
                    ;;
                importPending|imported)
                    w_stage="importing"
                    w_progress=10000
                    ;;
                *)
                    if [ -n "$w_release" ]; then
                        w_stage="grabbed"
                    fi
                    ;;
            esac
        fi

        # Check if file has landed
        local item_json
        item_json=$(curl -s --max-time 10 \
            -H "X-Api-Key: $api_key" \
            "${base_url}/${W_ITEM_EP}/${item_id}" 2>/dev/null) || true

        if [ -n "$item_json" ] && [ "$item_json" != "null" ]; then
            local has_file
            has_file=$(echo "$item_json" | jq -r "$W_HAS_FILE_JQ" 2>/dev/null)
            if [ "$has_file" = "true" ]; then
                w_has_file=true
                w_file_path=$(echo "$item_json" | jq -r "$W_PATH_JQ" 2>/dev/null)
                w_stage="complete"
            fi
        fi

        # If we're in grabbed/downloading and no queue entry but has file, it's complete
        if [ "$w_has_file" = "true" ]; then
            w_stage="complete"
        fi

        # Serialize
        {
            printf 'w_stage=%q\n' "$w_stage"
            printf 'w_release=%q\n' "$w_release"
            printf 'w_client=%q\n' "$w_client"
            echo "w_progress=$w_progress"
            printf 'w_size=%q\n' "$w_size"
            printf 'w_sizeleft=%q\n' "$w_sizeleft"
            printf 'w_timeleft=%q\n' "$w_timeleft"
            printf 'w_file_path=%q\n' "$w_file_path"
        } > "${fetch_tmp}.new" 2>/dev/null
        mv -f "${fetch_tmp}.new" "$fetch_tmp"
        touch "$fetch_signal"
    }

    _watch_load() {
        local w_stage="" w_release="" w_client="" w_progress=0
        local w_size="" w_sizeleft="" w_timeleft="" w_file_path=""

        source "$fetch_tmp"

        dl_prev_progress=$dl_progress
        stage="$w_stage"
        release_name="$w_release"
        dl_client="$w_client"
        dl_progress=$w_progress
        dl_size="$w_size"
        dl_sizeleft="$w_sizeleft"
        dl_timeleft="$w_timeleft"
        file_path="$w_file_path"
    }

    _watch_render() {
        local now_secs
        now_secs=$(date +%s)
        elapsed_secs=$(( now_secs - start_time ))
        remaining_secs=$(( timeout - elapsed_secs ))
        (( remaining_secs < 0 )) && remaining_secs=0

        local remaining_min=$(( remaining_secs / 60 ))

        local frame=""
        frame+='\e[H\e[2J\e[H'
        frame+="\n"

        # Title box
        local inner=38
        local title_len=${#title}
        local total_pad=$(( inner - title_len ))
        (( total_pad < 0 )) && total_pad=0
        local pad_left=$(( total_pad / 2 ))
        local pad_right=$(( total_pad - pad_left ))

        frame+="  ${C_SAPPHIRE}╭"
        for (( i=0; i<inner; i++ )); do frame+="─"; done
        frame+="╮${S_RESET}\n"

        frame+="  ${C_SAPPHIRE}│${S_RESET}"
        for (( i=0; i<pad_left; i++ )); do frame+=" "; done
        frame+="${S_BOLD}${C_TEXT}${title}${S_RESET}"
        for (( i=0; i<pad_right; i++ )); do frame+=" "; done
        frame+="${C_SAPPHIRE}│${S_RESET}\n"

        frame+="  ${C_SAPPHIRE}╰"
        for (( i=0; i<inner; i++ )); do frame+="─"; done
        frame+="╯${S_RESET}\n"

        frame+="\n"

        # Spinner frames (use frame_count for smooth animation)
        local spin_idx=$(( frame_count % ${#BRAILLE_FRAMES[@]} ))
        local spinner="${BRAILLE_FRAMES[$spin_idx]}"

        # Stage 1: Added
        frame+="  ${C_GREEN}✓${S_RESET} ${C_TEXT}Added to ${service^}${S_RESET}\n"

        # Stage 2+: Searching or grabbed
        case "$stage" in
            searching)
                frame+="  ${C_SAPPHIRE}${spinner}${S_RESET} ${C_SUBTEXT1}Searching for releases...${S_RESET}\n"
                ;;
            grabbed|downloading|importing|complete)
                frame+="  ${C_GREEN}✓${S_RESET} ${C_TEXT}Release grabbed${S_RESET}\n"
                if [ -n "$release_name" ]; then
                    local dname="$release_name"
                    if (( ${#dname} > 55 )); then
                        dname="${dname:0:52}..."
                    fi
                    frame+="    ${C_SUBTEXT0}${dname}${S_RESET}\n"
                fi
                if [ -n "$dl_client" ]; then
                    frame+="    ${C_OVERLAY0}via ${dl_client}${S_RESET}\n"
                fi
                ;;
        esac

        # Stage 3: Downloading
        case "$stage" in
            downloading)
                frame+="\n"
                frame+="  ${C_SAPPHIRE}${spinner}${S_RESET} ${C_SUBTEXT1}Downloading...${S_RESET}\n"

                # Progress bar
                _render_watch_bar "$dl_progress" "$C_SAPPHIRE"
                frame+="    ${REPLY}\n"

                # Size and ETA line
                local size_h="" sizeleft_h="" detail_parts=""
                if [ -n "$dl_size" ] && [ "$dl_size" != "0" ] && [ "$dl_size" != "null" ]; then
                    size_h=$(human_size "$dl_size")
                    if [ -n "$dl_sizeleft" ] && [ "$dl_sizeleft" != "0" ] && [ "$dl_sizeleft" != "null" ]; then
                        sizeleft_h=$(human_size "$dl_sizeleft")
                        local downloaded=$(( dl_size - dl_sizeleft ))
                        (( downloaded < 0 )) && downloaded=0
                        local downloaded_h
                        downloaded_h=$(human_size "$downloaded")
                        detail_parts="${downloaded_h} / ${size_h}"
                    else
                        detail_parts="${size_h}"
                    fi
                fi
                if [ -n "$dl_timeleft" ] && [ "$dl_timeleft" != "null" ] && [ "$dl_timeleft" != "" ]; then
                    [ -n "$detail_parts" ] && detail_parts+="    "
                    detail_parts+="ETA ${dl_timeleft}"
                fi
                if [ -n "$detail_parts" ]; then
                    frame+="    ${C_SUBTEXT0}${detail_parts}${S_RESET}\n"
                fi
                ;;
            importing)
                frame+="\n"
                local size_h=""
                if [ -n "$dl_size" ] && [ "$dl_size" != "0" ] && [ "$dl_size" != "null" ]; then
                    size_h=" ($(human_size "$dl_size"))"
                fi
                frame+="  ${C_GREEN}✓${S_RESET} ${C_TEXT}Downloaded${size_h}${S_RESET}\n"
                frame+="  ${C_SAPPHIRE}${spinner}${S_RESET} ${C_SUBTEXT1}Importing to library...${S_RESET}\n"
                ;;
            complete)
                frame+="\n"
                local size_h=""
                if [ -n "$dl_size" ] && [ "$dl_size" != "0" ] && [ "$dl_size" != "null" ]; then
                    size_h=" ($(human_size "$dl_size"))"
                fi
                frame+="  ${C_GREEN}✓${S_RESET} ${C_TEXT}Downloaded${size_h}${S_RESET}\n"
                frame+="  ${C_GREEN}✓${S_RESET} ${C_TEXT}Imported!${S_RESET}\n"
                if [ -n "$file_path" ] && [ "$file_path" != "null" ]; then
                    frame+="    ${C_SUBTEXT0}${file_path}${S_RESET}\n"
                fi
                frame+="\n"

                # Celebration line
                local emoji icon_msg
                case "$service" in
                    radarr) emoji="🍿"; icon_msg="Ready to watch" ;;
                    sonarr) emoji="📺"; icon_msg="Ready to binge" ;;
                    lidarr) emoji="🎧"; icon_msg="Ready to listen" ;;
                esac
                frame+="  ${emoji} ${S_BOLD}${C_GREEN}${icon_msg} on Jellyfin${S_RESET}"
                frame+=" ${C_OVERLAY0}→${S_RESET} ${C_SAPPHIRE}http://jellyfin:8096${S_RESET}\n"
                ;;
        esac

        # Bottom status bar
        frame+="\n"
        local div_line=""
        for (( i=0; i<46; i++ )); do div_line+="─"; done
        frame+="  ${C_SURFACE1}${div_line}${S_RESET}\n"

        if [ "$stage" = "complete" ]; then
            frame+="\n  ${C_OVERLAY0}Done!${S_RESET} ${C_SURFACE1}•${S_RESET} ${C_OVERLAY0}q${S_RESET} ${C_SURFACE1}quit${S_RESET}\n"
        else
            frame+="\n  ${C_OVERLAY0}Watching${S_RESET}"
            frame+=" ${C_SURFACE1}•${S_RESET} ${C_OVERLAY0}q${S_RESET} ${C_SURFACE1}quit${S_RESET}"
            frame+=" ${C_SURFACE1}•${S_RESET} ${C_OVERLAY0}r${S_RESET} ${C_SURFACE1}refresh${S_RESET}"
            frame+=" ${C_SURFACE1}•${S_RESET} ${C_OVERLAY0}timeout ${remaining_min}m${S_RESET}\n"
        fi

        printf '%b' "$frame"
    }

    # Enter alternate screen
    printf '\e[?1049h'
    printf '\e[?25l'

    # Start first fetch
    ( _watch_fetch ) &
    fetch_bg_pid=$!
    local fetch_running=true
    local last_fetch_start
    last_fetch_start=$(date +%s%3N 2>/dev/null || date +%s)

    while true; do
        local now_secs
        now_secs=$(date +%s)
        elapsed_secs=$(( now_secs - start_time ))

        # Timeout check
        if (( elapsed_secs >= timeout )) && [ "$stage" != "complete" ]; then
            _watch_render
            sleep 1
            printf '\e[?25h'
            printf '\e[?1049l'
            echo ""
            msg_info "Watch timed out after $(( timeout / 60 ))m. Your ${service^} is still working!"
            msg_dim "  Check back with: arr downloads"
            echo ""
            trap - EXIT INT TERM
            rm -f "$fetch_tmp" "${fetch_tmp}.new" "$fetch_signal"
            return 0
        fi

        # Check for completed background fetch
        if [[ -f "$fetch_signal" ]]; then
            _watch_load
            rm -f "$fetch_signal"
            fetch_running=false
        fi

        _watch_render

        # Auto-exit on complete (give user a moment to see it)
        if [ "$stage" = "complete" ]; then
            # Show completion for 5 seconds then exit, or let user press q
            local complete_wait=0
            while (( complete_wait < 50 )); do
                local key=""
                read -s -n1 -t 0.1 key 2>/dev/null || true
                case "$key" in
                    q|Q) break 2 ;;
                esac
                (( complete_wait++ ))
            done
            break
        fi

        # Start new fetch if interval elapsed and not running
        if ! $fetch_running; then
            local now_ms
            now_ms=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
            local elapsed_since=$(( now_ms - last_fetch_start ))
            if (( elapsed_since >= 3000 )); then
                ( _watch_fetch ) &
                fetch_bg_pid=$!
                fetch_running=true
                last_fetch_start=$now_ms
            fi
        fi

        (( frame_count++ ))

        # Check for keypress
        local key=""
        read -s -n1 -t 0.1 key 2>/dev/null || true
        case "$key" in
            q|Q) break ;;
            r|R)
                if ! $fetch_running; then
                    ( _watch_fetch ) &
                    fetch_bg_pid=$!
                    fetch_running=true
                    last_fetch_start=$(date +%s%3N 2>/dev/null || echo "$(date +%s)000")
                fi
                ;;
        esac
    done

    # Clean exit
    printf '\e[?25h'
    printf '\e[?1049l'
    trap - EXIT INT TERM
    rm -f "$fetch_tmp" "${fetch_tmp}.new" "$fetch_signal"
    [[ -n "${fetch_bg_pid:-}" ]] && kill "$fetch_bg_pid" 2>/dev/null || true

    echo ""
    if [ "$stage" = "complete" ]; then
        local emoji
        case "$service" in
            radarr) emoji="🍿" ;;
            sonarr) emoji="📺" ;;
            lidarr) emoji="🎧" ;;
        esac
        msg_success "${emoji} ${title} is ready on Jellyfin!"
    else
        msg_info "${title} is still being processed."
        msg_dim "  Check progress: arr downloads"
    fi
    echo ""
}

# ── Request: Movie (Radarr) ──────────────────────────────────────────────────

request_movie() {
    local search_term="${1:-}"
    _check_running radarr

    local api_key
    api_key=$(_get_api_key radarr)
    [ -z "$api_key" ] && { msg_error "Could not find Radarr API key."; exit 1; }

    if [ -z "$search_term" ]; then
        search_term=$(_search_prompt "Movie title")
        [ -z "$search_term" ] && { msg_dim "Cancelled."; exit 0; }
    fi

    msg_info "Searching Radarr for \"${search_term}\"..."

    local json
    json=$(_api_get "http://localhost:7878/api/v3/movie/lookup?term=$(printf '%s' "$search_term" | jq -sRr @uri)" "$api_key") || exit 1

    # Pre-check: if the best match is already in library, skip picker
    local top_id
    top_id=$(echo "$json" | jq -r '.[0].id // empty' 2>/dev/null)
    if [ -n "$top_id" ]; then
        local top_title top_year
        top_title=$(echo "$json" | jq -r '.[0].title')
        top_year=$(echo "$json" | jq -r '.[0].year // "?"')
        _already_owned "radarr" "$top_id" "${top_title} (${top_year})" "$api_key"
        exit 0
    fi

    # Parse results: ID|Display — better formatting with owned markers
    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.tmdbId)|\(.title) (\(.year // "?"))  \u2605 \(.ratings.imdb.value // .ratings.tmdb.value // "?")  \u2022  \(.runtime // "?")m  \u2022  \([.genres[0:2] | .[]] | join(", "))\(if .id then "  \u2713 IN LIBRARY" else "" end)"
    ' 2>/dev/null)

    if [ ${#lines[@]} -eq 0 ]; then
        msg_warn "No results found for \"${search_term}\""
        exit 0
    fi

    echo ""
    local choice
    choice=$(_pick_result "Select a movie" "${lines[@]}") || { msg_dim "Cancelled."; exit 0; }

    local tmdb_id="${choice%%|*}"
    [ -z "$tmdb_id" ] && { msg_dim "Cancelled."; exit 0; }

    # Get full details for the selected movie
    local detail
    detail=$(echo "$json" | jq -r ".[] | select(.tmdbId == $tmdb_id)")

    local title year runtime genres overview in_library imdb_id imdb_rating rt_score certification
    title=$(echo "$detail" | jq -r '.title')
    year=$(echo "$detail" | jq -r '.year // "?"')
    runtime=$(echo "$detail" | jq -r '.runtime // "?"')
    genres=$(echo "$detail" | jq -r '[.genres[0:3] | .[]] | join(", ")')
    overview=$(echo "$detail" | jq -r '.overview // ""')
    in_library=$(echo "$detail" | jq -r '.id // empty')
    imdb_id=$(echo "$detail" | jq -r '.imdbId // empty')
    imdb_rating=$(echo "$detail" | jq -r '.ratings.imdb.value // empty')
    rt_score=$(echo "$detail" | jq -r '.ratings.rottenTomatoes.value // empty')
    certification=$(echo "$detail" | jq -r '.certification // empty')

    if [ -n "$in_library" ]; then
        _already_owned "radarr" "$in_library" "${title} (${year})" "$api_key"
        exit 0
    fi

    # ── Movie detail card ──
    local meta_parts=""
    [ "$runtime" != "?" ] && [ "$runtime" != "0" ] && meta_parts="${runtime}m"
    [ -n "$genres" ] && meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${genres}"
    if [ -n "$imdb_rating" ] && [ "$imdb_rating" != "0" ]; then
        meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${C_YELLOW}${imdb_rating}${S_RESET} IMDb"
    fi
    if [ -n "$rt_score" ] && [ "$rt_score" != "0" ]; then
        meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${C_GREEN}${rt_score}%${S_RESET} RT"
    fi
    [ -n "$certification" ] && meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${C_OVERLAY0}${certification}${S_RESET}"

    local imdb_url=""
    [ -n "$imdb_id" ] && imdb_url="https://www.imdb.com/title/${imdb_id}/"

    _detail_card "$title" "(${year})" "$meta_parts" "$overview" "$imdb_url"

    # Check if unreleased
    local is_unreleased=false
    if _check_unreleased "radarr" "$detail"; then
        is_unreleased=true
        echo ""
        echo -e "  ${C_PEACH}▸ NOT YET RELEASED${S_RESET}"
        echo -e "    ${C_PEACH}${UNRELEASED_MSG}${S_RESET}"
        [ -n "$UNRELEASED_DATE" ] && echo -e "    ${C_TEXT}${UNRELEASED_DATE}${S_RESET}"
        echo -e "    ${C_SUBTEXT0}Radarr will monitor and grab it automatically${S_RESET}"
    fi

    # Show available releases from Prowlarr (skip for unreleased)
    if ! $is_unreleased; then
        echo ""
        _release_preview "${title} ${year}" "2000,2010,2020,2030,2040,2045,2050,2060" "radarr"

        # Warn if user picked a release below their quality cutoff
        if $RP_BELOW_CUTOFF; then
            echo ""
            echo -e "  ${C_YELLOW}!${S_RESET} ${C_TEXT}Below your upgrade target${S_RESET} ${C_OVERLAY0}(${RP_CUTOFF_NAME})${S_RESET}"
            echo -e "    ${C_SUBTEXT0}Radarr will grab this but may upgrade it later${S_RESET}"
            echo ""
            if ! gum_confirm "Continue with lower quality?"; then
                msg_dim "Cancelled."
                exit 0
            fi
        fi
    fi

    echo ""
    local confirm_msg="Add \"${title}\" to Radarr?"
    $is_unreleased && confirm_msg="Monitor \"${title}\" in Radarr? (will download when released)"

    if ! gum_confirm "$confirm_msg"; then
        msg_dim "Cancelled."
        exit 0
    fi

    # Build add payload
    local add_body
    add_body=$(echo "$detail" | jq '{
        title: .title,
        tmdbId: .tmdbId,
        year: .year,
        images: .images,
        monitored: true,
        qualityProfileId: 1,
        rootFolderPath: "/data/media/movies",
        minimumAvailability: "announced",
        addOptions: { searchForMovie: true }
    }')

    echo ""
    local add_result
    add_result=$(_api_post "http://localhost:7878/api/v3/movie" "$api_key" "$add_body") || exit 0

    local item_id
    item_id=$(echo "$add_result" | jq -r '.id // empty' 2>/dev/null)

    if $is_unreleased; then
        msg_success "${title} (${year}) is being monitored! It will download when released."
        echo ""
    elif $WATCH && [ -n "$item_id" ]; then
        _watch_journey "radarr" "$item_id" "${title} (${year})" "$api_key" "$WATCH_TIMEOUT"
    else
        msg_success "${title} (${year}) added to Radarr! Searching for downloads..."
        echo ""
    fi
}

# ── Request: TV Show (Sonarr) ────────────────────────────────────────────────

request_tv() {
    local search_term="${1:-}"
    _check_running sonarr

    local api_key
    api_key=$(_get_api_key sonarr)
    [ -z "$api_key" ] && { msg_error "Could not find Sonarr API key."; exit 1; }

    if [ -z "$search_term" ]; then
        search_term=$(_search_prompt "TV show title")
        [ -z "$search_term" ] && { msg_dim "Cancelled."; exit 0; }
    fi

    msg_info "Searching Sonarr for \"${search_term}\"..."

    local json
    json=$(_api_get "http://localhost:8989/api/v3/series/lookup?term=$(printf '%s' "$search_term" | jq -sRr @uri)" "$api_key") || exit 1

    # Pre-check: if the best match is already in library, skip picker
    local top_id
    top_id=$(echo "$json" | jq -r '.[0].id // empty' 2>/dev/null)
    if [ -n "$top_id" ]; then
        local top_title top_year
        top_title=$(echo "$json" | jq -r '.[0].title')
        top_year=$(echo "$json" | jq -r '.[0].year // "?"')
        _already_owned "sonarr" "$top_id" "${top_title} (${top_year})" "$api_key"
        exit 0
    fi

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.tvdbId)|\(.title) (\(.year // "?"))  \u2605 \(.ratings.value // "?")  \u2022  \(.network // "?")  \u2022  \(.seasons | length) seasons\(if .id then "  \u2713 IN LIBRARY" else "" end)"
    ' 2>/dev/null)

    if [ ${#lines[@]} -eq 0 ]; then
        msg_warn "No results found for \"${search_term}\""
        exit 0
    fi

    echo ""
    local choice
    choice=$(_pick_result "Select a TV show" "${lines[@]}") || { msg_dim "Cancelled."; exit 0; }

    local tvdb_id="${choice%%|*}"
    [ -z "$tvdb_id" ] && { msg_dim "Cancelled."; exit 0; }

    local detail
    detail=$(echo "$json" | jq -r ".[] | select(.tvdbId == $tvdb_id)")

    local title year network seasons overview in_library imdb_id
    title=$(echo "$detail" | jq -r '.title')
    year=$(echo "$detail" | jq -r '.year // "?"')
    network=$(echo "$detail" | jq -r '.network // "?"')
    seasons=$(echo "$detail" | jq -r '.seasons | length')
    overview=$(echo "$detail" | jq -r '.overview // ""')
    in_library=$(echo "$detail" | jq -r '.id // empty')
    imdb_id=$(echo "$detail" | jq -r '.imdbId // empty')

    if [ -n "$in_library" ]; then
        _already_owned "sonarr" "$in_library" "${title} (${year})" "$api_key"
        exit 0
    fi

    # ── TV detail card ──
    local meta_parts=""
    [ "$network" != "?" ] && meta_parts="${network}"
    [ -n "$seasons" ] && [ "$seasons" != "0" ] && meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${seasons} seasons"
    local tv_rating
    tv_rating=$(echo "$detail" | jq -r '.ratings.value // empty' 2>/dev/null) || true
    if [ -n "$tv_rating" ] && [ "$tv_rating" != "0" ]; then
        meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${C_YELLOW}${tv_rating}${S_RESET}"
    fi

    local imdb_url=""
    [ -n "$imdb_id" ] && imdb_url="https://www.imdb.com/title/${imdb_id}/"

    _detail_card "$title" "(${year})" "$meta_parts" "$overview" "$imdb_url"

    # Check if unreleased
    local is_unreleased=false
    if _check_unreleased "sonarr" "$detail"; then
        is_unreleased=true
        echo ""
        echo -e "  ${C_PEACH}▸ NOT YET RELEASED${S_RESET}"
        echo -e "    ${C_PEACH}${UNRELEASED_MSG}${S_RESET}"
        [ -n "$UNRELEASED_DATE" ] && echo -e "    ${C_TEXT}${UNRELEASED_DATE}${S_RESET}"
        echo -e "    ${C_SUBTEXT0}Sonarr will monitor and grab episodes as they air${S_RESET}"
    fi

    # Show available releases from Prowlarr (skip for unreleased)
    if ! $is_unreleased; then
        echo ""
        _release_preview "${title}" "5000,5010,5020,5030,5040,5045,5050" "sonarr"

        if $RP_BELOW_CUTOFF; then
            echo ""
            echo -e "  ${C_YELLOW}!${S_RESET} ${C_TEXT}Below your upgrade target${S_RESET} ${C_OVERLAY0}(${RP_CUTOFF_NAME})${S_RESET}"
            echo -e "    ${C_SUBTEXT0}Sonarr will grab this but may upgrade it later${S_RESET}"
            echo ""
            if ! gum_confirm "Continue with lower quality?"; then
                msg_dim "Cancelled."
                exit 0
            fi
        fi
    fi

    echo ""
    local confirm_msg="Add \"${title}\" to Sonarr?"
    $is_unreleased && confirm_msg="Monitor \"${title}\" in Sonarr? (will download as episodes air)"

    if ! gum_confirm "$confirm_msg"; then
        msg_dim "Cancelled."
        exit 0
    fi

    local add_body
    add_body=$(echo "$detail" | jq '{
        title: .title,
        tvdbId: .tvdbId,
        year: .year,
        images: .images,
        seasons: .seasons,
        monitored: true,
        qualityProfileId: 1,
        languageProfileId: 1,
        rootFolderPath: "/data/media/tv",
        seasonFolder: true,
        addOptions: { monitor: "all", searchForMissingEpisodes: true, searchForCutoffUnmetEpisodes: false }
    }')

    echo ""
    local add_result
    add_result=$(_api_post "http://localhost:8989/api/v3/series" "$api_key" "$add_body") || exit 0

    local item_id
    item_id=$(echo "$add_result" | jq -r '.id // empty' 2>/dev/null)

    if $is_unreleased; then
        msg_success "${title} (${year}) is being monitored! Episodes will download as they air."
        echo ""
    elif $WATCH && [ -n "$item_id" ]; then
        _watch_journey "sonarr" "$item_id" "${title} (${year})" "$api_key" "$WATCH_TIMEOUT"
    else
        msg_success "${title} (${year}) added to Sonarr! Searching for episodes..."
        echo ""
    fi
}

# ── Request: Music (Lidarr) ──────────────────────────────────────────────────

request_music() {
    local search_term="${1:-}"
    _check_running lidarr

    local api_key
    api_key=$(_get_api_key lidarr)
    [ -z "$api_key" ] && { msg_error "Could not find Lidarr API key."; exit 1; }

    if [ -z "$search_term" ]; then
        search_term=$(_search_prompt "Artist name")
        [ -z "$search_term" ] && { msg_dim "Cancelled."; exit 0; }
    fi

    msg_info "Searching Lidarr for \"${search_term}\"..."

    local json
    json=$(_api_get "http://localhost:8686/api/v1/artist/lookup?term=$(printf '%s' "$search_term" | jq -sRr @uri)" "$api_key") || exit 1

    # Pre-check: if the best match is already in library, skip picker
    local top_id
    top_id=$(echo "$json" | jq -r '.[0].id // empty' 2>/dev/null)
    if [ -n "$top_id" ]; then
        local top_name
        top_name=$(echo "$json" | jq -r '.[0].artistName')
        _already_owned "lidarr" "$top_id" "${top_name}" "$api_key"
        exit 0
    fi

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.foreignArtistId)|\(.artistName)  \u2022  \(.artistType // "?")  \u2605 \(.ratings.value // "?")\(if .id then "  \u2713 IN LIBRARY" else "" end)"
    ' 2>/dev/null)

    if [ ${#lines[@]} -eq 0 ]; then
        msg_warn "No results found for \"${search_term}\""
        exit 0
    fi

    echo ""
    local choice
    choice=$(_pick_result "Select an artist" "${lines[@]}") || { msg_dim "Cancelled."; exit 0; }

    local foreign_id="${choice%%|*}"
    [ -z "$foreign_id" ] && { msg_dim "Cancelled."; exit 0; }

    local detail
    detail=$(echo "$json" | jq -r ".[] | select(.foreignArtistId == \"$foreign_id\")")

    local name artist_type genres overview in_library
    name=$(echo "$detail" | jq -r '.artistName')
    artist_type=$(echo "$detail" | jq -r '.artistType // "?"')
    genres=$(echo "$detail" | jq -r '[.genres[0:3] | .[]] | join(", ")')
    overview=$(echo "$detail" | jq -r '.overview // ""')
    in_library=$(echo "$detail" | jq -r '.id // empty')

    if [ -n "$in_library" ]; then
        _already_owned "lidarr" "$in_library" "${name}" "$api_key"
        exit 0
    fi

    # ── Music detail card ──
    local meta_parts=""
    [ "$artist_type" != "?" ] && meta_parts="${artist_type}"
    [ -n "$genres" ] && meta_parts="${meta_parts:+${meta_parts}  ${C_SURFACE1}•${S_RESET}  }${genres}"

    _detail_card "$name" "" "$meta_parts" "$overview"

    # Show available releases from Prowlarr
    echo ""
    _release_preview "${name}" "3000,3010,3020,3030,3040,3050" "lidarr"

    if $RP_BELOW_CUTOFF; then
        echo ""
        echo -e "  ${C_YELLOW}!${S_RESET} ${C_TEXT}Below your upgrade target${S_RESET} ${C_OVERLAY0}(${RP_CUTOFF_NAME})${S_RESET}"
        echo -e "    ${C_SUBTEXT0}Lidarr will grab this but may upgrade it later${S_RESET}"
        echo ""
        if ! gum_confirm "Continue with lower quality?"; then
            msg_dim "Cancelled."
            exit 0
        fi
    fi

    echo ""
    if ! gum_confirm "Add \"${name}\" to Lidarr? (all albums will be monitored)"; then
        msg_dim "Cancelled."
        exit 0
    fi

    local add_body
    add_body=$(echo "$detail" | jq '{
        artistName: .artistName,
        foreignArtistId: .foreignArtistId,
        images: .images,
        monitored: true,
        qualityProfileId: 1,
        metadataProfileId: 1,
        rootFolderPath: "/data/media/music",
        monitorNewItems: "all",
        addOptions: { monitor: "all", searchForMissingAlbums: true }
    }')

    echo ""
    local add_result
    add_result=$(_api_post "http://localhost:8686/api/v1/artist" "$api_key" "$add_body") || exit 0

    local item_id
    item_id=$(echo "$add_result" | jq -r '.id // empty' 2>/dev/null)

    if $WATCH && [ -n "$item_id" ]; then
        _watch_journey "lidarr" "$item_id" "${name}" "$api_key" "$WATCH_TIMEOUT"
    else
        msg_success "${name} added to Lidarr! Searching for albums..."
        echo ""
    fi
}

# ── Request: Book (LazyLibrarian) ────────────────────────────────────────────

request_book() {
    local search_term="${1:-}"
    _check_running lazylibrarian

    local api_key
    api_key=$(_ll_ensure_apikey) || exit 1
    [ -z "$api_key" ] && { msg_error "Could not get LazyLibrarian API key."; exit 1; }

    if [ -z "$search_term" ]; then
        search_term=$(_search_prompt "Book title")
        [ -z "$search_term" ] && { msg_dim "Cancelled."; exit 0; }
    fi

    msg_info "Searching LazyLibrarian for \"${search_term}\"..."

    local json
    json=$(_api_get "http://localhost:5299/api?cmd=searchBook&name=$(printf '%s' "$search_term" | jq -sRr @uri)&apikey=$api_key") || exit 1

    # LazyLibrarian wraps results in {Success, Data}
    local success
    success=$(echo "$json" | jq -r '.Success' 2>/dev/null)
    if [ "$success" != "true" ]; then
        local err_msg
        err_msg=$(echo "$json" | jq -r '.Error.Message // "Unknown error"' 2>/dev/null)
        msg_error "LazyLibrarian API error: $err_msg"
        msg_dim "  Check the service logs or try the web UI."
        exit 1
    fi

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .Data[0:15] | .[] |
        "\(.bookid // .BookID // "")|\(.title // .Title // "?") \u2014 \(.author // .Author // "?") (\(.year // .Year // "?"))"
    ' 2>/dev/null)

    if [ ${#lines[@]} -eq 0 ]; then
        msg_warn "No results found for \"${search_term}\""
        exit 0
    fi

    echo ""
    local choice
    choice=$(_pick_result "Select a book" "${lines[@]}") || { msg_dim "Cancelled."; exit 0; }

    local book_id="${choice%%|*}"
    [ -z "$book_id" ] && { msg_dim "Cancelled."; exit 0; }

    local display="${choice#*|}"
    echo ""
    echo -e "  ${C_TEXT}${display}${S_RESET}"

    echo ""
    if ! gum_confirm "Add this book to LazyLibrarian?"; then
        msg_dim "Cancelled."
        exit 0
    fi

    echo ""
    local add_json
    add_json=$(_api_get "http://localhost:5299/api?cmd=addBook&id=$book_id&apikey=$api_key") || exit 1

    msg_success "Book added to LazyLibrarian! It will be searched for download."
    echo ""
}

# ── Request: Audiobook (LazyLibrarian) ───────────────────────────────────────

request_audiobook() {
    # LazyLibrarian handles both ebooks and audiobooks through the same search
    # The configured providers determine what gets downloaded
    msg_dim "  Audiobooks use the same search as books in LazyLibrarian."
    msg_dim "  Your provider config determines if you get ebook or audiobook."
    echo ""
    request_book "$@"
}

# ── Request: Author (LazyLibrarian) ──────────────────────────────────────────

request_author() {
    local search_term="${1:-}"
    _check_running lazylibrarian

    local api_key
    api_key=$(_ll_ensure_apikey) || exit 1
    [ -z "$api_key" ] && { msg_error "Could not get LazyLibrarian API key."; exit 1; }

    if [ -z "$search_term" ]; then
        search_term=$(_search_prompt "Author name")
        [ -z "$search_term" ] && { msg_dim "Cancelled."; exit 0; }
    fi

    msg_info "Searching LazyLibrarian for author \"${search_term}\"..."

    local json
    json=$(_api_get "http://localhost:5299/api?cmd=searchAuthor&name=$(printf '%s' "$search_term" | jq -sRr @uri)&apikey=$api_key") || exit 1

    local success
    success=$(echo "$json" | jq -r '.Success' 2>/dev/null)
    if [ "$success" != "true" ]; then
        local err_msg
        err_msg=$(echo "$json" | jq -r '.Error.Message // "Unknown error"' 2>/dev/null)
        msg_error "LazyLibrarian API error: $err_msg"
        msg_dim "  Check the service logs or try the web UI."
        exit 1
    fi

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .Data[0:15] | .[] |
        "\(.authorid // .AuthorID // "")|\(.name // .Name // "?")"
    ' 2>/dev/null)

    if [ ${#lines[@]} -eq 0 ]; then
        msg_warn "No results found for \"${search_term}\""
        exit 0
    fi

    echo ""
    local choice
    choice=$(_pick_result "Select an author" "${lines[@]}") || { msg_dim "Cancelled."; exit 0; }

    local author_id="${choice%%|*}"
    [ -z "$author_id" ] && { msg_dim "Cancelled."; exit 0; }

    local display="${choice#*|}"
    echo ""
    if ! gum_confirm "Add author \"${display}\" to LazyLibrarian? (all works will be monitored)"; then
        msg_dim "Cancelled."
        exit 0
    fi

    echo ""
    local add_json
    add_json=$(_api_get "http://localhost:5299/api?cmd=addAuthor&id=$author_id&apikey=$api_key") || exit 1

    msg_success "Author \"${display}\" added to LazyLibrarian! All works will be monitored."
    echo ""
}

# ── Request: Game (QuestArr) ─────────────────────────────────────────────────

request_game() {
    local search_term="${1:-}"
    _check_running questarr

    local token
    token=$(_qa_get_token) || exit 1
    [ -z "$token" ] && { msg_error "Could not authenticate with QuestArr."; exit 1; }

    if [ -z "$search_term" ]; then
        search_term=$(_search_prompt "Game title")
        [ -z "$search_term" ] && { msg_dim "Cancelled."; exit 0; }
    fi

    msg_info "Searching QuestArr for \"${search_term}\"..."

    local json
    json=$(curl -s --max-time 15 \
        -H "Authorization: Bearer $token" \
        "http://localhost:5002/api/games/search?q=$(printf '%s' "$search_term" | jq -sRr @uri)" 2>/dev/null) || {
        msg_error "Could not reach QuestArr."
        msg_dim "  Check the service logs or try the web UI."
        exit 1
    }

    # Check for auth error
    if echo "$json" | jq -e '.error' &>/dev/null; then
        msg_error "QuestArr: $(echo "$json" | jq -r '.error')"
        rm -f /tmp/arr-questarr-jwt
        exit 1
    fi

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.id // .igdbId // "")|\(.name // .title // "?") (\(.releaseYear // .year // "?"))"
    ' 2>/dev/null)

    if [ ${#lines[@]} -eq 0 ]; then
        msg_warn "No results found for \"${search_term}\""
        exit 0
    fi

    echo ""
    local choice
    choice=$(_pick_result "Select a game" "${lines[@]}") || { msg_dim "Cancelled."; exit 0; }

    local game_id="${choice%%|*}"
    [ -z "$game_id" ] && { msg_dim "Cancelled."; exit 0; }

    local display="${choice#*|}"
    echo ""
    if ! gum_confirm "Add \"${display}\" to QuestArr?"; then
        msg_dim "Cancelled."
        exit 0
    fi

    echo ""
    local add_result
    add_result=$(curl -s --max-time 15 \
        -X POST -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "{\"igdbId\": $game_id}" \
        "http://localhost:5002/api/games" 2>/dev/null) || {
        msg_error "Could not add game."
        msg_dim "  Check the service logs or try the web UI."
        exit 1
    }

    if echo "$add_result" | jq -e '.error' &>/dev/null; then
        local err
        err=$(echo "$add_result" | jq -r '.error')
        if echo "$err" | grep -qi "already"; then
            msg_warn "Game is already in your library!"
        else
            msg_error "QuestArr: $err"
        fi
        exit 0
    fi

    msg_success "\"${display}\" added to QuestArr!"
    echo ""
}

# ── Main Dispatch ────────────────────────────────────────────────────────────

show_request_help() {
    echo ""
    echo -e "  ${S_BOLD}${C_TEXT}Usage:${S_RESET} ${C_SUBTEXT0}arr request <type> [search term]${S_RESET}"
    echo ""
    echo -e "  ${C_SAPPHIRE}${S_BOLD}Content Types${S_RESET}"
    echo -e "  ${C_SURFACE2}|${S_RESET}"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "movie" "Search & add movies (Radarr)"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "tv" "Search & add TV shows (Sonarr)"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "music" "Search & add artists (Lidarr)"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "book" "Search & add books (LazyLibrarian)"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "audiobook" "Search & add audiobooks (LazyLibrarian)"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "author" "Add an author — monitors all works"
    printf "  ${C_SURFACE2}└─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "game" "Search & add games (QuestArr)"
    echo ""
    echo -e "  ${C_PEACH}${S_BOLD}Flags${S_RESET}"
    echo -e "  ${C_SURFACE2}|${S_RESET}"
    printf "  ${C_SURFACE2}├─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "--watch" "Follow the file's journey live"
    printf "  ${C_SURFACE2}└─${S_RESET} ${C_TEXT}%-14s${S_RESET} ${C_OVERLAY0}%s${S_RESET}\n" "--timeout N" "Watch timeout in seconds (default: 1800)"
    echo ""
    echo -e "  ${C_SUBTEXT0}Examples:${S_RESET}"
    echo -e "    ${C_TEXT}arr request movie \"Inception\"${S_RESET}"
    echo -e "    ${C_TEXT}arr request tv \"Breaking Bad\" --watch${S_RESET}"
    echo -e "    ${C_TEXT}arr request music \"Pink Floyd\" --watch --timeout 3600${S_RESET}"
    echo -e "    ${C_TEXT}arr request author \"Sanderson\"${S_RESET}"
    echo ""
}

TYPE="${1:-}"

case "$TYPE" in
    movie)
        shift; request_movie "${*:-}"
        ;;
    tv)
        shift; request_tv "${*:-}"
        ;;
    music)
        shift; request_music "${*:-}"
        ;;
    book)
        shift; request_book "${*:-}"
        ;;
    audiobook)
        shift; request_audiobook "${*:-}"
        ;;
    author)
        shift; request_author "${*:-}"
        ;;
    game)
        shift; request_game "${*:-}"
        ;;
    --help|-h)
        show_request_help
        ;;
    "")
        if $HAS_GUM; then
            choice=$(gum choose --header "  What would you like to request?" \
                "Movie       — Search & add movies" \
                "TV Show     — Search & add TV series" \
                "Music       — Search & add artists" \
                "Book        — Search & add books" \
                "Audiobook   — Search & add audiobooks" \
                "Author      — Add an author (all works)" \
                "Game        — Search & add games") || { msg_dim "Cancelled."; exit 0; }

            case "$choice" in
                Movie*)       request_movie ;;
                TV*)          request_tv ;;
                Music*)       request_music ;;
                Book*)        request_book ;;
                Audiobook*)   request_audiobook ;;
                Author*)      request_author ;;
                Game*)        request_game ;;
            esac
        else
            show_request_help
        fi
        ;;
    *)
        msg_error "Unknown type: $TYPE"
        show_request_help
        exit 1
        ;;
esac
