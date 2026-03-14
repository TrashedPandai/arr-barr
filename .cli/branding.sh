#!/usr/bin/env bash
# Pandai Technologies — shared branding & theme
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/branding.sh"

# ── Catppuccin Mocha Palette (true-color) ─────────────────────────────────────

# Base colors
C_BASE='\033[38;2;30;30;46m'       # #1E1E2E
C_MANTLE='\033[38;2;24;24;37m'     # #181825
C_SURFACE0='\033[38;2;49;50;68m'   # #313244
C_SURFACE1='\033[38;2;69;71;90m'   # #45475A
C_SURFACE2='\033[38;2;88;91;112m'  # #585B70
C_OVERLAY0='\033[38;2;108;112;134m' # #6C7086
C_OVERLAY1='\033[38;2;127;132;156m' # #7F849C
C_SUBTEXT0='\033[38;2;166;173;200m' # #A6ADC8
C_SUBTEXT1='\033[38;2;186;194;222m' # #BAC2DE
C_TEXT='\033[38;2;205;214;244m'    # #CDD6F4

# Accent colors
C_ROSEWATER='\033[38;2;245;224;220m' # #F5E0DC
C_FLAMINGO='\033[38;2;242;205;205m'  # #F2CDCD
C_PINK='\033[38;2;245;194;231m'      # #F5C2E7
C_MAUVE='\033[38;2;203;166;247m'     # #CBA6F7
C_RED='\033[38;2;243;139;168m'       # #F38BA8
C_MAROON='\033[38;2;235;160;172m'    # #EBA0AC
C_PEACH='\033[38;2;250;179;135m'     # #FAB387
C_YELLOW='\033[38;2;249;226;175m'    # #F9E2AF
C_GREEN='\033[38;2;166;227;161m'     # #A6E3A1
C_TEAL='\033[38;2;148;226;213m'      # #94E2D5
C_SKY='\033[38;2;137;220;235m'       # #89DCEB
C_SAPPHIRE='\033[38;2;116;199;236m'  # #74C7EC
C_BLUE='\033[38;2;137;180;250m'      # #89B4FA
C_LAVENDER='\033[38;2;180;190;254m'  # #B4BEFE

# Style modifiers
S_BOLD='\033[1m'
S_DIM='\033[2m'
S_ITALIC='\033[3m'
S_UNDERLINE='\033[4m'
S_RESET='\033[0m'

# Background variants
BG_RED='\033[48;2;243;139;168m'
BG_GREEN='\033[48;2;166;227;161m'
BG_YELLOW='\033[48;2;249;226;175m'
BG_BLUE='\033[48;2;137;180;250m'
BG_SURFACE0='\033[48;2;49;50;68m'

# Legacy color aliases (backward compat for any scripts using old names)
RED="$C_RED"
GREEN="$C_GREEN"
YELLOW="$C_YELLOW"
BLUE="$C_BLUE"
CYAN="$C_TEAL"
MAGENTA="$C_MAUVE"
DIM="$S_DIM"
BOLD="$S_BOLD"
NC="$S_RESET"

# ── Gradient & Color Functions ────────────────────────────────────────────────

# Print text with a horizontal gradient between two RGB colors
# FAST version: single awk call per line instead of per-character
# Usage: gradient_text "text" R1 G1 B1 R2 G2 B2
gradient_text() {
    local text="$1"
    local r1=$2 g1=$3 b1=$4 r2=$5 g2=$6 b2=$7
    local len=${#text}
    [ "$len" -eq 0 ] && return
    # Pass text via ENVIRON to avoid awk -v escape processing on backslashes
    TEXT_INPUT="$text" awk -v r1="$r1" -v g1="$g1" -v b1="$b1" \
        -v r2="$r2" -v g2="$g2" -v b2="$b2" \
        'BEGIN {
        text = ENVIRON["TEXT_INPUT"]
        len = length(text)
        for (i=0; i<len; i++) {
            c = substr(text, i+1, 1)
            if (c == " ") { printf " "; continue }
            ratio = (len > 1) ? i / (len-1) : 0
            r = int(r1 + (r2-r1) * ratio)
            g = int(g1 + (g2-g1) * ratio)
            b = int(b1 + (b2-b1) * ratio)
            printf "\033[38;2;%d;%d;%dm%s", r, g, b, c
        }
        printf "\033[0m"
    }'
}

# ── Box Drawing ───────────────────────────────────────────────────────────────

# Section header with accent color left bar
# Usage: section_header "SECTION NAME" [color_var]
section_header() {
    local title="$1"
    local color="${2:-$C_SAPPHIRE}"
    echo -e "  ${color}┃${S_RESET} ${S_BOLD}${C_TEXT}${title}${S_RESET}"
    echo -e "  ${color}┃${S_RESET}"
}

# Accent divider
# Usage: divider [width] [color_var]
divider() {
    local width=${1:-58}
    local color="${2:-$C_SURFACE1}"
    printf "  ${color}"
    printf '─%.0s' $(seq 1 $width)
    printf "${S_RESET}\n"
}

# ── Status Indicators ─────────────────────────────────────────────────────────

dot_up() { echo -e "${C_GREEN}●${S_RESET}"; }
dot_down() { echo -e "${C_RED}●${S_RESET}"; }
dot_warn() { echo -e "${C_YELLOW}●${S_RESET}"; }
dot_info() { echo -e "${C_BLUE}●${S_RESET}"; }

check_pass() { echo -e "${C_GREEN}✓${S_RESET}"; }
check_fail() { echo -e "${C_RED}✗${S_RESET}"; }
check_warn() { echo -e "${C_YELLOW}!${S_RESET}"; }
check_skip() { echo -e "${C_OVERLAY0}○${S_RESET}"; }

# ── Spinners ──────────────────────────────────────────────────────────────────

BRAILLE_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
DOT_FRAMES=("⠁" "⠂" "⠄" "⡀" "⢀" "⠠" "⠐" "⠈")

# Run a spinner while a background process runs
# Usage: spin_while <pid> "message" [color_var]
spin_while() {
    local pid=$1
    local msg="$2"
    local color="${3:-$C_SAPPHIRE}"
    local frames=("${BRAILLE_FRAMES[@]}")
    local i=0
    printf "\033[?25l"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${color}${frames[$i]}${S_RESET} ${C_SUBTEXT1}${msg}${S_RESET}\033[K"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done
    printf "\r\033[K"
    printf "\033[?25h"
    wait "$pid" 2>/dev/null
    return $?
}

# Inline spinner for quick operations (non-blocking visual)
_SPIN_PID=""
spin_start() {
    local msg="$1"
    local color="${2:-$C_SAPPHIRE}"
    (
        local frames=("${BRAILLE_FRAMES[@]}")
        local i=0
        printf "\033[?25l"
        while true; do
            printf "\r  ${color}${frames[$i]}${S_RESET} ${C_SUBTEXT1}${msg}${S_RESET}\033[K"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &
    _SPIN_PID=$!
}

spin_stop() {
    local msg="${1:-}"
    if [ -n "$_SPIN_PID" ]; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
        _SPIN_PID=""
    fi
    printf "\r\033[K\033[?25h"
    if [ -n "$msg" ]; then
        echo -e "  ${C_GREEN}✓${S_RESET} ${C_TEXT}${msg}${S_RESET}"
    fi
}

# ── Progress Bars ─────────────────────────────────────────────────────────────

BLOCKS=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")

# Smooth progress bar with fractional Unicode blocks
# Usage: smooth_bar <percent> <width> [filled_color] [empty_color]
smooth_bar() {
    local pct=${1:-0}
    local width=${2:-28}
    local fg="${3:-$C_SAPPHIRE}"
    local bg="${4:-$C_SURFACE0}"

    [ "$pct" -gt 100 ] && pct=100
    [ "$pct" -lt 0 ] && pct=0

    local total_eighths=$(( pct * width * 8 / 100 ))
    local full_blocks=$(( total_eighths / 8 ))
    local remainder=$(( total_eighths % 8 ))
    local empty=$(( width - full_blocks - (remainder > 0 ? 1 : 0) ))

    printf "${fg}"
    for (( i=0; i<full_blocks; i++ )); do
        printf "█"
    done
    if [ "$remainder" -gt 0 ]; then
        printf "%s" "${BLOCKS[$remainder]}"
    fi
    printf "${bg}"
    for (( i=0; i<empty; i++ )); do
        printf "░"
    done
    printf "${S_RESET}"
}

# ── Logo ──────────────────────────────────────────────────────────────────────

# Logo width constants (display columns)
LOGO_PREFIX="         "
LOGO_INNER_W=32   # Inner width of the box (matches tagline content width)

show_logo() {
    local lines=(
        "          ____                 _       _"
        "         |  _ \\ __ _ _ __   __| | __ _(_)"
        "         | |_) / _\` | '_ \\ / _\` |/ _\` | |"
        "         |  __/ (_| | | | | (_| | (_| | |"
        "         |_|   \\__,_|_| |_|\\__,_|\\__,_|_|"
    )
    local tag_text="──── T E C H N O L O G I E S ───"
    local prefix="$LOGO_PREFIX"
    local cursor="▌"

    local rainbow=(
        '\033[0;31m'
        '\033[0;33m'
        '\033[1;33m'
        '\033[0;32m'
        '\033[0;36m'
        '\033[0;34m'
        '\033[0;35m'
    )
    local num_colors=${#rainbow[@]}

    printf "\033[?25l"
    echo ""

    # Phase 1: Pandai appears dim, line by line
    for line in "${lines[@]}"; do
        echo -e "${S_DIM}${line}${S_RESET}"
        sleep 0.04
    done
    sleep 0.05

    # Phase 2: Pandai sweeps top-down — rainbow then cyan
    printf "\033[5A"
    for line in "${lines[@]}"; do
        for color in "${rainbow[@]}"; do
            printf "\r\033[K${color}%s${S_RESET}" "${line}"
            sleep 0.004
        done
        printf "\r\033[K"
        echo -e "\033[0;36m${line}\033[0m"
    done
    sleep 0.05

    # Phase 3: Typewriter tagline with rainbow cursor
    printf "${prefix}"
    for (( i=0; i<${#tag_text}; i++ )); do
        local color_idx=$(( i % num_colors ))
        printf "${S_DIM}%s${rainbow[$color_idx]}%s${S_RESET}" "${tag_text:$i:1}" "${cursor}"
        printf "\b"
        sleep 0.01
    done
    printf " \b"
    sleep 0.05

    # Phase 4: Tagline rainbow flash then settle
    for color in "${rainbow[@]}"; do
        printf "\r\033[K${prefix}${color}%s${S_RESET}" "${tag_text}"
        sleep 0.008
    done

    # Settle on cyan
    printf "\r\033[K"
    echo -e "${prefix}\033[0;36m${tag_text}\033[0m"
    echo ""

    printf "\033[?25h"
}

# Non-animated variant
show_logo_static() {
    echo ""
    gradient_text "          ____                 _       _" 116 199 236 180 190 254; echo ""
    gradient_text "         |  _ \\ __ _ _ __   __| | __ _(_)" 116 199 236 180 190 254; echo ""
    gradient_text "         | |_) / _\` | '_ \\ / _\` |/ _\` | |" 116 199 236 180 190 254; echo ""
    gradient_text "         |  __/ (_| | | | | (_| | (_| | |" 116 199 236 180 190 254; echo ""
    gradient_text "         |_|   \\__,_|_| |_|\\__,_|\\__,_|_|" 116 199 236 180 190 254; echo ""
    echo -e "         ${C_TEAL}──── T E C H N O L O G I E S ───${S_RESET}"
    echo ""
}

# ── Styled Header ─────────────────────────────────────────────────────────────

# Main header: rounded box matching logo width with centered gradient title
# Usage: show_header "Title"
show_header() {
    local title="$1"
    local prefix="$LOGO_PREFIX"
    local inner=$LOGO_INNER_W

    # Build top border
    printf "${prefix}${C_SAPPHIRE}╭"
    printf '─%.0s' $(seq 1 $inner)
    printf "╮${S_RESET}\n"

    # Center the title
    local title_len=${#title}
    local total_pad=$((inner - title_len))
    local pad_left=$(( total_pad / 2 ))
    local pad_right=$(( total_pad - pad_left ))

    printf "${prefix}${C_SAPPHIRE}│${S_RESET}"
    printf '%*s' "$pad_left" ""
    gradient_text "$title" 137 220 235 180 190 254
    printf '%*s' "$pad_right" ""
    printf "${C_SAPPHIRE}│${S_RESET}\n"

    # Build bottom border
    printf "${prefix}${C_SAPPHIRE}╰"
    printf '─%.0s' $(seq 1 $inner)
    printf "╯${S_RESET}\n"
    echo ""
}
