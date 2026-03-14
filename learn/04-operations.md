# Operations & CLI

## The `arr` CLI

A custom command-line interface with 12 commands, Catppuccin Mocha theming, animated ASCII logos, and real-time dashboards.

### Command Map

```mermaid
graph TD
    USER["arr <command>"] --> DISPATCH{Dispatcher}

    DISPATCH --> |"setup"| SETUP["First-time setup wizard<br/>(6 steps)"]
    DISPATCH --> |"status / st"| STATUS["Container health dashboard"]
    DISPATCH --> |"update / up"| UPDATE["Git pull + Docker pull + restart"]
    DISPATCH --> |"doctor / doc"| DOCTOR["6-check diagnostic with auto-fix"]
    DISPATCH --> |"downloads / dl"| DL["Live download dashboard<br/>(real-time TUI)"]
    DISPATCH --> |"vpn"| VPN["VPN tunnel status + geolocation"]
    DISPATCH --> |"health / hp"| HEALTH["15 parallel API health checks"]
    DISPATCH --> |"logs / log"| LOGS["Service log viewer"]
    DISPATCH --> |"restart"| RESTART["Smart restart (VPN-aware)"]
    DISPATCH --> |"start"| START["Start services"]
    DISPATCH --> |"stop"| STOP["Stop services"]
    DISPATCH --> |"backup / bk"| BACKUP["Config backup/list/prune"]
    DISPATCH --> |"help"| HELP["Animated logo + command list"]
```

### Quick Reference

| Command | What It Does |
|---------|-------------|
| `arr setup` | Full first-time initialization (install, env, dirs, templates, pull images) |
| `arr status` | Show all containers with up/down status, profiles, troubleshooting hints |
| `arr update` | Pull latest code + Docker images, restart changed containers |
| `arr doctor` | Diagnose and auto-fix: binary, env vars, VPN creds, dirs, templates, perms |
| `arr downloads` | Live TUI dashboard with Transmission + SABnzbd progress bars and speeds |
| `arr downloads --once` | Single snapshot (no live refresh) |
| `arr vpn` | Check VPN tunnel, show public IP and geolocation |
| `arr health` | Hit all 15 service endpoints in parallel, show response times |
| `arr logs sonarr` | Last 100 lines of a service's logs |
| `arr logs sonarr -f` | Follow logs live |
| `arr restart vpn` | Restart Gluetun → wait 10s → restart download clients |
| `arr restart downloads` | Restart Transmission + SABnzbd |
| `arr backup` | Create timestamped tar.gz of all service configs |
| `arr backup --list` | List existing backups with sizes |
| `arr backup --prune 5` | Keep only 5 most recent backups |

### Script Architecture

```mermaid
graph TD
    BRAND["branding.sh<br/>━━━━━━━━━━━━━━━<br/>Catppuccin Mocha palette (30 colors)<br/>Logo animation (4 phases)<br/>Gradient text renderer<br/>Spinners (Braille + dots)<br/>Progress bars (fractional blocks)<br/>Box drawing / section headers<br/>Status dots and check marks"]

    COMMON["common.sh<br/>━━━━━━━━━━━━━━━<br/>Docker detection (4-tier fallback)<br/>SERVICES array (15 entries)<br/>compose_cmd() wrapper<br/>Environment guards<br/>jq polyfill (Python3 fallback)<br/>Human-readable formatters<br/>Confirm prompts / step counter"]

    BRAND --> COMMON
    COMMON --> SCRIPTS["All 12 command scripts"]

    style BRAND fill:#cba6f7,color:#1e1e2e
    style COMMON fill:#89b4fa,color:#1e1e2e
```

Every script sources `common.sh` (which chains to `branding.sh`), giving all commands consistent theming and utilities. All scripts use `set -euo pipefail`.

## Setup Flow

```mermaid
graph TD
    S1["1. Install CLI<br/>Copy to /usr/local/bin/arr<br/>Create ~/.arr-home marker"] --> S2

    S2["2. Configure Environment<br/>Copy .env.example → .env<br/>Auto-detect PUID/PGID<br/>Prompt for VPN credentials"] --> S3

    S3["3. Create Directory Tree<br/>20 directories: config/, downloads/, media/<br/>All subdirectories for every service"] --> S4

    S4["4. Apply Config Templates<br/>Transmission settings<br/>LazyLibrarian config<br/>Bazarr config (if available)"] --> S5

    S5["5. Fix Permissions<br/>Seerr config dir → 1000:1000<br/>(Jellyseerr hardcoded UID)"] --> S6

    S6["6. Pull Docker Images<br/>docker compose pull<br/>(all 15 services)"] --> Q

    Q{Start now?}
    Q -->|"Yes"| UP["docker compose up -d"]
    Q -->|"No"| DONE["Ready"]

    style S1 fill:#89b4fa,color:#1e1e2e
    style S6 fill:#a6e3a1,color:#1e1e2e
```

**Idempotent:** If already set up, exits immediately.

## Doctor Self-Repair

```mermaid
graph TD
    C1["1. arr Binary<br/>Compare installed vs source"] -->|"Differs"| F1["Auto-update"]
    C2["2. .env Variables<br/>Check for missing keys"] -->|"Missing"| F2["Append from template"]
    C3["3. VPN Credentials<br/>Check for placeholders"] -->|"Found"| W3["Warning"]
    C4["4. Directory Tree<br/>Check 20 directories"] -->|"Missing"| F4["Auto-create"]
    C5["5. Config Templates<br/>Check 3 templates deployed"] -->|"Missing"| F5["Auto-copy"]
    C6["6. Seerr Permissions<br/>Check ownership"] -->|"Wrong"| F6["Auto-chown"]

    style F1 fill:#a6e3a1,color:#1e1e2e
    style F2 fill:#a6e3a1,color:#1e1e2e
    style W3 fill:#f9e2af,color:#1e1e2e
    style F4 fill:#a6e3a1,color:#1e1e2e
    style F5 fill:#a6e3a1,color:#1e1e2e
    style F6 fill:#a6e3a1,color:#1e1e2e
```

## Downloads Dashboard

The most complex CLI component — a real-time terminal UI:

```mermaid
graph TD
    subgraph BACKGROUND["Background Fetcher"]
        F1["Transmission RPC<br/>session stats + torrent list"]
        F2["SABnzbd API<br/>queue + history"]
    end

    F1 & F2 -->|"4 parallel curls<br/>serialize via declare -p"| MAIN

    MAIN["Main Loop<br/>100ms poll cycle<br/>Alt screen buffer"] --> INTERP["Ease-out interpolation<br/>between data points"]
    INTERP --> RENDER["Render frame:<br/>Speed gauges<br/>Progress bars (fractional Unicode)<br/>ETAs / ratios / status"]

    RENDER --> KB["Keyboard: q=quit, r=refresh"]

    style BACKGROUND fill:#89b4fa,color:#1e1e2e
    style MAIN fill:#a6e3a1,color:#1e1e2e
```

**Display limits:** 5 downloading torrents, 5 seeding, 5 SABnzbd active, 3 queued, 3 history.

## Health Check Endpoints

All 15 services are checked in parallel with 2-second timeouts:

| Service | Endpoint | Expected |
|---------|----------|----------|
| Gluetun | /v1/openvpn/status | 302 |
| Transmission | /transmission/rpc | 409 |
| SABnzbd | /api?mode=version | 200 |
| Prowlarr | /ping | 200 |
| FlareSolverr | /health | 200 |
| Radarr | /ping | 200 |
| Sonarr | /ping | 200 |
| Lidarr | /ping | 200 |
| Bazarr | /ping | 200 |
| Jellyfin | /System/Info/Public | 200 |
| Seerr | /api/v1/status | 200 |
| LazyLibrarian | /api?cmd=getVersion | 200 |
| Kavita | /api/health | 200 |
| Audiobookshelf | /healthcheck | 200 |
| QuestArr | / | 200 |

Color-coded: green (healthy), yellow (>1000ms), red (wrong code or timeout).

## Update Pipeline

```mermaid
sequenceDiagram
    actor User
    participant CLI as arr update
    participant GIT as Git
    participant DC as Docker Compose

    User->>CLI: arr update
    CLI->>CLI: Confirm prompt

    CLI->>GIT: git pull --ff-only
    Note over GIT: Updates compose.yaml,<br/>CLI scripts, templates<br/>(NOT .env or config/)

    CLI->>DC: docker compose pull
    Note over DC: Pulls latest images

    CLI->>DC: docker compose up -d
    Note over DC: Recreates only<br/>changed containers
```

### What Gets Updated

| Component | Updated? | How |
|-----------|:---:|-----|
| compose.yaml | Yes | git pull |
| CLI scripts | Yes | git pull |
| Templates | Yes | git pull (NOT auto-deployed) |
| .env | No | gitignored, personal |
| Service configs/DBs | No | gitignored, runtime |
| Docker images | Yes | docker compose pull |
| /usr/local/bin/arr | No | Only via `arr doctor` |

## Onboarding (Friends)

```mermaid
graph LR
    CLONE["1. Clone repo"] --> SETUP["2. arr setup"]
    SETUP --> CONFIGURE["3. Edit .env<br/>(VPN creds)"]
    CONFIGURE --> START["4. arr start"]
    START --> BROWSE["5. Open Seerr<br/>Start requesting!"]

    style CLONE fill:#89b4fa,color:#1e1e2e
    style BROWSE fill:#a6e3a1,color:#1e1e2e
```

Friends update with `arr update` — pulls latest code and Docker images in one command.

## Agent Ecosystem

The stack is managed by 16+ specialized Claude Code agents:

```mermaid
graph TB
    MAIN["Orchestrator"]

    subgraph INFRA["Infrastructure"]
        C1["arr-compose"] & C2["arr-paths"] & C3["arr-vpn"]
        C4["arr-repo"] & C5["arr-cli"] & C6["arr-troubleshoot"]
    end

    subgraph MEDIA["Media Pipelines"]
        M1["arr-movies"] & M2["arr-tv"] & M3["arr-music"]
        M4["arr-books"] & M5["arr-games"] & M6["arr-subtitles"]
        M7["arr-quality"]
    end

    subgraph SERVICES["Services"]
        S1["arr-jellyfin"] & S2["arr-indexers"] & S3["arr-downloads"]
    end

    subgraph SYSTEM["System"]
        Y1["athena (NAS)"] & Y2["zeus (Mac)"]
    end

    MAIN --> INFRA & MEDIA & SERVICES & SYSTEM
```

Each agent has:
- **Domain expertise** — deep knowledge of its specific area
- **Tool access** — Bash, Read, Write, Edit, Glob, Grep (some have WebFetch)
- **NAS access** — SSH to Athena for live verification
- **Autonomous operation** — given a task, investigates and fixes independently
- **Parallel execution** — multiple agents can run simultaneously

Agents communicate through the orchestrator (not directly with each other) and update persistent memory files for cross-conversation continuity.

## Branding

- **Theme:** Catppuccin Mocha (24-bit true color throughout)
- **Logo:** Pandai Technologies ASCII art with 4-phase rainbow animation
- **Progress bars:** Fractional Unicode blocks (▏▎▍▌▋▊▉█) for smooth percentages
- **Spinners:** Braille animation (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) at 80ms intervals
- **Gradients:** Per-character RGB interpolation via awk
- **Tab completion:** Bash completion for all commands, services, and flags
