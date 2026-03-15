#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker

show_logo
show_header "Arr Media Stack  —  Setup"

TOTAL_STEPS=8

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

# ── Step 2: Install gum (interactive CLI toolkit) ────────────────────────────

step 2 $TOTAL_STEPS "Installing gum"

GUM_VERSION="0.17.0"

if command -v gum &>/dev/null || [ -x /usr/local/bin/gum ]; then
    installed_ver="$(gum --version 2>/dev/null || /usr/local/bin/gum --version 2>/dev/null || echo "unknown")"
    msg_success "gum already installed (${installed_ver})"
else
    # Detect architecture
    case "$(uname -m)" in
        x86_64|amd64)  GUM_ARCH="x86_64" ;;
        aarch64|arm64) GUM_ARCH="arm64" ;;
        *)
            msg_warn "Unsupported architecture: $(uname -m). Skipping gum install."
            msg_dim "  Interactive features will be unavailable."
            GUM_ARCH=""
            ;;
    esac

    if [ -n "${GUM_ARCH:-}" ]; then
        GUM_URL="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz"
        GUM_TMP=$(mktemp -d /tmp/gum-install-XXXXXX)

        msg_dim "  Downloading gum v${GUM_VERSION} for ${GUM_ARCH}..."

        if curl -fsSL "$GUM_URL" -o "$GUM_TMP/gum.tar.gz" 2>/dev/null; then
            tar -xzf "$GUM_TMP/gum.tar.gz" -C "$GUM_TMP" 2>/dev/null
            GUM_BIN="$(find "$GUM_TMP" -name gum -type f | head -1)"
            if [ -n "$GUM_BIN" ] && sudo cp "$GUM_BIN" /usr/local/bin/gum && sudo chmod +x /usr/local/bin/gum; then
                msg_success "gum v${GUM_VERSION} installed to /usr/local/bin/gum"
                # Re-init gum theme now that it's available
                export_gum_theme
            else
                msg_warn "Could not install gum binary. Interactive features will be unavailable."
            fi
        else
            msg_warn "Could not download gum. Interactive features will be unavailable."
            msg_dim "  You can install it manually: https://github.com/charmbracelet/gum"
        fi

        rm -rf "$GUM_TMP"
    fi
fi
echo ""

# ── Step 3: .env file ───────────────────────────────────────────────────────

step 3 $TOTAL_STEPS "Configuring environment"

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

    if $HAS_GUM; then
        gum confirm "Have you edited .env with your VPN credentials?" || {
            msg_error "Edit .env and run arr setup again."
            exit 1
        }
    else
        read -rp "  Press Enter after you've edited .env, or Ctrl+C to exit... "
    fi
    echo ""

    if grep -q "your_private_key_here" "$ARR_HOME/.env"; then
        msg_error ".env still contains placeholder values. Edit it and run arr setup again."
        exit 1
    fi
fi

# ── Step 4: Create directories ───────────────────────────────────────────────

step 4 $TOTAL_STEPS "Creating directory tree"

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

# ── Step 5: Config templates ────────────────────────────────────────────────

step 5 $TOTAL_STEPS "Applying config templates"

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

# ── Step 6: Seerr permissions ───────────────────────────────────────────────

step 6 $TOTAL_STEPS "Setting Seerr permissions"

chown -R 1000:1000 "$DATA_ROOT/config/seerr" 2>/dev/null && {
    msg_success "Seerr config owned by 1000:1000"
} || {
    msg_warn "Could not set Seerr permissions."
    msg_dim "  Run: sudo chown -R 1000:1000 $DATA_ROOT/config/seerr"
}
echo ""

# ── Step 7: GPU hardware transcoding ────────────────────────────────────────

step 7 $TOTAL_STEPS "Detecting GPU for hardware transcoding"

OVERRIDE_FILE="$ARR_HOME/compose.override.yaml"

if [ -e /dev/dri/renderD128 ]; then
    msg_success "Found GPU: /dev/dri/renderD128"

    # Detect the video group GID
    VIDEO_GID="$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo "")"
    if [ -z "$VIDEO_GID" ] || [ "$VIDEO_GID" = "0" ]; then
        VIDEO_GID="$(getent group video 2>/dev/null | cut -d: -f3 || echo "44")"
        msg_dim "  Using default video GID: $VIDEO_GID"
    else
        msg_dim "  Video device GID: $VIDEO_GID"
    fi

    if gum_confirm "Enable GPU hardware transcoding in Jellyfin?" "y"; then
        cat > "$OVERRIDE_FILE" <<GPUEOF
# Local overrides — not tracked by git
# Generated by: arr setup (GPU detection)
services:
  jellyfin:
    group_add:
      - "$VIDEO_GID"  # /dev/dri video group
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
      - /dev/dri/card0:/dev/dri/card0
GPUEOF
        msg_success "GPU transcoding enabled in compose.override.yaml"
        msg_dim "  After starting, enable QSV in Jellyfin Dashboard → Playback → Transcoding"
    else
        # Remove override if it exists from a previous setup
        rm -f "$OVERRIDE_FILE"
        msg_dim "GPU transcoding skipped. Run arr setup again to enable later."
    fi
else
    msg_dim "No GPU detected (/dev/dri/renderD128 not found)"
    msg_dim "Jellyfin will use software transcoding (CPU only)"
    # Remove any leftover GPU override
    rm -f "$OVERRIDE_FILE"
fi
echo ""

# ── Step 8: Pull images ─────────────────────────────────────────────────────

step 8 $TOTAL_STEPS "Pulling Docker images"
echo ""
compose_cmd pull
echo ""
msg_success "Images pulled"
echo ""

# ── Optionally start ─────────────────────────────────────────────────────────

if gum_confirm "Start the stack now?" "y"; then
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
