#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker

show_logo
show_header "Arr Media Stack  —  Setup"

TOTAL_STEPS=6

# ── Already set up? ──────────────────────────────────────────────────────────

if [ -f "$ARR_HOME/.env" ] && [ -f "$HOME/.arr-home" ]; then
    msg_success "This stack is already set up."
    echo ""
    msg_dim "If something's off, run: arr doctor"
    msg_dim "To pull updates, run:    arr update"
    echo ""
    exit 0
fi

# ── Step 1: Install the arr command ──────────────────────────────────────────

step 1 $TOTAL_STEPS "Installing arr command"

if sudo cp "$CLI_DIR/arr" /usr/local/bin/arr && sudo chmod +x /usr/local/bin/arr; then
    echo "$ARR_HOME" > "$HOME/.arr-home"
    msg_success "Installed! You can now run arr from anywhere."
else
    msg_warn "Could not install to /usr/local/bin. You can still run scripts from $CLI_DIR"
fi
echo ""

# ── Step 2: .env file ───────────────────────────────────────────────────────

step 2 $TOTAL_STEPS "Configuring environment"

echo -e "  ${C_SUBTEXT0}Creating .env from template...${S_RESET}"
cp "$ARR_HOME/.env.example" "$ARR_HOME/.env"
msg_success "Created .env"

# Auto-detect PUID/PGID
current_uid=$(id -u)
current_gid=$(id -g)
sed -i "s/^PUID=1000$/PUID=${current_uid}/" "$ARR_HOME/.env"
sed -i "s/^PGID=1000$/PGID=${current_gid}/" "$ARR_HOME/.env"
msg_dim "  PUID=${current_uid}, PGID=${current_gid}"
echo ""

# Check for placeholder VPN key
if grep -q "your_private_key_here" "$ARR_HOME/.env"; then
    msg_warn "Your .env file still has placeholder VPN credentials!"
    echo ""
    echo -e "    ${C_TEXT}You need to edit .env and fill in your VPN details.${S_RESET}"
    echo -e "    ${C_SUBTEXT0}At minimum, set these values:${S_RESET}"
    echo -e "      ${C_PEACH}WIREGUARD_PRIVATE_KEY${S_RESET}"
    echo -e "      ${C_PEACH}WIREGUARD_PUBLIC_KEY${S_RESET}"
    echo -e "      ${C_PEACH}VPN_ENDPOINT_IP${S_RESET}"
    echo -e "      ${C_PEACH}VPN_ENDPOINT_PORT${S_RESET}"
    echo ""
    echo -e "    ${C_SUBTEXT0}Open .env in a text editor:${S_RESET}"
    echo -e "      ${S_BOLD}nano $ARR_HOME/.env${S_RESET}"
    echo ""
    read -rp "  Press Enter after you've edited .env, or Ctrl+C to exit... "
    echo ""

    if grep -q "your_private_key_here" "$ARR_HOME/.env"; then
        msg_error ".env still contains placeholder values. Edit it and run arr setup again."
        exit 1
    fi
fi

# ── Step 3: Create directories ───────────────────────────────────────────────

step 3 $TOTAL_STEPS "Creating directory tree"

DATA_ROOT="$(grep '^DATA_ROOT=' "$ARR_HOME/.env" | cut -d= -f2- || true)"

if [ -z "$DATA_ROOT" ]; then
    msg_error "DATA_ROOT is not set in .env"
    exit 1
fi

# Resolve relative DATA_ROOT
case "$DATA_ROOT" in
    /*) ;;
    *)  DATA_ROOT="$(cd "$ARR_HOME" && cd "$DATA_ROOT" 2>/dev/null && pwd)" ;;
esac

# Save resolved path back
tmp="$(grep -v '^DATA_ROOT=' "$ARR_HOME/.env" || true)"
printf '%s\n' "$tmp" > "$ARR_HOME/.env"
echo "DATA_ROOT=${DATA_ROOT}" >> "$ARR_HOME/.env"

msg_dim "  Data root: $DATA_ROOT"

# Service config directories
for dir in \
    config/audiobookshelf config/audiobookshelf-meta config/bazarr \
    config/jellyfin config/jellyfin-cache config/kavita \
    config/lazylibrarian config/lidarr config/prowlarr config/questarr \
    config/radarr config/sabnzbd config/seerr config/sonarr \
    config/transmission \
    downloads \
    media/audiobooks media/books media/games media/movies media/music media/tv
do
    mkdir -p "$DATA_ROOT/$dir"
done
msg_success "Directories created"
echo ""

# ── Step 4: Config templates ────────────────────────────────────────────────

step 4 $TOTAL_STEPS "Applying config templates"

apply_template() {
    local src="$1"
    local dest="$2"
    local name
    name="$(basename "$(dirname "$dest")")"
    [ ! -f "$src" ] && return
    if [ -f "$dest" ]; then
        if ! diff -q "$src" "$dest" &>/dev/null; then
            msg_warn "$name — template updated upstream"
            msg_dim "    Review: diff $src $dest"
        fi
        return
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    msg_success "$name"
}

apply_template "$ARR_HOME/templates/bazarr/config/config.yaml" "$DATA_ROOT/config/bazarr/config/config.yaml"
apply_template "$ARR_HOME/templates/transmission/settings.json" "$DATA_ROOT/config/transmission/settings.json"
apply_template "$ARR_HOME/templates/lazylibrarian/config.ini" "$DATA_ROOT/config/lazylibrarian/config.ini"
echo ""

# ── Step 5: Seerr permissions ───────────────────────────────────────────────

step 5 $TOTAL_STEPS "Setting Seerr permissions"

chown -R 1000:1000 "$DATA_ROOT/config/seerr" 2>/dev/null && {
    msg_success "Seerr config owned by 1000:1000"
} || {
    msg_warn "Could not set Seerr permissions."
    msg_dim "  Run: sudo chown -R 1000:1000 $DATA_ROOT/config/seerr"
}
echo ""

# ── Step 6: Pull images ─────────────────────────────────────────────────────

step 6 $TOTAL_STEPS "Pulling Docker images"
echo ""
compose_cmd pull
echo ""
msg_success "Images pulled"
echo ""

# ── Optionally start ─────────────────────────────────────────────────────────

if confirm "Start the stack now?" "y"; then
    echo ""
    compose_cmd up -d > /tmp/.arr-setup-$$ 2>&1 &
    spin_while $! "Starting the stack..."
    rm -f /tmp/.arr-setup-$$
    msg_success "Stack is running!"
else
    echo ""
    msg_dim "Start the stack later with: arr start"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
divider 58
echo ""
echo -e "  $(check_pass) ${S_BOLD}${C_GREEN}Setup complete!${S_RESET}"
echo ""

section_header "SERVICE URLS" "$C_SAPPHIRE"
echo ""

printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Jellyfin"       "8096"  "Stream movies & TV"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Seerr"          "5055"  "Request content"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Radarr"         "7878"  "Movies"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Sonarr"         "8989"  "TV shows"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Lidarr"         "8686"  "Music"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Bazarr"         "6767"  "Subtitles"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Prowlarr"       "9696"  "Indexers"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Transmission"   "9091"  "Torrent downloads"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "SABnzbd"        "8080"  "Usenet downloads"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "LazyLibrarian"  "5299"  "Book search"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Kavita"         "5004"  "Book reader"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "Audiobookshelf" "13378" "Audiobooks"
printf "    ${C_TEXT}%-17s${S_RESET} ${C_OVERLAY0}:%-6s${S_RESET} ${C_SUBTEXT0}%s${S_RESET}\n" "QuestArr"       "5002"  "Games"
echo ""
msg_dim "  Replace localhost with your server's IP or hostname."
echo ""
msg_dim "  Run arr status to check the health of all services."
echo ""
