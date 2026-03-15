# CLI Design Language

The definitive style guide for the arr-barr CLI. Every script in `.cli/` follows these patterns. This document is the single source of truth for color usage, animation architecture, layout conventions, and interaction design.


---

## 1. Color System

The CLI uses the **Catppuccin Mocha** palette exclusively. All color constants are defined once in `branding.sh` as true-color (24-bit) ANSI escape sequences.

### Base & Surface Colors

| Constant | Hex | Role |
|----------|---------|------|
| `C_BASE` | `#1E1E2E` | Deepest background (rarely used in fg) |
| `C_MANTLE` | `#181825` | Even deeper background layer |
| `C_SURFACE0` | `#313244` | Progress bar empty fill, inactive backgrounds |
| `C_SURFACE1` | `#45475A` | Dividers, separators, dashed lines |
| `C_SURFACE2` | `#585B70` | Stopped/inactive indicators (dim circle) |
| `C_OVERLAY0` | `#6C7086` | Dim text, hints, secondary info, response times |
| `C_OVERLAY1` | `#7F849C` | Slightly brighter dim text |
| `C_SUBTEXT0` | `#A6ADC8` | Key labels in kv_line, context line text |
| `C_SUBTEXT1` | `#BAC2DE` | Spinner messages, secondary labels |
| `C_TEXT` | `#CDD6F4` | Primary text, service names, values |

### Accent Colors

| Constant | Hex | Primary Usage |
|----------|---------|---------------|
| `C_ROSEWATER` | `#F5E0DC` | Warm highlight, wave bar accent |
| `C_FLAMINGO` | `#F2CDCD` | Gaming group color |
| `C_PINK` | `#F5C2E7` | Wave bar accent, gum cursor |
| `C_MAUVE` | `#CBA6F7` | Streaming group, pre-flight section |
| `C_RED` | `#F38BA8` | Errors, down indicators, shutdown theme |
| `C_MAROON` | `#EBA0AC` | Shutdown wave bar accent |
| `C_PEACH` | `#FAB387` | Activity panel, downloading labels, confirmation prompt |
| `C_YELLOW` | `#F9E2AF` | Warnings, slow indicators, mixed-state headers, indexer group |
| `C_GREEN` | `#A6E3A1` | Success, healthy indicators, network group, seeding |
| `C_TEAL` | `#94E2D5` | Books group, usenet progress bars, Technologies tagline |
| `C_SKY` | `#89DCEB` | Gradient endpoint, wave bar accent |
| `C_SAPPHIRE` | `#74C7EC` | Primary accent. Headers, download bars, step counters, section bars |
| `C_BLUE` | `#89B4FA` | Media group, info indicators, gradient component |
| `C_LAVENDER` | `#B4BEFE` | Gradient endpoint, wave bar accent |

### Style Modifiers

| Constant | Effect |
|----------|--------|
| `S_BOLD` | Bold weight, used for emphasis in counts, service names, group headers |
| `S_DIM` | Dimmed text, used for initial logo state, footer hints |
| `S_ITALIC` | Italic, used sparingly for "Library is idle" type messages |
| `S_UNDERLINE` | Underline, reserved for future use |
| `S_RESET` | Clears all styles. ALWAYS terminate styled output with this |

### Background Colors

| Constant | Hex | Usage |
|----------|---------|-------|
| `BG_RED` | `#F38BA8` | Reserved for critical alerts |
| `BG_GREEN` | `#A6E3A1` | Reserved for success banners |
| `BG_YELLOW` | `#F9E2AF` | Reserved for warning banners |
| `BG_BLUE` | `#89B4FA` | Gum selected item background |
| `BG_SURFACE0` | `#313244` | Reserved for subtle background highlights |

Background colors are rarely used in terminal output. The CLI relies on foreground color + bold/dim for hierarchy rather than background fills. Background colors are primarily consumed by gum's env vars for interactive menus.

### Text Hierarchy

The color system creates a clear visual hierarchy without relying on font size:

```
Level 1 (loudest):  S_BOLD + C_TEXT        — service names, counts, titles
Level 2 (normal):   C_TEXT                  — values, descriptions
Level 3 (secondary): C_SUBTEXT0/C_SUBTEXT1 — labels, context
Level 4 (dim):      C_OVERLAY0             — hints, response times, "arr logs" suggestions
Level 5 (ghost):    C_SURFACE2             — stopped indicators
```


---

## 2. Service Groups

The 15 services are organized into 6 groups. Groups have semantic names, assigned colors, and ordered members. This mapping is defined identically in `start.sh`, `stop.sh`, `status.sh`, and `dashboard.sh`.

### Group Definitions

| Group ID | Label | Color | Members |
|----------|-------|-------|---------|
| `network` | NETWORK & DOWNLOADS | `C_GREEN` | gluetun, transmission, sabnzbd |
| `indexers` | INDEXERS | `C_YELLOW` | prowlarr, flaresolverr |
| `media` | MEDIA MANAGERS | `C_BLUE` | radarr, sonarr, lidarr, bazarr |
| `streaming` | STREAMING | `C_MAUVE` | jellyfin, seerr |
| `books` | BOOKS & AUDIO | `C_TEAL` | lazylibrarian, kavita, audiobookshelf |
| `gaming` | GAMING | `C_FLAMINGO` | questarr |

### Group Ordering

Groups always render in this fixed order: network, indexers, media, streaming, books, gaming. This matches the dependency chain: network must be up before indexers can search, indexers feed media managers, media managers feed streaming.

### Three-State Group Headers

Group headers change appearance based on the aggregate health of their member services. This is the **only** correct way to render a group header:

**ALL HEALTHY** -- every member service is running and responsive:
```
    ${GROUP_COLOR}${S_BOLD}▸ GROUP LABEL ✓${S_RESET}
```
The group's own assigned color, bold, with a space and checkmark after the label.

**MIXED** -- some members up, some down:
```
    ${C_YELLOW}${S_BOLD}▸ GROUP LABEL${S_RESET}
```
Bright yellow (not the group's own color), bold, no checkmark.

**ALL DOWN** -- every member service is unreachable:
```
    ${C_RED}${S_BOLD}▸ GROUP LABEL${S_RESET}
```
Bright red, bold, no checkmark.

**NEUTRAL** -- non-health context (e.g., ACTIVITY panel):
```
    ${GROUP_COLOR}${S_BOLD}▸ GROUP LABEL${S_RESET}
```
The group's own color, bold, no checkmark. Used when the header is not expressing health state.

### Computing Group State

```bash
compute_group_state() {
    local members="$1"
    local g_total=0 g_healthy=0
    for svc in $members; do
        # skip inactive profile services
        g_total=$((g_total + 1))
        if container_running "$svc" && api_healthy "$svc"; then
            g_healthy=$((g_healthy + 1))
        fi
    done
    if [ "$g_total" -eq 0 ]; then echo "neutral"
    elif [ "$g_healthy" -eq "$g_total" ]; then echo "healthy"
    elif [ "$g_healthy" -eq 0 ]; then echo "down"
    else echo "mixed"
    fi
}
```

This pattern must be consistent across `status.sh`, `dashboard.sh`, `start.sh`, `stop.sh`, and any future command that renders group headers.


---

## 3. Animation Architecture

### The Problem

`docker compose up -d` and `docker compose stop` are slow operations (10-30 seconds). During this time, the user needs visual feedback that something is happening. A naive approach of running compose and then updating the display creates frozen UI -- the spinner stops mid-frame while compose pulls or stops a container, and the user thinks the CLI has hung.

### The Three-Process Model

Any command that needs smooth animation during long operations uses three concurrent processes:

```
Process 1: BACKGROUND RUNNER
    Runs the actual docker compose command.
    Writes output to a log file.
    Creates a marker file when complete.
    Example: docker compose up -d >> $LOGFILE 2>&1

Process 2: BACKGROUND WATCHER
    Tails the log file for service state changes.
    Creates per-service marker files when it detects started/stopped.
    Verifies final state with docker ps after compose exits.
    Example: touch $MARKERDIR/$svc when "Started" appears in log

Process 3: FOREGROUND RENDERER (the render loop)
    Runs at 33fps (sleep 0.03).
    ONLY checks file existence -- never forks processes.
    Animates spinners and wave bars.
    Updates service lines when marker files appear.
```

### Why Three Processes

The renderer must NEVER call external commands. Every `docker`, `grep`, `wc`, or `curl` call takes 5-50ms on Synology NAS hardware. At 33fps, each frame has a 30ms budget. A single fork would cause visible stutter.

File existence checks (`[ -f "$MARKERDIR/$svc" ]`) are kernel-cached and take ~0ms. This is the ONLY cross-process communication mechanism the renderer uses.

### Marker Directory Pattern

```bash
MARKERDIR="/tmp/.arr-markers-$$"
mkdir -p "$MARKERDIR"

# Watcher creates these:
touch "$MARKERDIR/radarr"          # service started/stopped
touch "$MARKERDIR/__exit__"        # compose process finished
echo "0" > "$MARKERDIR/__exit__"   # exit code stored in file
touch "$MARKERDIR/__verified__"    # docker ps verification complete

# Renderer checks these:
[ -f "$MARKERDIR/$sname" ]         # has this service transitioned?
[ -f "$MARKERDIR/__verified__" ]   # is everything done?
```

### Cleanup

Always register a cleanup trap that restores the cursor and removes temp files:

```bash
cleanup_start() {
    printf "\033[?25h"       # show cursor
    rm -f "$LOGFILE" "$SVCLIST"
    rm -rf "$MARKERDIR"
}
trap cleanup_start EXIT
```

### When to Use This Architecture

Use the three-process model when:
- The operation takes more than 2 seconds
- You need animated spinners that must not freeze
- Multiple services transition independently during the operation

Do NOT use it for:
- Single-service start/stop (use `spin_while` instead)
- Quick data fetches (use parallel curls with `wait`)


---

## 4. Spinner Design

### Boot Spinner (start.sh)

Braille characters cycling rapidly in the service's group color. Conveys energy and activity.

```
Frames: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
Color:  GROUP_COLOR of the service's group
Speed:  One frame per render loop iteration (30ms)
```

Example line during startup:
```
    ⠹  radarr           Movies
```
The spinner character is in the group's color (blue for media). The service name and label are in dim overlay color (not yet confirmed up).

### Shutdown Spinner (stop.sh)

Pulsing dot that fades and brightens, conveying a powering-down rhythm. Distinct from the energetic braille spinner.

```
Frames: ◉ ◎ ○ ◎ ◉ ● ◉ ◎ ○ ◎
Color:  GROUP_COLOR of the service's group
Speed:  One frame per render loop iteration (30ms)
```

Example line during shutdown:
```
    ◎  radarr           Movies             shutting down
```

### Failure State

When a service fails to start or stop:
```
    ✗  radarr           Movies             failed
```
The cross and service name are in `C_RED`. The word "failed" is also in `C_RED`.

### General-Purpose Spinner (branding.sh)

For simple operations (single service start, non-animated waits), use `spin_while`:

```bash
compose_cmd start "$SERVICE" > /tmp/.arr-start-$$ 2>&1 &
spin_while $! "Starting ${SERVICE}..." "$C_SAPPHIRE"
```

This renders braille frames at 80ms intervals (slower than the 30ms animation loop, which is fine for non-parallel operations).

### Critical Rule

Spinners must be constantly animating. If a spinner ever appears frozen for more than 100ms, the user will assume the CLI has crashed. This is why the render loop must never fork external processes.


---

## 5. Wave Bar

The wave bar is a 36-character wide animated progress indicator that fills or drains as services come up or shut down. It uses Unicode block height characters that cycle through Catppuccin accent colors, creating a flowing wave effect.

### Start Wave (fills left to right)

Cool-toned colors conveying energy building up:

```
Colors: sapphire, blue, lavender, mauve, pink,
        flamingo, rosewater, yellow, green, teal, sky
Characters: ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▇ ▆ ▅ ▄ ▃ ▂
Width: 36 characters
```

The fill level corresponds to `(started_count / total) * WAVE_W`. Characters in the filled region cycle through both the color array and the height array based on position + frame offset, creating the wave motion. Unfilled region shows `▁` in `C_SURFACE0`.

A counter sits to the right: `12/15` with the started count in `S_BOLD` + `C_TEXT` and the total in `C_SUBTEXT0`.

### Stop Wave (drains right to left)

Warm-toned colors conveying energy dissipating:

```
Colors: red, maroon, peach, pink, flamingo,
        rosewater, mauve, yellow, peach, red, maroon
Characters: same height characters as start wave
```

The fill level corresponds to `(remaining_count / total) * WAVE_W`. As services stop, the bar drains from right to left. The counter shows `X/15 stopped`.

### Wave Rendering

```bash
render_wave() {
    local pct=$1 frame=$2
    local filled=$(( pct * WAVE_W / 100 ))
    printf "    "
    for (( i=0; i<WAVE_W; i++ )); do
        if [ "$i" -lt "$filled" ]; then
            local cidx=$(( (i + frame) % WAVE_NUM_COLORS ))
            local widx=$(( (i + frame * 2) % WAVE_LEN ))
            printf "\033[38;2;%sm%s" "${WAVE_COLORS[$cidx]}" "${WAVE_CHARS[$widx]}"
        else
            printf "\033[38;2;49;50;68m▁"
        fi
    done
    printf "${S_RESET}"
}
```

The `frame` variable increments each render cycle, causing the wave to animate. The offset into both color and height arrays creates the flowing effect.


---

## 6. Status Indicators

Every service's state is communicated through a single-character indicator. These indicators are consistent across all commands.

| State | Character | Color | Label | When |
|-------|-----------|-------|-------|------|
| Healthy | `●` | `C_GREEN` | `healthy` | Container running, API responds with expected code, <1000ms |
| Slow | `●` | `C_YELLOW` | `slow` | Container running, API responds correctly, but >1000ms |
| Down | `●` | `C_RED` | `down` | Container not running |
| Unreachable | `●` | `C_RED` | `unreachable` | Container running but API returns wrong code or times out |
| Pending (booting) | Braille spinner | Group color | (none) | During `arr start`, waiting for service |
| Shutting down | Pulsing dot | Group color | `shutting down` | During `arr stop`, waiting for service |
| Failed | `✗` | `C_RED` | `failed` | Service did not start/stop after compose finished |
| Stopped (static) | `○` | `C_SURFACE2` | (none) | Service confirmed stopped, no longer animating |

### Message Helpers

For general-purpose status messages (not service rows):

```bash
msg_success "Operation completed"    # ✓ in C_GREEN
msg_error   "Something went wrong"   # ✗ in C_RED
msg_warn    "Check your config"      # ! in C_YELLOW
msg_info    "FYI"                     # ● in C_BLUE
msg_dim     "Hint text"              # All in C_OVERLAY0
```

All message helpers indent with 2 spaces. The indicator character is followed by a space and the message in `C_TEXT` (except `msg_dim` which uses `C_OVERLAY0` for the entire line).


---

## 7. Typography & Layout

### Logo Usage

| Context | Logo Function | Behavior |
|---------|--------------|----------|
| Event commands (start, setup) | `show_logo` | Animated: dim reveal, rainbow sweep, typewriter tagline |
| Info commands (status, dashboard) | `show_logo_static` | Static gradient from sapphire to lavender |
| Quick commands (health) | (none) | No logo -- immediate output |
| Live TUI (downloads) | `show_logo` | Animated on entry, then alternate buffer takes over |

### Header Box

The `show_header` function creates a rounded-corner box matching the logo width (32 inner characters) with a centered gradient title:

```
         ╭────────────────────────────────╮
         │    Arr Media Stack  -  Status  │
         ╰────────────────────────────────╯
```

Border is `C_SAPPHIRE`. Title is a gradient from sky (`137;220;235`) to lavender (`180;190;254`). Used as the first element after the logo in major commands.

### Section Headers

```bash
section_header "PRE-FLIGHT" "$C_MAUVE"
```

Renders as:
```
  ┃ PRE-FLIGHT
  ┃
```

The vertical bar and subsequent blank bar line are in the accent color. The title is `S_BOLD` + `C_TEXT`. Used to introduce phases within a command (pre-flight, launch sequence, shutdown sequence).

### Key-Value Lines

```bash
kv_line "Status" "Running" "$C_SUBTEXT0" "$C_TEXT"
```

Renders as:
```
  Status           Running
```

16-character key width, key in `C_SUBTEXT0`, value in `C_TEXT`. The 2-space indent is built into the function.

### Context Lines

Used in dashboard for additional details beneath a service group:

```bash
render_context_line "Library: 450 movies  28 series  12 artists"
```

Renders as:
```
      ↳ Library: 450 movies  28 series  12 artists
```

Prefixed with `↳`, indented 6 spaces total. Arrow in `C_OVERLAY0`, text in `C_SUBTEXT0` with accent-colored numbers.

### Dividers

```bash
divider 58 "$C_SURFACE1"
```

Renders a dashed line of `─` characters in the specified color. Default width is 58, default color is `C_SURFACE1`. Used to separate major sections (e.g., before final results in start/stop).

### Indentation Rules

```
0 spaces:  Nothing. All CLI output is indented.
2 spaces:  Message helpers (msg_success, msg_error, etc.)
2 spaces:  Section headers, dividers
4 spaces:  Service rows, group headers, wave bar
6 spaces:  Context lines (↳), sub-detail like progress bars in dashboard
```

### Staggered Reveal

When rendering a list of items for the first time (not in an animation loop), add `sleep 0.02` after each line. This creates a subtle top-to-bottom cascade that makes the output feel alive:

```bash
for dl in "${DISPLAY_LINES[@]}"; do
    # render the line...
    sleep 0.02
done
```

Never use staggered reveal inside animation loops (30ms budget is for the entire frame, not per line). Staggered reveal is for initial renders only.

### Gradient Text

```bash
gradient_text "ALL SYSTEMS OPERATIONAL" 166 227 161 137 220 235
```

Applies a per-character color gradient between two RGB values. Used for victory/completion messages. Common gradients:

- **Launch success:** green (`166;227;161`) to sky (`137;220;235`)
- **Shutdown complete:** red (`243;139;168`) to mauve (`203;166;247`)
- **Static logo:** sapphire (`116;199;236`) to lavender (`180;190;254`)


---

## 8. Gum Usage Policy

[Gum](https://github.com/charmbracelet/gum) is used exclusively for interactive INPUT. It is never used for data display.

### Allowed Uses

| Component | Purpose | Example |
|-----------|---------|---------|
| `gum choose` | Menu selection | Stop action picker, service picker |
| `gum confirm` | Yes/No confirmation | "Stop all containers?" |
| `gum filter` | Fuzzy search picker | Service selection with type-to-search |
| `gum spin` | Simple operation spinner | Wrapping compose commands for single services |

### Forbidden Uses

| Component | Why Forbidden |
|-----------|---------------|
| `gum table` | Produces uniform mono-colored output. Cannot do per-field color differentiation. |
| `gum style` | Generic box rendering. Cannot match per-status colors or group-aware styling. |
| `gum format` | Loses fine-grained ANSI control. |

### The Reason

The handcrafted ANSI output is the soul of the CLI. Every service row has a status dot in a health-dependent color, a service name in text color, a label in subtext color, a port in overlay color, and a response time in yet another color. `gum table` would flatten all of this into a single foreground color. The visual personality and information density that ANSI provides is not achievable through gum's display components.

### Gum Theme

All gum env vars are set by `export_gum_theme()` in `branding.sh` to match Catppuccin Mocha. This ensures menus, confirmations, and filters feel like part of the same design system even though they use gum's rendering.

### Graceful Degradation

When gum is not installed (`$HAS_GUM = false`):
- `gum_confirm` falls back to `confirm()` (ANSI prompt with `read -r`)
- `gum_choose_service` prints available services and exits with error
- `gum_spin` falls back to `spin_while`

The CLI must be fully functional without gum. Gum is a luxury, not a dependency.


---

## 9. Menu Design

### Two-Stage Menus

Destructive operations (stop, restart) use a two-stage menu when run interactively without arguments:

**Stage 1: Action type**
```
  What to stop?
  > Stop all containers
    Stop a single service
```

**Stage 2: Target selection** (if "single service" chosen)
```
  Stop which service?
  > Never mind
    gluetun
    transmission
    ...
    Stop ALL containers
```

### Ordering Rules

- Most common/expected action goes FIRST. If you typed `arr stop`, you probably want all.
- Individual services are listed in the middle.
- "Never mind" (cancel) goes at the TOP of target pickers.
- "Do ALL" action goes at the BOTTOM as an escape hatch.

### Menu Height

Always pass `--height` to `gum choose` so that all options are visible without scrolling:

```bash
menu_height=$((svc_count + 4))
gum choose --header "  Stop which service?" --height "$menu_height" ...
```

### Cancellation

Escape and Ctrl-C gracefully cancel with `msg_dim "Cancelled."` followed by a blank line and exit 0. Never show an error on user cancellation.


---

## 10. Progress Bars

### Fractional Unicode Blocks

The `BLOCKS` array provides sub-character precision for smooth progress bars:

```bash
BLOCKS=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")
```

Each character represents 1/8th of a full block. Combined with full `█` blocks, this gives a resolution of `width * 8` discrete positions.

### smooth_bar (branding.sh)

```bash
smooth_bar <percent> <width> [filled_color] [empty_color]
```

- `percent`: 0-100 integer
- `width`: number of character cells
- `filled_color`: defaults to `C_SAPPHIRE`
- `empty_color`: defaults to `C_SURFACE0` (renders as `░`)

Used in dashboard for disk usage and download progress. The empty region uses `░` (shade character) for visual distinction from blank space.

### render_bar (downloads.sh)

The live downloads TUI uses a zero-fork bar renderer optimized for the animation loop:

```bash
render_bar <pct_x100> <fg_color>
```

- `pct_x100`: 0-10000 integer (100ths of a percent for sub-percent precision)
- Width fixed at `BAR_WIDTH` (30)
- Empty region uses spaces (not `░`) for cleaner look in the alternate buffer
- Returns result in `$REPLY` variable (no subshell fork)

### Bar Cache

The downloads TUI pre-builds arrays of full-block strings and space-padding strings at startup:

```bash
BAR_FULL[0]=""
BAR_FULL[1]="█"
BAR_FULL[2]="██"
...
BAR_FULL[30]="██████████████████████████████"
```

This avoids building strings character-by-character in the render loop. The renderer just indexes into the array.

### Color by Context

| Context | Bar Color |
|---------|-----------|
| Torrent downloads | `C_SAPPHIRE` |
| Usenet downloads | `C_TEAL` |
| Disk usage | `C_SAPPHIRE` |
| Stopped torrents | `C_OVERLAY0` |
| Wave bar (start) | Multi-color cycling (cool tones) |
| Wave bar (stop) | Multi-color cycling (warm tones) |


---

## 11. Data Display (Dashboard)

The dashboard (`arr dashboard`) is the flagship display command. It fetches data from all service APIs in parallel and renders a comprehensive overview.

### System Bar

A single glanceable line at the top with critical vitals:

```
  ● VPN: Connected (US)  |  Disk: ████░░░░░░ 42% (2.1T free)  |  Docker: 15/15 up
```

Segments are separated by `│` in `C_SURFACE1`. Each segment has its own status coloring:
- VPN: green dot if connected, red if down
- Disk: `smooth_bar` with percentage and free space
- Docker: green count if all up, yellow if some down

### Context Lines

Additional detail beneath each group, prefixed with `↳`:

```
      ↳ ▼ 2.4 MB/s  ▲ 156 KB/s  |  Active: 3 torrents, 1 usenet
      ↳ Library: 450 movies  28 series  12 artists  |  Queue: 3
      ↳ 14/18 indexers active
      ↳ Jellyfin v10.9.11  |  Subs needed: 5 episodes, 2 movies
```

Numbers within context lines use accent colors (`C_TEXT` or `C_PEACH`/`C_YELLOW` for attention) while labels stay in `C_SUBTEXT0`.

### Activity Panel

The activity panel uses the neutral header style (peach color, no checkmark) and shows three types of items:

```
▼  Downloading item name                        (C_PEACH arrow)
      ████████████░░░░░░░░  65%   2.1 GB   ETA 23m

▲  Seeding item name                             (C_GREEN arrow)
                                    ratio 1.4   seeding

◆  Recently imported item                        (C_SAPPHIRE diamond)
                                    2h ago       Radarr
```

### Parallel Data Fetch

All API calls launch as background subshells writing to temp files in a `mktemp -d` directory. A single `wait` collects all results before rendering begins. Target: all data fetched and parsed within 3 seconds.

```bash
TMPDIR=$(mktemp -d /tmp/arr-dash-XXXXXX)
( curl ... > "$TMPDIR/radarr_movies" ) &
( curl ... > "$TMPDIR/sonarr_series" ) &
wait
```

### Graceful Degradation

If an API fails, show what you can. A missing Radarr response shows `?` for movie count rather than crashing. Every data read is guarded:

```bash
radarr_movies=$(cat "$TMPDIR/radarr_movies" 2>/dev/null || echo "?")
```


---

## 12. Error & Warning States

### Message Helpers

| Function | Indicator | Color | Usage |
|----------|-----------|-------|-------|
| `msg_success` | `✓` | `C_GREEN` | Operation completed successfully |
| `msg_error` | `✗` | `C_RED` | Operation failed, invalid input |
| `msg_warn` | `!` | `C_YELLOW` | Non-fatal issue, placeholder credentials |
| `msg_info` | `●` | `C_BLUE` | Informational, FYI |
| `msg_dim` | (none) | `C_OVERLAY0` | Hints, suggestions, secondary info |

### Check Marks (doctor.sh, setup.sh)

| Function | Character | Color | Usage |
|----------|-----------|-------|-------|
| `check_pass` | `✓` | `C_GREEN` | Check passed |
| `check_fail` | `✗` | `C_RED` | Check failed |
| `check_warn` | `!` | `C_YELLOW` | Check passed with warning |
| `check_skip` | `○` | `C_OVERLAY0` | Check skipped |

### Warning Boxes

For important warnings that need visual prominence (e.g., VPN placeholder credentials):

```bash
msg_warn "VPN credentials are still placeholder -- gluetun may fail"
```

### Troubleshooting Hints

When services are down, list each with its log command:

```bash
msg_dim "    arr logs radarr"
msg_dim "    arr logs sonarr"
```

This gives the user an immediate next step.


---

## 13. Performance Rules

### Animation Loops (33fps)

```
Budget per frame:  30ms (sleep 0.03)
External commands: ZERO in render loop
File checks:       [ -f ] only (kernel-cached, ~0ms)
String building:   printf to variable, single flush per frame
```

The foreground renderer in start.sh and stop.sh must never call `docker`, `grep`, `wc`, `awk`, `curl`, `jq`, or any other external command. These all fork a new process, which takes 5-50ms on Synology NAS hardware and causes visible frame drops.

### API Calls

```
Strategy:  Always parallel, never sequential
Timeout:   --connect-timeout 2 --max-time 3
Pattern:   Background subshells writing to temp files, single wait
```

### Downloads TUI (100ms frame budget)

The live downloads monitor runs at 10fps (100ms per frame) rather than 33fps because it also needs one `date` fork per frame for interpolation timing. The larger frame budget accommodates this.

```
Fetch interval:  5 seconds (background subshell)
Interpolation:   Ease-out quadratic between fetches
Bar rendering:   Pre-cached arrays, zero forks
Key handling:    read -s -n1 -t 0.1 (doubles as frame timer)
```

### Staggered Reveals

```
Per-line delay:  20ms (sleep 0.02)
Usage:           Initial renders only, never in animation loops
Purpose:         Creates cascade effect for visual polish
```

### Target Performance

| Command | Target |
|---------|--------|
| `arr status` | Under 2 seconds |
| `arr dashboard` | Under 3 seconds |
| `arr health` | Under 2 seconds |
| `arr start` (all) | As fast as docker compose, no added latency |
| `arr stop` (all) | As fast as docker compose, no added latency |
| `arr downloads` | First frame within 3 seconds, then live |

### Use awk Instead of bc

`bc` is not always installed on Synology NAS. All arithmetic that needs floating point uses `awk`:

```bash
# Good
printf "%.1f GB" "$(awk "BEGIN {printf \"%.1f\", $bytes / 1073741824}")"

# Bad
echo "scale=1; $bytes / 1073741824" | bc
```

### Use [ -f ] Instead of ls or stat

For file existence checks in hot paths:

```bash
# Good (kernel-cached, ~0ms)
[ -f "$MARKERDIR/$svc" ]

# Bad (forks a process, 5-50ms)
ls "$MARKERDIR/$svc" 2>/dev/null
stat "$MARKERDIR/$svc" 2>/dev/null
```


---

## Appendix: File Reference

| File | Role |
|------|------|
| `.cli/branding.sh` | All color constants, gradient_text, section_header, divider, status indicators, spinners, progress bars, logo, show_header, gum theme |
| `.cli/common.sh` | Sources branding.sh, SERVICES array, detect_docker, compose_cmd, require_env, human formatters, kv_line, confirm, gum wrappers, message helpers |
| `.cli/start.sh` | Full-stack launch with three-process animation, boot spinners, start wave bar |
| `.cli/stop.sh` | Full-stack shutdown with three-process animation, shutdown spinners, drain wave bar |
| `.cli/status.sh` | Quick health check with parallel API probes, three-state group headers |
| `.cli/dashboard.sh` | Flagship display with parallel data fetch, system bar, context lines, activity panel |
| `.cli/downloads.sh` | Live TUI with background fetch, interpolation, bar cache, alternate buffer |
