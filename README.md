# CB Stream Recorder Daemon

A lightweight, fully automated Windows monitoring and recording daemon tailored for live streaming channels (Chaturbate LL-HLS). It runs silently in the background, multiplexes dissociated CDN video and audio tracks in real-time, splits sessions into clean 60-minute segments, handles audio/video desync correction upon session completion, and pushes instant snapshot alerts via Telegram.

---

## Key Features

- **Continuous Standby Monitoring:** Polls the target room every 15 seconds with minimal footprint and zero browser overhead.
- **CDN Track Multiplexing:** Detects dissociated LL-HLS streams (`chunklist_3` video + `chunklist_5` audio) and remuxes them on-the-fly via FFmpeg copy mode with zero quality loss.
- **Anti-403 Protection:** Injects necessary HTTP headers (`User-Agent` and `Referer`) into FFmpeg network demuxers to prevent CDN authorization drops.
- **Hourly Segmentation:** Splits recordings into seamless 60-minute chunks (`raw_YYYYMMDD_HHMMSS_part%03d.mkv`) using Matroska containers to preserve stream integrity in case of unexpected connection loss.
- **Post-Session Remuxing & A/V Resync:** Automatically converts MKV chunks to web-optimized MP4 files with `aresample=async=1000` drift correction once the broadcaster goes offline.
- **Telegram Push Notifications:** Sends immediate alerts with live captured frames (via HTML payload with TLS 1.2 support) upon room opening, followed by finalization reports with output file sizes.
- **Silent Background Operations:** Runs headlessly via VBScript wrappers without command prompt flashes, accompanied by lightweight desktop shortcut utilities for status checks and surgical process termination.

---

## Prerequisites

- **Windows 10 / 11** (PowerShell 5.1 or PowerShell 7+)
- **FFmpeg & FFprobe:** Installed and reachable via system `PATH`.
- **yt-dlp:** Up-to-date and accessible via system `PATH`.
- **Telegram Bot:** A bot token and your personal chat ID for alerts.

---

## Architecture & Workflow

```text
[ Standby Loop (every 15s) ]
           │
           ▼
[ yt-dlp resolves live HLS manifest ]
     ├── No  ──> Sleep 15s and retry
     └── Yes ──> 1. Capture snapshot -> Send to Telegram (HTML + TLS 1.2)
                 2. Launch FFmpeg segment muxer (-c copy, 3600s slices)
                 3. Wait for broadcaster disconnection
                 4. Re-encode audio (aresample=async=1000) -> Faststart MP4
                 5. Send completion report to Telegram -> Return to Standby