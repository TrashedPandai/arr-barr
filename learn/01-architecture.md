# arr-barr Architecture

A self-hosted, automated media server stack that searches, downloads, organizes, and streams movies, TV, music, books, audiobooks, and games — with full VPN protection on all download traffic.

## The Big Picture

```mermaid
graph TB
    subgraph REQUEST["Request Layer"]
        USER["Users / Friends"]
        SEERR["Jellyseerr<br/>Request Interface"]
    end

    subgraph SEARCH["Search Layer"]
        PROWLARR["Prowlarr<br/>Indexer Manager"]
        FLARESOLVERR["FlareSolverr<br/>Cloudflare Bypass"]
    end

    subgraph MANAGE["Management Layer"]
        RADARR["Radarr<br/>Movies"]
        SONARR["Sonarr<br/>TV Shows"]
        LIDARR["Lidarr<br/>Music"]
        LAZYLIB["LazyLibrarian<br/>Books & Audiobooks"]
        QUESTARR["QuestArr<br/>Games"]
        BAZARR["Bazarr<br/>Subtitles"]
    end

    subgraph VPN["VPN Tunnel — All Traffic Encrypted"]
        direction LR
        GLUETUN["Gluetun<br/>WireGuard VPN"]
        TRANSMISSION["Transmission<br/>Torrents"]
        SABNZBD["SABnzbd<br/>Usenet"]
    end

    subgraph STREAM["Streaming Layer"]
        JELLYFIN["Jellyfin<br/>Movies, TV, Music"]
        KAVITA["Kavita<br/>Ebook Reader"]
        ABS["Audiobookshelf<br/>Audiobooks"]
    end

    USER --> SEERR
    SEERR --> RADARR & SONARR

    RADARR & SONARR & LIDARR --> PROWLARR
    QUESTARR --> PROWLARR
    PROWLARR --> FLARESOLVERR

    RADARR & SONARR & LIDARR & LAZYLIB & QUESTARR --> TRANSMISSION & SABNZBD
    GLUETUN --- TRANSMISSION & SABNZBD

    BAZARR -.->|subtitles| RADARR & SONARR

    TRANSMISSION & SABNZBD -->|"organize"| JELLYFIN & KAVITA & ABS

    USER --> JELLYFIN & KAVITA & ABS

    style VPN fill:#f38ba8,color:#1e1e2e
    style STREAM fill:#a6e3a1,color:#1e1e2e
```

## 15 Services at a Glance

| # | Service | Port | Role | Always On? |
|---|---------|------|------|:---:|
| 1 | **Gluetun** | — | WireGuard VPN tunnel with kill switch | Yes |
| 2 | **Transmission** | 9091 | Torrent download client (inside VPN) | Yes |
| 3 | **SABnzbd** | 8080 | Usenet download client (inside VPN) | Yes |
| 4 | **Prowlarr** | 9696 | Manages all indexers, syncs to arr apps | Yes |
| 5 | **FlareSolverr** | 8191 | Bypasses Cloudflare protection for indexers | Yes |
| 6 | **Radarr** | 7878 | Movie search, download, organize | Yes |
| 7 | **Sonarr** | 8989 | TV show search, download, organize | Yes |
| 8 | **Lidarr** | 8686 | Music search, download, organize | Yes |
| 9 | **Bazarr** | 6767 | Automatic subtitle downloads | Yes |
| 10 | **Jellyfin** | 8096 | Media server (self-hosted Netflix) | Yes |
| 11 | **Jellyseerr** | 5055 | User-friendly request interface | Yes |
| 12 | **QuestArr** | 5002 | Game search and download | Yes |
| 13 | **LazyLibrarian** | 5299 | Book & audiobook search/download | Optional |
| 14 | **Kavita** | 5004 | Browser-based ebook reader | Optional |
| 15 | **Audiobookshelf** | 13378 | Audiobook server with progress tracking | Optional |

## Three Network Zones

```mermaid
graph TB
    subgraph ZONE1["Zone 1: VPN Tunnel"]
        direction LR
        GL["Gluetun"]
        TX["Transmission"]
        SB["SABnzbd"]
        GL --- TX
        GL --- SB
    end

    subgraph ZONE2["Zone 2: Docker Bridge"]
        PW["Prowlarr"] & FS["FlareSolverr"]
        RD["Radarr"] & SN["Sonarr"] & LD["Lidarr"]
        BZ["Bazarr"] & SR["Seerr"] & QA["QuestArr"]
        LL["LazyLibrarian"] & KV["Kavita"] & AB["Audiobookshelf"]
    end

    subgraph ZONE3["Zone 3: Host Network"]
        JF["Jellyfin"]
    end

    ZONE2 -->|"gluetun:9091<br/>gluetun:8080"| ZONE1
    ZONE3 -->|"localhost ports"| ZONE2

    style ZONE1 fill:#f38ba8,color:#1e1e2e
    style ZONE2 fill:#89b4fa,color:#1e1e2e
    style ZONE3 fill:#a6e3a1,color:#1e1e2e
```

**Zone 1 — VPN Tunnel:** Transmission and SABnzbd share Gluetun's network namespace. They have no independent network access — all traffic exits through the encrypted WireGuard tunnel. If the VPN drops, the kill switch blocks everything.

**Zone 2 — Docker Bridge:** All management apps live on a private bridge network. They communicate by container name (e.g., `radarr:7878`). Search traffic goes directly to the internet (no VPN needed for searching).

**Zone 3 — Host Network:** Jellyfin runs directly on the host for maximum streaming performance and DLNA support.

## Dependency Chain

```mermaid
graph TD
    GL["Gluetun<br/>Must be healthy first"] -->|"condition: service_healthy"| TX["Transmission"]
    GL -->|"condition: service_healthy"| SB["SABnzbd"]

    NOTE["All other 12 services<br/>start independently<br/>(no depends_on)"]

    style GL fill:#a6e3a1,color:#1e1e2e
    style NOTE fill:#f9e2af,color:#1e1e2e
```

Only one hard dependency: download clients wait for the VPN to be healthy. Everything else starts in parallel and retries connections on its own.

## Optional Service Profiles

Books/audiobook services are profile-gated. Enabling any reader automatically enables LazyLibrarian (the acquisition engine).

| `COMPOSE_PROFILES=` | LazyLibrarian | Kavita | Audiobookshelf |
|---------------------|:---:|:---:|:---:|
| _(empty)_ | OFF | OFF | OFF |
| `kavita` | ON | ON | — |
| `audiobookshelf` | ON | — | ON |
| `kavita,audiobookshelf` | ON | ON | ON |

## Hardlink Architecture (TRaSH Guides)

The key to zero-waste storage: every service that touches both downloads and media mounts the **same root directory**. This keeps everything on one filesystem, enabling hardlinks.

```mermaid
graph LR
    subgraph SINGLE["Single Mount: DATA_ROOT → /data"]
        DL["/data/downloads/torrents/movie.mkv<br/>inode #3899"]
        MEDIA["/data/media/movies/Movie (2024)/movie.mkv<br/>inode #3899"]
    end

    DL ===|"HARDLINK<br/>Same inode<br/>Zero extra disk space<br/>Torrent keeps seeding"| MEDIA

    style SINGLE fill:#a6e3a1,color:#1e1e2e
```

**Why this matters:** A 50GB movie file doesn't get copied — it gets a second filename pointing to the same data blocks. The torrent client keeps seeding from the original path while Jellyfin streams from the library path. Zero duplication.

## Volume Mount Tiers

```mermaid
graph TD
    subgraph T1["Tier 1: Full /data (read-write)<br/>Can hardlink between downloads ↔ media"]
        TX["Transmission"] & SB["SABnzbd"]
        RD["Radarr"] & SN["Sonarr"] & LD["Lidarr"]
        BZ["Bazarr"] & LL["LazyLibrarian"]
    end

    subgraph T2["Tier 2: Media Only (read-only)<br/>Consumers — stream/display content"]
        JF["Jellyfin → /movies, /tv, /music"]
        KV["Kavita → /books"]
        AB["Audiobookshelf → /audiobooks"]
    end

    subgraph T3["Tier 3: Config Only<br/>No media access at all"]
        PW["Prowlarr"] & SR["Seerr"]
        QA["QuestArr"] & FS["FlareSolverr"]
        GL["Gluetun"]
    end

    style T1 fill:#a6e3a1,color:#1e1e2e
    style T2 fill:#89b4fa,color:#1e1e2e
    style T3 fill:#f9e2af,color:#1e1e2e
```

## Directory Tree

```
DATA_ROOT/
├── config/                    Service databases & settings (15 directories)
│   ├── radarr/               Movies DB, config
│   ├── sonarr/               TV DB, config
│   ├── lidarr/               Music DB, config
│   ├── bazarr/               Subtitle DB, config
│   ├── prowlarr/             Indexer DB
│   ├── transmission/         Torrent client settings
│   ├── sabnzbd/              Usenet client settings
│   ├── jellyfin/             Media server config
│   ├── jellyfin-cache/       Transcoding cache
│   ├── seerr/                Request DB (must be 1000:1000)
│   ├── lazylibrarian/        Book search config
│   ├── kavita/               Ebook reader config
│   ├── audiobookshelf/       Audiobook server config
│   ├── audiobookshelf-meta/  Audiobook metadata
│   └── questarr/             Game tracking DB
├── downloads/                 Staging area (temporary)
│   ├── incomplete/           In-progress downloads
│   ├── torrents/             Completed torrents (keep for seeding)
│   │   ├── radarr/          Movies
│   │   ├── tv-sonarr/       TV shows
│   │   ├── lidarr/          Music
│   │   ├── books/           Books & audiobooks
│   │   └── games/           Games
│   └── usenet/               Completed usenet (disposable staging)
│       ├── movies/
│       ├── tv/
│       ├── music/
│       ├── books/
│       ├── audiobooks/
│       └── games/
├── media/                     Organized final library
│   ├── movies/               → Jellyfin
│   ├── tv/                   → Jellyfin
│   ├── music/                → Jellyfin + Roon
│   ├── books/                → Kavita
│   ├── audiobooks/           → Audiobookshelf
│   └── games/                → GameVault
└── backups/                   Config backup archives
```
