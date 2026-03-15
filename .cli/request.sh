#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env
require_curl

DATA_ROOT="$(get_data_root)"

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
            msg_dim "  This feature is still under construction. Try again later or use the web UI."
            return 1
        }
    else
        response=$(curl -s --max-time 15 -w "\n%{http_code}" "$url" 2>/dev/null) || {
            msg_error "Could not reach service."
            msg_dim "  This feature is still under construction. Try again later or use the web UI."
            return 1
        }
    fi
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')
    if [ "$http_code" != "200" ] && [ "$http_code" != "302" ]; then
        msg_error "API returned HTTP ${http_code}"
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
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
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
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
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
        return 1
    fi
    echo "$response"
}

_search_prompt() {
    local header="$1"
    if $HAS_GUM; then
        gum input --header "  $header" --placeholder "Type a name..." --width 50 || true
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
        printf '%s\n' "${lines[@]}" | gum filter \
            --header "  $header" \
            --placeholder "Type to search..." \
            --height 15 \
            --width 80 || return 1
    else
        echo ""
        echo -e "  ${S_BOLD}${C_TEXT}${header}${S_RESET}"
        echo ""
        local i=1
        for line in "${lines[@]}"; do
            # Strip the ID prefix for display
            local display="${line#*|}"
            printf "  ${C_SAPPHIRE}%2d)${S_RESET} ${C_TEXT}%s${S_RESET}\n" "$i" "$display"
            ((i++))
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

    # Parse results into display lines: ID|Display Text
    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.tmdbId)|\(.title) (\(.year // "?")) \u2605 \(.ratings.imdb.value // .ratings.tmdb.value // "?") \u2014 \(.overview[:60] // "")..."
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

    local title year runtime genres overview in_library
    title=$(echo "$detail" | jq -r '.title')
    year=$(echo "$detail" | jq -r '.year // "?"')
    runtime=$(echo "$detail" | jq -r '.runtime // "?"')
    genres=$(echo "$detail" | jq -r '[.genres[0:3] | .[]] | join(", ")')
    overview=$(echo "$detail" | jq -r '.overview[:120] // ""')
    in_library=$(echo "$detail" | jq -r '.id // empty')

    if [ -n "$in_library" ]; then
        msg_warn "${title} (${year}) is already in your library!"
        exit 0
    fi

    # Show details and confirm
    echo ""
    echo ""
    kv_line "  Title" "$title"
    kv_line "  Year" "$year"
    kv_line "  Runtime" "${runtime} min"
    kv_line "  Genres" "$genres"
    if [ -n "$overview" ]; then
        echo ""
        printf "    ${C_OVERLAY0}%s${S_RESET}\n" "$overview"
    fi

    echo ""
    if ! gum_confirm "Add \"${title}\" to Radarr?"; then
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

    msg_success "${title} (${year}) added to Radarr! Searching for downloads..."
    echo ""
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

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.tvdbId)|\(.title) (\(.year // "?")) \u2014 \(.network // "?") \u2014 \(.seasons | length) seasons \u2605 \(.ratings.value // "?")"
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

    local title year network seasons overview in_library
    title=$(echo "$detail" | jq -r '.title')
    year=$(echo "$detail" | jq -r '.year // "?"')
    network=$(echo "$detail" | jq -r '.network // "?"')
    seasons=$(echo "$detail" | jq -r '.seasons | length')
    overview=$(echo "$detail" | jq -r '.overview[:120] // ""')
    in_library=$(echo "$detail" | jq -r '.id // empty')

    if [ -n "$in_library" ]; then
        msg_warn "${title} (${year}) is already in your library!"
        exit 0
    fi

    echo ""
    echo ""
    kv_line "  Title" "$title"
    kv_line "  Year" "$year"
    kv_line "  Network" "$network"
    kv_line "  Seasons" "$seasons"
    if [ -n "$overview" ]; then
        echo ""
        printf "    ${C_OVERLAY0}%s${S_RESET}\n" "$overview"
    fi

    echo ""
    if ! gum_confirm "Add \"${title}\" to Sonarr?"; then
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

    msg_success "${title} (${year}) added to Sonarr! Searching for episodes..."
    echo ""
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

    local lines=()
    while IFS= read -r line; do
        [ -n "$line" ] && lines+=("$line")
    done < <(echo "$json" | jq -r '
        .[0:15] | .[] |
        "\(.foreignArtistId)|\(.artistName) \u2014 \(.artistType // "?") \u2605 \(.ratings.value // "?")"
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
    overview=$(echo "$detail" | jq -r '.overview[:120] // ""')
    in_library=$(echo "$detail" | jq -r '.id // empty')

    if [ -n "$in_library" ]; then
        msg_warn "${name} is already in your library!"
        exit 0
    fi

    echo ""
    echo ""
    kv_line "  Artist" "$name"
    kv_line "  Type" "$artist_type"
    kv_line "  Genres" "$genres"
    if [ -n "$overview" ]; then
        echo ""
        printf "    ${C_OVERLAY0}%s${S_RESET}\n" "$overview"
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

    msg_success "${name} added to Lidarr! Searching for albums..."
    echo ""
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
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
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
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
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
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
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
        msg_dim "  This feature is still under construction. Try again later or use the web UI."
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
    echo -e "  ${C_SUBTEXT0}Examples:${S_RESET}"
    echo -e "    ${C_TEXT}arr request movie \"Inception\"${S_RESET}"
    echo -e "    ${C_TEXT}arr request tv \"Breaking Bad\"${S_RESET}"
    echo -e "    ${C_TEXT}arr request music \"Pink Floyd\"${S_RESET}"
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
