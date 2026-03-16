<div align="center">

# arr-barr

### Self-hosted media management and automation.
### Movies, TV, music, books, audiobooks, and games.

[🌐 arrbarr.com](https://arrbarr.com) · [Get Started](#-get-started) · [How It Works](#-how-it-works) · [Docs](https://arrbarr.com/docs)

---

**One command sets up 15 services.** Add a movie, and minutes later it's streaming on your TV — organized with perfect names and artwork, subtitles included. Repeat for TV shows, music, books, audiobooks, and games.

**New here?** Visit **[arrbarr.com](https://arrbarr.com)** for visual guides, an interactive architecture tour, and a step-by-step walkthrough designed for non-technical users.

</div>

## What You Get

| | What | How |
|:---:|---|---|
| 🎬 | **Movies & TV** | Add anything. It searches 12 indexers, picks the best quality, and appears in Jellyfin ready to stream. |
| 🎵 | **Music** | Full albums in lossless quality, organized by artist. Stream through Jellyfin or your favorite music app. |
| 📖 | **Books & Audiobooks** | Ebooks managed by Kavita (read in your browser). Audiobooks in Audiobookshelf (with chapter support and progress sync). |
| 🎮 | **Games** | Search and manage PC games. Auto-imported to your library every 15 minutes. |
| 🔒 | **VPN Privacy** | All traffic routed through an encrypted WireGuard tunnel. Kill switch prevents unprotected connections. |
| 🤖 | **Fully Automated** | Quality scoring picks the best release from dozens of options. Upgrades happen automatically when something better appears. Zero manual work. |

## 🚀 Get Started

> **First time?** Read the full walkthrough at **[arrbarr.com/guide](https://arrbarr.com/guide)** — it covers prerequisites, VPN setup, and your first request with screenshots and explanations.

```bash
# Clone
git clone https://github.com/TrashedPandai/arr-barr.git
cd arr-barr

# Setup (creates everything, installs the CLI, pulls images)
arr setup

# Launch
arr start
```

That's it. The setup wizard walks you through VPN configuration, creates all directories, and pulls every container. First launch takes a few minutes for image downloads, then you're live.

**After setup, open these in your browser:**

| What | URL | For |
|---|---|---|
| 🎬 **Jellyfin** | `http://your-server:8096` | Watch movies, TV, listen to music |
| 🔍 **Seerr** | `http://your-server:5055` | Request new media |

That's all most people need. The other 13 services work behind the scenes.

## ⚡ The `arr` CLI

Every operation is one command:

```bash
arr dashboard     # Live dashboard — library counts, downloads, disk, health
arr status        # Quick pulse — are all 15 services alive?
arr downloads     # Live download monitor with progress bars
arr vpn           # VPN tunnel status and public IP
arr request       # Search & add content from the terminal
arr start         # Launch the stack (animated sequence)
arr stop          # Shut it down (visual shutdown sequence)
arr update        # Pull latest code + images
arr backup        # Snapshot all configs
arr doctor        # Diagnose and auto-fix common issues
arr logs <svc>    # View service logs
arr help          # Full command reference
```

The CLI features animated launch/shutdown sequences, color-coded service groups, live progress bars, and a 33fps render loop for buttery-smooth terminal animations.

## 🔧 How It Works

```
  You request "Dune"
       │
       ▼
  Jellyseerr ──▶ Radarr ──▶ Prowlarr (searches 12 indexers)
                    │
                    ▼
              Best release scored (48 custom formats)
                    │
                    ▼
          ┌─── VPN Tunnel (WireGuard) ───┐
          │  Transmission  ·  SABnzbd    │
          │  Kill switch · Network privacy │
          └──────────────────────────────┘
                    │
                    ▼
         Hardlinked to library (0 extra disk space)
         Renamed · Artwork fetched · Subtitles queued
                    │
                    ▼
           Jellyfin ──▶ Ready to watch
```

**Key architecture decisions:**
- **Single mount** (`/data`) — downloads and media on the same filesystem so hardlinks work. A 50GB movie uses 50GB total, not 100GB.
- **Split networking** — download traffic goes through VPN, streaming stays fast on the local network.
- **Quality scoring** — 48 custom formats in Radarr, 44 in Sonarr (from TRaSH Guides). Every release is scored and ranked automatically.

> Deep dive into the architecture at **[arrbarr.com/docs](https://arrbarr.com/docs)** — interactive network topology, hardlink diagrams, quality pipeline, and more.

## 📦 The 15 Services

<details>
<summary><strong>🟢 Network & Downloads</strong></summary>

| Service | Role |
|---|---|
| **Gluetun** | WireGuard VPN tunnel with kill switch |
| **Transmission** | Torrent client (runs inside VPN) |
| **SABnzbd** | Usenet client (runs inside VPN) |

</details>

<details>
<summary><strong>🟡 Indexers</strong></summary>

| Service | Role |
|---|---|
| **Prowlarr** | Manages 12 indexers (8 torrent + 4 usenet), syncs to all arr apps |
| **FlareSolverr** | Cloudflare bypass for protected indexer sites |

</details>

<details>
<summary><strong>🔵 Media Managers</strong></summary>

| Service | Role |
|---|---|
| **Radarr** | Movies — search, organize, upgrade |
| **Sonarr** | TV shows — seasons, episodes, anime |
| **Lidarr** | Music — albums, artists, lossless preferred |
| **Bazarr** | Subtitles — automatic matching, timing sync |

</details>

<details>
<summary><strong>🟣 Streaming</strong></summary>

| Service | Role |
|---|---|
| **Jellyfin** | Media server — stream to any device, hardware transcoding |
| **Jellyseerr** | Request interface — friends search and request here |

</details>

<details>
<summary><strong>🔷 Books & Audio</strong> (optional profiles)</summary>

| Service | Role |
|---|---|
| **LazyLibrarian** | Book & audiobook library management |
| **Kavita** | Ebook reader in the browser |
| **Audiobookshelf** | Audiobook server with chapters, bookmarks, mobile apps |

</details>

<details>
<summary><strong>🩷 Gaming</strong></summary>

| Service | Role |
|---|---|
| **QuestArr** | Game library management via Prowlarr indexers |

</details>

> Meet every service visually at **[arrbarr.com/crew](https://arrbarr.com/crew)**

## 🔄 Staying Updated

```bash
arr update
```

Pulls latest code and Docker images, restarts only changed containers. Your media, configs, and settings are never touched.

## 📂 Directory Structure

```
DATA_ROOT/
├── config/          15 service databases & settings (auto-created)
├── downloads/
│   ├── torrents/    Completed torrents (keep for seeding)
│   ├── usenet/      Completed usenet (staging, disposable)
│   └── incomplete/  Active transfers
└── media/           Your organized library
    ├── movies/      → Jellyfin
    ├── tv/          → Jellyfin
    ├── music/       → Jellyfin
    ├── books/       → Kavita
    ├── audiobooks/  → Audiobookshelf
    └── games/       → GameVault
```

## 🛟 Troubleshooting

```bash
arr doctor          # Auto-diagnose and fix common issues
arr logs <service>  # Check a specific service's logs
arr vpn             # Verify VPN is connected
```

| Problem | Fix |
|---|---|
| Downloads not starting | `arr vpn` — if tunnel is down, kill switch blocks traffic (by design). Check `.env` VPN credentials. |
| Permission denied | Check `PUID`/`PGID` in `.env` matches your file ownership. `arr doctor` can auto-fix. |
| Jellyfin can't play file | Enable hardware transcoding in Jellyfin → Dashboard → Playback → Transcoding. |
| Seerr crash loop | `chown -R 1000:1000 $DATA_ROOT/config/seerr` (Seerr runs as UID 1000 internally). |

## 📚 Learn More

| Resource | What's there |
|---|---|
| **[arrbarr.com](https://arrbarr.com)** | Visual homepage, animated terminal demo |
| **[The Guide](https://arrbarr.com/guide)** | Step-by-step setup for non-technical users |
| **[The Crew](https://arrbarr.com/crew)** | Visual roster of all 15 services |
| **[Costs](https://arrbarr.com/costs)** | Hardware and running cost breakdown |
| **[Docs](https://arrbarr.com/docs)** | Technical reference, quality scoring, CLI guide |
| **[learn/](./learn/)** | In-repo architecture docs with Mermaid diagrams |

## ⚖️ Legal

Every tool in this stack is 100% legal, open-source software designed for managing and automating personal media libraries. Users are responsible for ensuring their use complies with applicable laws in their jurisdiction. The VPN provides network privacy as a standard security practice.

---

<div align="center">

**arr-barr** · [Pandai Technologies](https://arrbarr.com)

*Every crew needs a port.*

</div>
