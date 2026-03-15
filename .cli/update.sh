#!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
detect_docker
require_env

show_logo
show_header "Arr Media Stack  —  Update"

msg_warn "This will pull updates and restart changed containers."
echo ""
if ! gum_confirm "Continue?" "y"; then
    msg_dim "Cancelled."
    echo ""
    exit 0
fi
echo ""

# Pull latest repo changes
if command -v git &>/dev/null && [ -d "$ARR_HOME/.git" ]; then
    git -C "$ARR_HOME" pull --ff-only > /tmp/.arr-update-$$ 2>&1 &
    if $HAS_GUM; then
        gum spin --spinner dot --title "  Pulling latest changes from git..." -- wait $!
    else
        spin_while $! "Pulling latest changes from git..."
    fi

    git_result="$(cat /tmp/.arr-update-$$ 2>/dev/null)" || git_result=""
    if echo "$git_result" | grep -q "Already up to date"; then
        msg_dim "Already up to date"
    else
        msg_success "Repository updated"
    fi
    rm -f /tmp/.arr-update-$$
    echo ""
fi

echo -e "  ${C_SAPPHIRE}Pulling latest Docker images...${S_RESET}"
echo ""
compose_cmd pull
echo ""

compose_cmd up -d > /tmp/.arr-update-$$ 2>&1 &
if $HAS_GUM; then
    gum spin --spinner dot --title "  Restarting changed containers..." -- wait $!
else
    spin_while $! "Restarting changed containers..."
fi
rm -f /tmp/.arr-update-$$

echo ""
msg_success "Updated! Use ${S_BOLD}arr status${S_RESET}${C_TEXT} to check health."
echo ""
