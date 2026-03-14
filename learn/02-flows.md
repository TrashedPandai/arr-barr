# How It All Works

The complete journey from "I want to watch something" to "it's streaming on my TV."

## The Main Flow: Request → Search → Download → Organize → Stream

```mermaid
sequenceDiagram
    actor User
    participant Seerr as Jellyseerr
    participant Arr as Arr App<br/>(Radarr / Sonarr)
    participant Prowlarr as Prowlarr
    participant FS as FlareSolverr
    participant Indexer as Indexer Sites
    participant VPN as Gluetun VPN
    participant DL as Download Client
    participant Library as Media Library
    participant Jellyfin as Jellyfin

    User->>Seerr: "I want The Matrix"
    Seerr->>Arr: Add to wanted list

    Note over Arr,Indexer: SEARCH PHASE

    Arr->>Prowlarr: Search all indexers
    Prowlarr->>FS: Cloudflare-protected site?
    FS->>Indexer: Headless browser bypass
    Indexer-->>Prowlarr: Results from 12 indexers

    Note over Arr: DECISION PHASE
    Arr->>Arr: Score results with<br/>Custom Formats<br/>Pick highest score

    Note over VPN,DL: DOWNLOAD PHASE (VPN protected)

    alt Torrent selected
        Arr->>DL: Send to Transmission
        DL->>VPN: Download through tunnel
        VPN-->>DL: Complete
        DL-->>Arr: 100% done
        Arr->>Library: HARDLINK<br/>(zero extra disk space)
        Note over DL: Continues seeding
    else Usenet selected
        Arr->>DL: Send to SABnzbd
        DL->>VPN: Download through tunnel
        VPN-->>DL: Complete + extract
        DL-->>Arr: Completed
        Arr->>Library: MOVE<br/>(staging cleared)
    end

    Note over Library,Jellyfin: STREAMING PHASE

    Library-->>Jellyfin: New file detected
    Jellyfin-->>User: Ready to watch
```

## VPN Kill Switch: What Happens When the Tunnel Drops

```mermaid
sequenceDiagram
    participant DL as Download Client
    participant FW as Firewall (iptables)
    participant VPN as VPN Tunnel
    participant Internet as Internet

    Note over VPN: Tunnel drops unexpectedly

    DL->>FW: Try to download
    FW->>FW: Check rules:<br/>1. VPN tunnel? DOWN<br/>2. Docker internal? NO<br/>3. VPN handshake? NO
    FW--xDL: BLOCKED (kill switch)

    Note over DL: Zero traffic leaks<br/>Real IP never exposed

    Note over FW: Auto-restart enabled
    FW->>VPN: Re-establish tunnel
    VPN->>Internet: Connected

    DL->>FW: Try again
    FW->>VPN: Route through tunnel
    VPN->>Internet: Download resumes
```

The kill switch uses iptables with a default DROP policy. Only three types of outbound traffic are allowed:
1. Traffic through the VPN tunnel interface
2. Docker-internal communication (container-to-container)
3. WireGuard handshake packets (to re-establish the tunnel)

Everything else is silently dropped. IPv6 is also fully blocked.

## Search Traffic vs Download Traffic

```mermaid
graph LR
    subgraph SEARCH["Search Traffic<br/>(Direct Internet — no VPN)"]
        ARR["Arr Apps"] -->|"HTTPS"| IDX["Indexer Sites"]
        PW["Prowlarr"] -->|"via FlareSolverr"| CF["CF-Protected Sites"]
    end

    subgraph DOWNLOAD["Download Traffic<br/>(VPN Tunnel — encrypted)"]
        TX["Transmission"] -->|"WireGuard"| TRK["Torrent Trackers"]
        SB["SABnzbd"] -->|"WireGuard"| USN["Usenet Servers"]
    end

    style SEARCH fill:#89b4fa,color:#1e1e2e
    style DOWNLOAD fill:#f38ba8,color:#1e1e2e
```

**Why searches don't need VPN:** Searching reveals what you're looking for, but downloading is what needs protection. Running searches through VPN would add latency and risk stability issues.

## Indexer Search Architecture

```mermaid
graph TD
    PW["Prowlarr<br/>(Central Manager)"]

    subgraph TORRENT["8 Torrent Indexers"]
        T1["1337x"] & T2["EZTV"] & T3["Knaben"] & T4["LimeTorrents"]
        T5["Nyaa.si"] & T6["SkidrowRepack"] & T7["The Pirate Bay"] & T8["YTS"]
    end

    subgraph USENET["4 Usenet Indexers"]
        U1["NZBFinder"] & U2["NZBgeek"] & U3["NzbPlanet"] & U4["Usenet-Crawler"]
    end

    PW -->|"with FlareSolverr<br/>CF bypass"| TORRENT
    PW -->|"API key auth<br/>no CF needed"| USENET

    PW ==>|"fullSync<br/>every 6 hours"| RD["Radarr (9 indexers)"]
    PW ==>|"fullSync"| SN["Sonarr (10 indexers)"]
    PW ==>|"fullSync"| LD["Lidarr (8 indexers)"]
```

Prowlarr is the single source of truth for indexers. It pushes configs to each arr app via fullSync — add an indexer once in Prowlarr and it appears everywhere.

**Category filtering:** Each app only receives indexers relevant to its media type. EZTV (TV-only) syncs to Sonarr but not Radarr. YTS (movies-only) syncs to Radarr but not Sonarr.

## Download Category Routing

Each arr app tags downloads with a category that determines the landing directory:

```mermaid
graph TD
    subgraph APPS["Arr Apps"]
        RD["Radarr"]
        SN["Sonarr"]
        LD["Lidarr"]
        LL["LazyLibrarian"]
        QA["QuestArr"]
    end

    subgraph TORRENT["Transmission Directories"]
        T1["torrents/radarr/"]
        T2["torrents/tv-sonarr/"]
        T3["torrents/lidarr/"]
        T4["torrents/books/"]
        T5["torrents/games/"]
    end

    subgraph USENET["SABnzbd Categories"]
        S1["usenet/movies/"]
        S2["usenet/tv/"]
        S3["usenet/music/"]
        S4["usenet/books/ + audiobooks/"]
        S5["usenet/games/"]
    end

    RD --> T1 & S1
    SN --> T2 & S2
    LD --> T3 & S3
    LL --> T4 & S4
    QA --> T5 & S5
```

## Usenet Server Tiers

SABnzbd uses a multi-tier server architecture for maximum article completion:

```mermaid
graph TD
    SB["SABnzbd"] -->|"Priority 0 (Primary)<br/>100 connections"| P0["Primary Backbone"]
    SB -->|"Priority 1 (Fill)<br/>8 connections"| P1["Fill Server<br/>(different backbone)"]
    SB -->|"Priority 2 (Backup)<br/>40 connections"| P2["Two Backup Servers<br/>(third backbone + block)"]

    P0 -->|"missing articles"| P1
    P1 -->|"still missing"| P2
```

If the primary server is missing articles (DMCA takedowns), SABnzbd automatically tries the fill server, then backups. Different providers use different backbone networks, maximizing the chance of finding complete files.

## Torrent vs Usenet: Why Both?

```mermaid
graph TB
    subgraph TORRENT["Torrent Path"]
        T1["Peer-to-peer protocol"]
        T2["Free (no subscription)"]
        T3["Good for popular content"]
        T4["Must seed back (hardlinks!)"]
        T5["Slower for old/rare content"]
    end

    subgraph USENET["Usenet Path"]
        U1["Client-server protocol"]
        U2["Requires paid subscription"]
        U3["Fast — saturates bandwidth"]
        U4["No seeding obligation"]
        U5["DMCA takedowns = gaps"]
    end

    style TORRENT fill:#89b4fa,color:#1e1e2e
    style USENET fill:#fab387,color:#1e1e2e
```

Having both maximizes availability. If a release is DMCA'd on usenet, torrents may still have it. If a torrent has few seeders, usenet may have it at full speed.

## The Hardlink Flow (Why Disk Space Doesn't Double)

```mermaid
sequenceDiagram
    participant TX as Transmission
    participant FS as Filesystem
    participant RD as Radarr
    participant JF as Jellyfin

    TX->>FS: Download complete<br/>/downloads/torrents/radarr/Movie.mkv<br/>Creates inode #3899

    TX->>TX: Continue seeding from<br/>original location

    RD->>FS: Import: create hardlink<br/>/media/movies/Movie (2024)/Movie.mkv<br/>Same inode #3899

    Note over FS: Two filenames<br/>One set of data blocks<br/>50GB file uses 50GB total<br/>(not 100GB)

    JF->>FS: Stream /media/movies/Movie.mkv
    Note over JF: Reads same data blocks

    Note over TX: Eventually stop seeding
    TX->>FS: Delete /downloads/.../Movie.mkv
    Note over FS: inode #3899 still has<br/>1 remaining link<br/>Data persists in library
```

**The common mistake (and why it fails):**

```
WRONG: Two separate volume mounts
  -v /downloads:/downloads    ← mount 1
  -v /media:/media            ← mount 2
  Result: Cross-device hardlink fails → Radarr COPIES the file → disk doubles

RIGHT: Single volume mount
  -v /data:/data
  Both /data/downloads/ and /data/media/ on same mount
  Result: Hardlink works → zero extra space
```

## DNS Architecture

```mermaid
graph TD
    subgraph VPN_DNS["Inside VPN (Download Clients)"]
        TX["Transmission"] & SB["SABnzbd"]
        TX & SB --> GDNS["Gluetun DNS Server"]
        GDNS -->|"Through VPN tunnel"| CF["Cloudflare DNS"]
    end

    subgraph BRIDGE_DNS["Bridge Network (Arr Apps)"]
        APPS["Radarr, Sonarr, Lidarr,<br/>Prowlarr, Bazarr, QuestArr"]
        APPS -->|"Hardcoded<br/>(bypasses local DNS)"| PUBLIC["Public DNS"]
    end

    subgraph HOST_DNS["Host Network"]
        JF["Jellyfin"] --> SYS["System DNS"]
    end

    style VPN_DNS fill:#f38ba8,color:#1e1e2e
```

Arr apps use hardcoded public DNS to prevent local ad-blockers from interfering with indexer domain resolution. Download client DNS goes through the VPN tunnel for privacy.

## Game Pipeline (Special Case)

Games don't have a built-in import engine like movies/TV. A separate script bridges the gap:

```mermaid
sequenceDiagram
    participant QA as QuestArr
    participant DL as Download Client
    participant CRON as game-import.sh<br/>(runs every 15 min)
    participant API as Client APIs
    participant LIB as Game Library

    QA->>DL: User picks a game release
    DL->>DL: Downloads through VPN

    loop Every 15 minutes
        CRON->>API: "Is this download finished?"
        API-->>CRON: "Yes, 100% complete"
        CRON->>CRON: Safety checks:<br/>✓ Settling time (10 min)<br/>✓ Not a duplicate<br/>✓ Not empty<br/>✓ Not still extracting
        alt Torrent
            CRON->>LIB: Hardlink (keeps seeding)
        else Usenet
            CRON->>LIB: Move (staging cleared)
        end
    end
```

## Book Sorting (LazyLibrarian PostProcessor)

LazyLibrarian handles both ebooks and audiobooks through file-type detection:

```mermaid
graph TD
    DL["Download completes in<br/>/downloads/torrents/books/<br/>/downloads/usenet/books/"]

    DL -->|"Every 10 minutes"| PP["PostProcessor<br/>scans download dirs"]

    PP --> DETECT{File type?}

    DETECT -->|"epub / pdf / mobi"| EBOOKS["/media/books/<br/>Author/Title/<br/>→ Kavita reads this"]

    DETECT -->|"mp3 / m4b / m4a"| AUDIO["/media/audiobooks/<br/>Author/Title/<br/>→ Audiobookshelf reads this"]

    PP -->|"Also generates"| META["Cover art (.jpg)<br/>Metadata (.opf)"]
```

## Subtitle Flow

```mermaid
graph TD
    TRIGGER["New media imported<br/>(Radarr/Sonarr notification)"]
    SCHEDULE["Wanted scan<br/>(every 6 hours)"]

    TRIGGER & SCHEDULE --> BZ["Bazarr"]

    BZ -->|"Query providers"| PROV["Subtitle Providers"]
    PROV -->|"Candidates"| BZ

    BZ --> SCORE["Score against<br/>media file metadata:<br/>hash, title, year,<br/>release group, source"]

    SCORE --> THRESH{Above<br/>threshold?}
    THRESH -->|"Yes"| DL["Download .srt"]
    THRESH -->|"No"| SKIP["Skip"]

    DL --> PLACE["Place alongside media:<br/>Movie.en.srt<br/>Episode.en.srt"]

    DL -->|"Low score?"| SYNC["Timing correction<br/>(subsync)"]

    PLACE --> JF["Jellyfin auto-detects<br/>sidecar subtitle files"]
```
