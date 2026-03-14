#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker

show_logo
show_header "Arr Media Stack  —  Doctor"

require_env
DATA_ROOT="$(get_data_root)"

issues=0
fixes=0
total_checks=6
current_check=0

run_check() {
    current_check=$((current_check + 1))
    local title="$1"
    echo ""
    printf "  ${C_SAPPHIRE}[%d/%d]${S_RESET} ${S_BOLD}${C_TEXT}%s${S_RESET}\n" "$current_check" "$total_checks" "$title"
}

# ── Check 1: arr command ─────────────────────────────────────────────────────

run_check "arr command"

if [ -f /usr/local/bin/arr ]; then
    if ! diff -q "$CLI_DIR/arr" /usr/local/bin/arr &>/dev/null; then
        check_warn; echo -e " ${C_YELLOW}arr command is outdated${S_RESET}"
        if sudo cp "$CLI_DIR/arr" /usr/local/bin/arr && sudo chmod +x /usr/local/bin/arr; then
            msg_success "Updated"
            ((fixes++))
        else
            msg_error "Could not update — run: sudo cp $CLI_DIR/arr /usr/local/bin/arr"
            ((issues++))
        fi
    else
        msg_success "Up to date"
    fi
else
    check_warn; echo -e " ${C_YELLOW}Not installed${S_RESET}"
    if sudo cp "$CLI_DIR/arr" /usr/local/bin/arr && sudo chmod +x /usr/local/bin/arr; then
        echo "$ARR_HOME" > "$HOME/.arr-home"
        msg_success "Installed"
        ((fixes++))
    else
        msg_error "Could not install — run: sudo cp $CLI_DIR/arr /usr/local/bin/arr"
        ((issues++))
    fi
fi

# ── Check 2: .env variables ─────────────────────────────────────────────────

run_check ".env variables"

new_vars=0
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    var_name="${line%%=*}"
    if ! grep -q "^${var_name}=" "$ARR_HOME/.env" 2>/dev/null; then
        echo "$line" >> "$ARR_HOME/.env"
        echo -e "    $(check_pass) Added missing: ${S_BOLD}${var_name}${S_RESET}"
        ((new_vars++))
        ((fixes++))
    fi
done < "$ARR_HOME/.env.example"
if [ "$new_vars" -eq 0 ]; then
    msg_success "All variables present"
fi

# ── Check 3: VPN credentials ────────────────────────────────────────────────

run_check "VPN credentials"

if grep -q "your_private_key_here" "$ARR_HOME/.env"; then
    msg_error "VPN credentials are still placeholders — edit .env"
    ((issues++))
else
    msg_success "VPN credentials set"
fi

# ── Check 4: Directory tree ─────────────────────────────────────────────────

run_check "Directory tree"

missing_dirs=0
for dir in \
    "$DATA_ROOT/config/audiobookshelf" \
    "$DATA_ROOT/config/bazarr" \
    "$DATA_ROOT/config/jellyfin" \
    "$DATA_ROOT/config/kavita" \
    "$DATA_ROOT/config/lazylibrarian" \
    "$DATA_ROOT/config/lidarr" \
    "$DATA_ROOT/config/prowlarr" \
    "$DATA_ROOT/config/questarr" \
    "$DATA_ROOT/config/radarr" \
    "$DATA_ROOT/config/sabnzbd" \
    "$DATA_ROOT/config/seerr" \
    "$DATA_ROOT/config/sonarr" \
    "$DATA_ROOT/config/transmission" \
    "$DATA_ROOT/downloads" \
    "$DATA_ROOT/media/audiobooks" \
    "$DATA_ROOT/media/books" \
    "$DATA_ROOT/media/games" \
    "$DATA_ROOT/media/movies" \
    "$DATA_ROOT/media/music" \
    "$DATA_ROOT/media/tv"
do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo -e "    $(check_pass) Created ${C_SUBTEXT0}$(echo "$dir" | sed "s|$DATA_ROOT/||")${S_RESET}"
        ((missing_dirs++))
        ((fixes++))
    fi
done
if [ "$missing_dirs" -eq 0 ]; then
    msg_success "All directories exist"
fi

# ── Check 5: Config templates ───────────────────────────────────────────────

run_check "Config templates"

check_template() {
    local src="$1"
    local dest="$2"
    local name
    name="$(basename "$(dirname "$dest")")"
    [ ! -f "$src" ] && return
    if [ ! -f "$dest" ]; then
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo -e "    $(check_pass) Copied template for ${C_TEXT}$name${S_RESET}"
        ((fixes++))
    elif ! diff -q "$src" "$dest" &>/dev/null; then
        echo -e "    $(check_warn) ${C_YELLOW}$name${S_RESET} — template has upstream changes"
        msg_dim "      Review: diff $src $dest"
        ((issues++))
    else
        echo -e "    $(check_pass) ${C_TEXT}$name${S_RESET}"
    fi
}

check_template "$ARR_HOME/templates/bazarr/config/config.yaml" "$DATA_ROOT/config/bazarr/config/config.yaml"
check_template "$ARR_HOME/templates/transmission/settings.json" "$DATA_ROOT/config/transmission/settings.json"
check_template "$ARR_HOME/templates/lazylibrarian/config.ini" "$DATA_ROOT/config/lazylibrarian/config.ini"

# ── Check 6: Seerr permissions ──────────────────────────────────────────────

run_check "Seerr permissions"

if [ -d "$DATA_ROOT/config/seerr" ]; then
    seerr_owner=$(stat -c '%u:%g' "$DATA_ROOT/config/seerr" 2>/dev/null || stat -f '%u:%g' "$DATA_ROOT/config/seerr" 2>/dev/null || echo "unknown")
    if [ "$seerr_owner" = "1000:1000" ]; then
        msg_success "Owned by 1000:1000"
    else
        echo -e "    $(check_warn) ${C_YELLOW}Owned by $seerr_owner (should be 1000:1000)${S_RESET}"
        chown -R 1000:1000 "$DATA_ROOT/config/seerr" 2>/dev/null && {
            msg_success "Fixed"
            ((fixes++))
        } || {
            msg_error "Could not fix — run: sudo chown -R 1000:1000 $DATA_ROOT/config/seerr"
            ((issues++))
        }
    fi
else
    msg_dim "    Seerr config dir doesn't exist yet (created on first start)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
divider 58
echo ""

if [ "$issues" -eq 0 ] && [ "$fixes" -eq 0 ]; then
    echo -e "  $(check_pass) ${S_BOLD}${C_GREEN}Everything looks healthy!${S_RESET}"
elif [ "$issues" -eq 0 ]; then
    echo -e "  $(check_pass) ${S_BOLD}${C_GREEN}All good!${S_RESET} ${C_SUBTEXT0}Fixed $fixes thing(s) along the way.${S_RESET}"
else
    echo -e "  $(check_warn) ${S_BOLD}${C_YELLOW}$issues issue(s) need attention.${S_RESET} ${C_SUBTEXT0}Fixed $fixes thing(s) automatically.${S_RESET}"
fi
echo ""
