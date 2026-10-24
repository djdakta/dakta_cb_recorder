# CB Stream Recorder Daemon

A lightweight, fully automated Windows monitoring and recording daemon tailored for live streaming channels (specifically Chaturbate LL-HLS). It runs silently in the background, multiplexes dissociated CDN video and audio tracks in real-time, splits sessions into clean 60-minute segments, handles audio/video desync correction upon session completion, and pushes instant snapshot alerts via Telegram.

## 🚀 Overview

The CB Stream Recorder Daemon is designed to provide autonomous, robust monitoring and recording of live streams.

- **Autonomous Monitoring:** Continuously polls the target room every 15 seconds with a minimal footprint, avoiding heavy browser overhead.
- **LL-HLS Management:** Seamlessly handles Low-Latency HLS streams. It automatically detects and multiplexes dissociated audio and video chunks on-the-fly, utilizing FFmpeg's stream copy mode for zero quality loss.
- **60-Minute Segmentation:** Splits the recording into highly manageable and safe 60-minute blocks (`raw_YYYYMMDD_HHMMSS_part%03d.mkv`). This prevents file corruption in case of a sudden network drop by saving smaller, self-contained chunks.

## ⚙️ System Prerequisites

To ensure the daemon runs smoothly, the following dependencies must be installed and properly configured in your system environment:

- **OS:** Windows 10 or Windows 11
- **PowerShell:** Version 5.1 or PowerShell 7+
- **FFmpeg & FFprobe:** Must be installed and added to the system `PATH`. These tools handle stream downloading, multiplexing, and transcoding.
- **yt-dlp:** Must be installed, kept up-to-date, and added to the system `PATH`. Used for HLS stream extraction and resolution.

## 🛠 Configuration

To configure the daemon, open the primary PowerShell script (e.g., `dakta_cb_recorder_telegram_60_min_v8.1.ps1`) and adjust the following parameters located at the top of the script:

- **Target Room URL:**
  `$ChannelUrl = "https://chaturbate.com/username/"`
- **Destination Path:**
  `$DestDir = "D:\Vidz\CB_Recorder"` (The path where videos will be stored. The script will create it if it doesn't exist).
- **Telegram Bot Settings (for alerts):**
  - `$TelegramBotToken = "YOUR_BOT_TOKEN_HERE"`
  - `$TelegramChatId = "YOUR_CHAT_ID_HERE"`
- **Minimum File Size:**
  `$MinFileSize = 10MB` (Segments smaller than this size will be discarded to avoid saving empty/broken chunks).

## 🧰 Auxiliary Scripts

The daemon comes with several auxiliary VBScript and PowerShell tools to help manage its background execution gracefully:

- **`cb_recorder_autolaunch.vbs`:**
  A simple VBScript wrapper used to launch the main PowerShell script silently. It bypasses the command prompt flash and hides the PowerShell window so the daemon can run completely invisibly in the background.

- **`status_cb_recorder.vbs`:**
  A lightweight status checker. When executed, it checks the current running processes (looking for the PowerShell daemon and any active FFmpeg instances) and displays a quick popup notification indicating whether the daemon is actively recording, standing by in monitor mode, or entirely inactive.

- **`STOP_CB_RECORDER.ps1`:**
  A surgical termination script. Instead of brutally killing all PowerShell or FFmpeg instances on the machine, it targets specifically the processes initiated by the daemon (matching the specific command lines and recording patterns), ensuring a clean and precise shutdown of the recording loop.

## 🔎 Container Validation Example

After recording, you can validate that the final `.mp4` container correctly multiplexed both H.264 (video) and AAC (audio) streams using `ffprobe`:

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 stream_20231025_143000_part000.mp4
# Output expected: h264

ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 stream_20231025_143000_part000.mp4
# Output expected: aac
```

Alternatively, running a standard `ffprobe` against the file will show both streams bundled correctly:
```bash
ffprobe stream_20231025_143000_part000.mp4
```
*Look for `Stream #0:0: Video: h264...` and `Stream #0:1: Audio: aac...` in the output.*
