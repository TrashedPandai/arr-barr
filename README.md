# Arr Media Automation Stack

Automated media server — movies, TV, music, books, and audiobooks in Docker.

Everything runs in Docker containers, all download traffic is routed through a VPN for privacy, and you manage it all from simple web interfaces in your browser.

---

## What's Inside

| Service | What It Does | Port | Profile |
|---|---|---|---|
| **Gluetun** | VPN tunnel — keeps all download traffic private | — | Core |
| **Transmission** | Downloads torrents sent by the arr apps | 9091 | Core |
| **SABnzbd** | Downloads from Usenet (a different download source) | 8080 | Core |
| **Prowlarr** | Manages search sites and shares them with all arr apps | 9696 | Core |
| **FlareSolverr** | Helps Prowlarr access sites with bot protection | 8191 | Core |
| **Radarr** | Finds, downloads, and organizes movies | 7878 | Core |
| **Sonarr** | Finds, downloads, and organizes TV shows | 8989 | Core |
| **Bazarr** | Automatically finds subtitles for your movies and shows | 6767 | Core |
| **Jellyfin** | Stream your media on any device (like a personal Netflix) | 8096 | Core |
| **Seerr** | Lets anyone request movies and shows from a friendly page | 5055 | Core |
| **Lidarr** | Finds, downloads, and organizes music | 8686 | Core |
| **QuestArr** | Game library management and tracking | 5002 | Core |
| **LazyLibrarian** | Finds and downloads ebooks (like Radarr but for books) | 5299 | `lazylibrarian` |
| **Kavita** | Read your ebooks in the browser (like a personal Kindle) | 5004 | `kavita` |
| **Audiobookshelf** | Listen to audiobooks with progress tracking | 13378 | `audiobookshelf` |

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/TrashedPandai/arr-barr.git arr-barr
cd arr-barr
```

### 2. Run setup

```bash
.cli/setup.sh
```

The setup script will:
- Install the `arr` command so you can run `arr status`, `arr update`, etc. from anywhere
- Create your `.env` configuration file
- Prompt you to fill in your VPN details
- Create all the directories the stack needs
- Pull all the Docker images
- Optionally start everything for you

### 3. Day-to-day usage

```bash
arr status    # Check the health of all services
arr update    # Pull latest images and restart changed containers
arr help      # Show all available commands
```

---

## Staying Up to Date

When the stack is updated (new container versions, config changes, etc.), all you need to do is:

```bash
cd arr-barr
git pull
arr update
```

That's it. The update command pulls the latest Docker images and restarts only the containers that changed. Your data and settings are never touched.

---

## Services & Ports

Once the stack is running, open these URLs in your browser (replace `your-server` with your server's IP address or hostname):

| Service | URL | What You'll Use It For |
|---|---|---|
| **Jellyfin** | `http://your-server:8096` | Watch movies and TV shows |
| **Seerr** | `http://your-server:5055` | Request new movies and shows |
| **Radarr** | `http://your-server:7878` | Manage your movie library |
| **Sonarr** | `http://your-server:8989` | Manage your TV show library |
| **Bazarr** | `http://your-server:6767` | Manage subtitles |
| **Prowlarr** | `http://your-server:9696` | Manage search indexers |
| **Transmission** | `http://your-server:9091` | Monitor torrent downloads |
| **SABnzbd** | `http://your-server:8080` | Monitor Usenet downloads |
| **FlareSolverr** | `http://your-server:8191` | Bot protection bypass (no UI to configure) |
| **Lidarr** | `http://your-server:8686` | Manage your music library |
| **QuestArr** | `http://your-server:5002` | Track your game library |
| **LazyLibrarian** | `http://your-server:5299` | Search and download ebooks |
| **Kavita** | `http://your-server:5004` | Read your ebooks |
| **Audiobookshelf** | `http://your-server:13378` | Listen to audiobooks |

---

## Choosing What to Install

Not everyone needs every service. The stack uses **Docker Compose profiles** to let you pick what you want.

The **core services** always run — these give you movies, TV shows, music, games, and subtitles:
- Gluetun, Transmission, SABnzbd, Prowlarr, FlareSolverr
- Radarr, Sonarr, Lidarr, Bazarr
- Jellyfin, Seerr, QuestArr

The **optional services** each have their own profile you can enable or disable independently:

| Profile | Service | What It Adds |
|---|---|---|
| `lazylibrarian` | LazyLibrarian | Ebook search and download |
| `kavita` | Kavita | Ebook reader in the browser |
| `audiobookshelf` | Audiobookshelf | Audiobook server with progress tracking |

### How to enable or disable profiles

Open your `.env` file and find the `COMPOSE_PROFILES` line:

```ini
# Enable everything:
COMPOSE_PROFILES=lazylibrarian,kavita,audiobookshelf

# Only books (search + reader):
COMPOSE_PROFILES=lazylibrarian,kavita

# Only the core stack (movies, TV, music, games, subtitles):
COMPOSE_PROFILES=
```

After changing profiles, apply with:

```bash
arr update
```

---

## Directory Structure

All your data lives under the `DATA_ROOT` path you set in `.env`. Here's what each folder is for:

```
DATA_ROOT/
├── config/                       # Service configuration files
│   ├── audiobookshelf/           #   (each service stores its database
│   ├── audiobookshelf-meta/      #    and settings in its own folder —
│   ├── bazarr/                   #    these are created automatically
│   ├── jellyfin/                 #    on first run)
│   ├── jellyfin-cache/
│   ├── kavita/
│   ├── lazylibrarian/
│   ├── lidarr/
│   ├── prowlarr/
│   ├── questarr/
│   ├── radarr/
│   ├── sabnzbd/
│   ├── seerr/
│   ├── sonarr/
│   └── transmission/
├── downloads/                    # Temporary staging area for active downloads
└── media/                        # Your organized media library
    ├── audiobooks/               #   Audiobooks (used by Audiobookshelf)
    ├── books/                    #   Ebooks (used by Kavita)
    ├── games/                    #   Games (used by QuestArr)
    ├── movies/                   #   Movies (used by Radarr + Jellyfin)
    ├── music/                    #   Music (used by Lidarr)
    └── tv/                       #   TV shows (used by Sonarr + Jellyfin)
```

The `config/` folder contains service configs and databases. These are created automatically when each container starts for the first time. The `media/` folder is where your finished, organized content lives — this is what Jellyfin reads from.

---

## Troubleshooting

### "Permission denied" errors

The containers run as the user/group specified by `PUID` and `PGID` in your `.env` file. Make sure your data directories are owned by that user:

```bash
# Replace 1000:1000 with your PUID:PGID if different
chown -R 1000:1000 /your/DATA_ROOT
```

### Jellyfin shows a blank page

Clear your browser cookies and cache for the Jellyfin URL, then reload the page.

### VPN not connecting

Check the Gluetun logs for error messages:

```bash
docker compose logs gluetun
```

Common causes:
- Wrong WireGuard private key or public key in `.env`
- VPN server endpoint IP or port is incorrect
- Your VPN subscription has expired

### Seerr is in a crash loop

Seerr runs as UID 1000 internally (it ignores PUID/PGID). Fix the permissions:

```bash
chown -R 1000:1000 /your/DATA_ROOT/config/seerr
docker compose restart seerr
```

### A container won't start

Check its logs for the specific error:

```bash
docker compose logs <service-name>

# For example:
docker compose logs radarr
docker compose logs sonarr
```

### Downloads aren't working

First, make sure the VPN is connected and healthy:

```bash
docker compose logs gluetun | tail -20
```

Look for a line that says the VPN is connected. If the VPN is down, Transmission and SABnzbd won't be able to reach the internet (this is by design — it prevents accidental unprotected downloads).

### Transmission/SABnzbd web UI not loading

These run inside the VPN container. If Gluetun is down or restarting, their web UIs will be unreachable. Fix Gluetun first, and they'll come back automatically.

---

## How It All Fits Together

Here's the big picture of how media flows through the stack:

1. **You request something** — either by adding it directly in Radarr/Sonarr/Lidarr, or by using Seerr's friendly request page.

2. **The arr app searches for it** — Prowlarr manages your search indexers (torrent and Usenet sites) and shares them with all the arr apps, so you only configure indexers once.

3. **It gets downloaded privately** — The arr app sends the download to Transmission (torrents) or SABnzbd (Usenet). Both of these run inside Gluetun's VPN tunnel, so all download traffic is encrypted and routed through your VPN provider.

4. **It gets organized automatically** — Once the download finishes, the arr app moves and renames the file into your media library with clean, consistent naming (e.g., `Movies/The Matrix (1999)/The Matrix (1999).mkv`).

5. **Bazarr grabs subtitles** — For movies and TV shows, Bazarr automatically searches for and downloads subtitles in your preferred languages.

6. **You watch it** — Jellyfin picks up the new file and makes it available to stream on any device — your TV, phone, tablet, or browser.

```
  Seerr (requests)
       |
       v
  Radarr / Sonarr / Lidarr / LazyLibrarian
       |                        ^
       v                        | (organizes files)
  Prowlarr (indexers) -----> Download Clients
                             (Transmission / SABnzbd)
                                    |
                              [VPN Tunnel via Gluetun]
                                    |
                                 Internet

  Organized Media Library --> Jellyfin --> Your Devices
                         --> Kavita --> Your Browser (books)
                         --> Audiobookshelf --> Your Phone (audiobooks)
```
