# Quality Profiles & Release Selection

How the stack decides which release to download when multiple options exist.

## The Decision Engine

Every arr app uses the same core algorithm:

```mermaid
graph TD
    RELEASE["Incoming Release<br/>from indexer search"] --> Q{Quality tier<br/>in allowed list?}
    Q -->|"No"| R1["REJECTED"]
    Q -->|"Yes"| CF["Calculate Custom Format score<br/>(sum all matching CFs)"]

    CF --> UNWANTED{Any -10000 CF<br/>matched?}
    UNWANTED -->|"Yes"| R2["REJECTED<br/>(unwanted content)"]
    UNWANTED -->|"No"| MIN{Total score ≥<br/>minimum?}

    MIN -->|"No"| R3["REJECTED"]
    MIN -->|"Yes"| RANK["ACCEPTED<br/>Ranked by total score"]

    RANK --> BEST["Highest score grabbed"]
    BEST --> UPGRADE{Better than<br/>existing file?}
    UPGRADE -->|"Yes"| UP["UPGRADE<br/>(replace existing)"]
    UPGRADE -->|"No"| SKIP["SKIP"]

    style R1 fill:#f38ba8,color:#1e1e2e
    style R2 fill:#f38ba8,color:#1e1e2e
    style R3 fill:#f38ba8,color:#1e1e2e
    style UP fill:#a6e3a1,color:#1e1e2e
```

## Custom Format Scoring Across All Apps

### Radarr — Movies (48 Custom Formats)

```mermaid
graph LR
    subgraph POSITIVE["Positive Scores (prefer)"]
        direction TB
        A["HD Bluray Tier 01: +1800"]
        B["HD Bluray Tier 02: +1750"]
        C["HD Bluray Tier 03: +1700"]
        D["WEB Tier 01: +1700"]
        E["WEB Tier 02: +1650"]
        F["WEB Tier 03: +1600"]
        G["IMAX: +800"]
        H["IMAX Enhanced: +800"]
        I["Special Edition: +125"]
    end

    subgraph NEGATIVE["Instant Reject (-10000)"]
        direction TB
        X["BR-DISK"]
        Y["LQ / LQ (Release Title)"]
        Z["x265 (HD)"]
        W["3D / Extras / AV1"]
        V["Bad Dual Groups"]
        U["No-RlsGroup / Obfuscated"]
    end

    style POSITIVE fill:#a6e3a1,color:#1e1e2e
    style NEGATIVE fill:#f38ba8,color:#1e1e2e
```

**Tier system:** Release groups are ranked into tiers based on their track record. A Tier 01 Bluray rip from DON scores +1800 while a random group with no history gets +0.

**Movie versions:** IMAX gets a massive +800 boost because IMAX versions have expanded aspect ratios and better sound. Special Editions, Remasters, Criterion, and Vinegar Syndrome releases get smaller boosts.

**14 streaming service CFs** (AMZN, NF, DSNP, etc.) score 0 in Radarr — they're used for tagging/naming only, not for selection.

### Sonarr — TV Shows (44 Custom Formats)

Key differences from Radarr:

| Feature | Radarr | Sonarr |
|---------|--------|--------|
| Streaming services | Score 0 (tagging only) | **+75 each** (17 services) |
| HDR/DV | Not scored | DV Boost +1000, HDR +500, HDR10+ +100 |
| SDR at 4K | Not penalized | **-10000** (want HDR for 4K content) |

**Why streaming services matter more for TV:** A Netflix or Disney+ WEB-DL of a TV show is almost certainly high quality. For movies, the release group matters more than the source.

### Lidarr — Music (5 Custom Formats, Davo's Guide)

```mermaid
graph TD
    subgraph SCORING["Music Release Scoring"]
        CD["CD Rip: +500<br/>(physical source = gold standard)"]
        PREF["Preferred Groups: +500<br/>(DeVOiD, PERFECT, ENRiCH)"]
        WEB["WEB Release: +200<br/>(digital streaming source)"]
        LOSS["Lossless Tag: +100<br/>(FLAC/ALAC indicator)"]
        VINYL["Vinyl Rip: -10000<br/>(noisy, inferior digital)"]
    end

    style VINYL fill:#f38ba8,color:#1e1e2e
```

**Min CF score: 1** — Lidarr requires at least one positive CF match. A random MP3 with no quality indicators scores 0 and gets skipped. This prevents grabbing garbage.

## Scoring Examples

### Movie: The Matrix

```
Release A: The.Matrix.1999.Bluray.1080p.x264-DON
  ✓ HD Bluray Tier 01 (+1800)
  = Score: 1800

Release B: The.Matrix.1999.IMAX.Bluray.1080p.x264-DON
  ✓ HD Bluray Tier 01 (+1800)
  ✓ IMAX (+800)
  = Score: 2600  ← WINNER

Release C: The.Matrix.1999.1080p.WEB-DL.AMZN-NTb
  ✓ WEB Tier 01 (+1700)
  ✓ AMZN (+0, tagging only)
  = Score: 1700

Release D: The.Matrix.1999.CAM.LQ-BadGroup
  ✗ LQ (-10000)
  = REJECTED
```

### TV Show: Premium 4K

```
Release A: Show.S01E01.2160p.DSNP.WEB-DL.DV.HDR.Atmos-FLUX
  ✓ WEB Tier 01 (+1700)
  ✓ Disney+ (+75)
  ✓ DV Boost (+1000)
  ✓ HDR (+500)
  ✓ UHD Streaming Boost (+75)
  = Score: 3350  ← WINNER

Release B: Show.S01E01.1080p.NF.WEB-DL-GROUP
  ✓ WEB Tier 02 (+1650)
  ✓ Netflix (+75)
  = Score: 1725

Release C: Show.S01E01.2160p.WEB-DL.SDR-BadGroup
  ✗ SDR at 4K (-10000)
  = REJECTED (want HDR for 4K)
```

### Music: FLAC Album

```
Release A: Album - FLAC - CD - DeVOiD
  ✓ CD (+500) + Preferred Groups (+500) + Lossless (+100)
  = Score: 1100  ← WINNER

Release B: Album - FLAC - WEB
  ✓ WEB (+200) + Lossless (+100)
  = Score: 300

Release C: Album - MP3-320
  No CF matches = Score: 0
  Below minimum (1) → SKIPPED

Release D: Album - Vinyl
  ✗ Vinyl (-10000) → REJECTED
```

## Quality Profile Settings

| Setting | Radarr | Sonarr | Lidarr |
|---------|--------|--------|--------|
| Profile name | "Any" | "Any" | "Any" |
| Upgrade allowed | Yes | Yes | Yes |
| Cutoff quality | Bluray-1080p | WEB 2160p | Lossless |
| Min CF score | 0 | 0 | 1 |
| Cutoff CF score | 10000 | 10000 | 10000 |
| Propers/Repacks | CF-handled (+5/+6/+7) | CF-handled | Do Not Prefer |

**Cutoff CF score of 10000** means the app essentially never stops looking for upgrades. A Tier 01 Bluray IMAX (2600) will still be upgraded if a Tier 01 Bluray IMAX Criterion (2625) appears.

## Upgrade Flow

```mermaid
sequenceDiagram
    participant RSS as RSS Sync<br/>(every 15-30 min)
    participant ARR as Arr App
    participant LIB as Library
    participant DL as Download Client

    loop Periodic Check
        RSS->>ARR: New release found
        ARR->>ARR: Score: 2600
        ARR->>LIB: Current file score?
        LIB-->>ARR: 1700

        Note over ARR: 2600 > 1700<br/>and quality ≥ cutoff

        ARR->>DL: Download upgrade
        DL-->>ARR: Complete
        ARR->>LIB: Replace with upgrade
        Note over LIB: Old file removed<br/>New file hardlinked
    end
```

## Season Pack Logic (Sonarr)

When more than 50% of a season's episodes are missing, Sonarr prefers downloading the entire season pack over individual episodes. Season packs are evaluated against the same CF scoring system.

```mermaid
graph TD
    MISSING{Missing episodes<br/>in season?}
    MISSING -->|"≤ 50%"| INDIVIDUAL["Search individual episodes"]
    MISSING -->|"> 50%"| PACK["Prefer season pack<br/>(if available and scores well)"]

    PACK --> EXTRACT["Extract and rename<br/>per episode naming convention"]
```

## Naming Conventions (TRaSH Guide)

**Movies:**
```
Movie Name (2024) {Edition Tags} [Custom Formats][Bluray-1080p][DTS-HD MA 7.1][HDR10][x265]-ReleaseGroup
```

**TV Episodes:**
```
Series Name (2024) - S01E01 - Episode Title [WEB Tier 01 WEB-DL-1080p][EAC3 5.1][x264]-ReleaseGroup
```

**Anime:**
```
Anime Name (2024) - S01E01 - 001 - Episode Title [CFs Quality][Audio Languages][HDR][x265 10bit]-Group
```

**Music Tracks:**
```
Album Title (2024)/01 - Track Title.flac
```

**Artist Folders:** `{Artist NameThe}` — "Beatles, The" sorts under B.
