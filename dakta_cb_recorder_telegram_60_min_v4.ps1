# ==========================================
# Configuration
# ==========================================
$ChannelUrl       = "https://chaturbate.com/tacyleemon/"
$DestDir          = "D:\Vidz\CB_Recorder"
$MinFileSize      = 10MB  # Ignore captures under 10 MB

# Telegram Bot Credentials
$TelegramBotToken = "8902344508:AAFtXCS2YabKl4oJwrXnNF_kbYxVuq4NoWg"
$TelegramChatId   = "8902344508"

# Internal operational flags
$MonitoringActive = $true
$LastUpdateId     = 0

# ==========================================
# Dependency Validation
# ==========================================
$Dependencies = @("yt-dlp", "ffmpeg")
$MissingDeps = @()

foreach ($Dep in $Dependencies) {
    if (-not (Get-Command $Dep -ErrorAction SilentlyContinue)) {
        $MissingDeps += $Dep
    }
}

if ($MissingDeps.Count -gt 0) {
    Write-Host "[!] Missing required dependencies in system PATH: $($MissingDeps -join ', ')" -ForegroundColor Red
    Write-Host "[!] Ensure yt-dlp and FFmpeg are installed and accessible in %PATH%." -ForegroundColor Yellow
    exit 1
}

# Ensure destination directory exists
if (!(Test-Path -Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

# ==========================================
# Telegram API Helper Functions
# ==========================================
function Send-TelegramAlert {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Uri = "https://api.telegram.org/bot$TelegramBotToken/sendMessage"
    $Payload = @{
        chat_id                  = $TelegramChatId
        text                     = $Message
        parse_mode               = "Markdown"
        disable_web_page_preview = $true
    } | ConvertTo-Json

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json; charset=utf-8" -Body $Payload -ErrorAction Stop
        return $Response.ok
    }
    catch {
        Write-Warning "[!] Telegram dispatch failed: $_"
        return $false
    }
}

function Send-TelegramPhoto {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [string]$Caption = ""
    )

    $Uri = "https://api.telegram.org/bot$TelegramBotToken/sendPhoto"

    try {
        Add-Type -AssemblyName System.Net.Http
        $HttpClient = New-Object System.Net.Http.HttpClient
        $Content = New-Object System.Net.Http.MultipartFormDataContent

        # Chat ID parameter
        $StringContentChatId = New-Object System.Net.Http.StringContent($TelegramChatId)
        $Content.Add($StringContentChatId, "chat_id")

        # Caption parameter
        if ($Caption) {
            $StringContentCaption = New-Object System.Net.Http.StringContent($Caption)
            $Content.Add($StringContentCaption, "caption")
            $StringContentParse = New-Object System.Net.Http.StringContent("Markdown")
            $Content.Add($StringContentParse, "parse_mode")
        }

        # File payload
        $FileStream = [System.IO.File]::OpenRead($ImagePath)
        $FileContent = New-Object System.Net.Http.StreamContent($FileStream)
        $Content.Add($FileContent, "photo", [System.IO.Path]::GetFileName($ImagePath))

        $Response = $HttpClient.PostAsync($Uri, $Content).Result
        $FileStream.Close()
        $HttpClient.Dispose()

        return $Response.IsSuccessStatusCode
    }
    catch {
        Write-Warning "[!] Telegram photo upload failed: $_"
        return $false
    }
}

function Process-TelegramCommands {
    $Uri = "https://api.telegram.org/bot$TelegramBotToken/getUpdates?offset=$($script:LastUpdateId + 1)&timeout=1"

    try {
        $Updates = Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop

        if ($Updates.ok -and $Updates.result.Count -gt 0) {
            foreach ($Update in $Updates.result) {
                $script:LastUpdateId = $Update.update_id

                # Security: Only accept commands from your authorized ChatId
                if ($Update.message.chat.id.ToString() -ne $TelegramChatId.ToString()) {
                    continue
                }

                $Text = $Update.message.text.Trim()

                if ($Text -eq "/status") {
                    $State = if ($script:MonitoringActive) { "🟢 Active" } else { "🔴 Paused" }
                    $Reply = "📊 *Recorder Status*`n`n*Monitoring:* $State`n*Target:* $script:ChannelUrl`n*Folder:* `$script:DestDir`"
                    Send-TelegramAlert -Message $Reply
                }
                elseif ($Text -eq "/stop") {
                    $script:MonitoringActive = $false
                    Write-Host "[!] Monitoring paused via Telegram." -ForegroundColor Yellow
                    Send-TelegramAlert -Message "⏸ *Monitoring paused.* Send /start to resume."
                }
                elseif ($Text -eq "/start") {
                    $script:MonitoringActive = $true
                    Write-Host "[*] Monitoring resumed via Telegram." -ForegroundColor Green
                    Send-TelegramAlert -Message "▶️ *Monitoring resumed.* Watching target: $script:ChannelUrl"
                }
                elseif ($Text -eq "/disk") {
                    $DriveLetter = (Get-Item $script:DestDir).PSDrive.Name
                    $DriveInfo = Get-PSDrive -Name $DriveLetter

                    $FreeGB      = [math]::Round($DriveInfo.Free / 1GB, 2)
                    $UsedGB      = [math]::Round($DriveInfo.Used / 1GB, 2)
                    $TotalGB     = [math]::Round(($DriveInfo.Free + $DriveInfo.Used) / 1GB, 2)
                    $PercentFree = [math]::Round(($DriveInfo.Free / ($DriveInfo.Free + $DriveInfo.Used)) * 100, 1)

                    $FolderSizeMB = 0
                    $FolderFiles = Get-ChildItem -Path $script:DestDir -File -Recurse -ErrorAction SilentlyContinue
                    if ($FolderFiles) {
                        $FolderSizeMB = [math]::Round(($FolderFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
                    }

                    $DiskMsg = "💾 *Storage Metrics (`$DriveLetter`:)*`n`n" +
                               "*Free Space:* $FreeGB GB ($PercentFree% free)`n" +
                               "*Used Space:* $UsedGB GB`n" +
                               "*Total Capacity:* $TotalGB GB`n`n" +
                               "*Target Folder Size:* $FolderSizeMB MB"
                    Send-TelegramAlert -Message $DiskMsg
                }
                elseif ($Text -eq "/snapshot") {
                    Send-TelegramAlert -Message "📸 Fetching live frame for $script:ChannelUrl..."
                    $LiveStreamUrl = & yt-dlp -g --no-warnings --quiet $script:ChannelUrl 2>$null

                    if (-not $LiveStreamUrl) {
                        Send-TelegramAlert -Message "⚠️ Broadcaster is currently *offline* or unreachable. No preview available."
                    } else {
                        $SnapshotTemp = Join-Path $env:TEMP "snapshot_$(Get-Date -Format 'HHmmss').jpg"
                        & ffmpeg -y -ss 00:00:01 -i $LiveStreamUrl -frames:v 1 -q:v 2 $SnapshotTemp 2>$null

                        if (Test-Path $SnapshotTemp) {
                            $Caption = "📸 *Preview Frame*`n*Target:* $script:ChannelUrl`n*Timestamp:* $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                            Send-TelegramPhoto -ImagePath $SnapshotTemp -Caption $Caption
                            Remove-Item -Path $SnapshotTemp -Force
                        } else {
                            Send-TelegramAlert -Message "❌ Failed to extract preview frame via FFmpeg."
                        }
                    }
                }
                elseif ($Text -like "/url *") {
                    $NewUrl = $Text.Substring(5).Trim()
                    if ($NewUrl -match "^https?://") {
                        $script:ChannelUrl = $NewUrl
                        Write-Host "[*] Target URL updated: $script:ChannelUrl" -ForegroundColor Cyan
                        Send-TelegramAlert -Message "🔄 *Target URL updated to:*`n$script:ChannelUrl"
                    } else {
                        Send-TelegramAlert -Message "⚠️ Invalid URL provided. Must start with http:// or https://"
                    }
                }
            }
        }
    }
    catch {
        # Silently fail on network flickers during polling
    }
}

# ==========================================
# Main Monitoring Loop
# ==========================================
Write-Host "[*] Active monitoring initialized for : $ChannelUrl" -ForegroundColor Cyan
Write-Host "[*] Destination folder                 : $DestDir" -ForegroundColor Cyan

Send-TelegramAlert -Message "🚀 *Recorder daemon started*`n*Target:* $ChannelUrl`n`nAvailable commands:`n`/status` - Check state`n`/disk` - Disk space info`n`/snapshot` - Manual frame grab`n`/stop` - Pause watcher`n`/start` - Resume watcher`n`/url <link>` - Change target"

while ($true) {
    Process-TelegramCommands

    if ($MonitoringActive) {
        $Date = Get-Date -Format "yyyyMMdd_HHmmss"

        # Check if stream is currently live and resolve direct manifest URL
        $LiveStreamUrl = & yt-dlp -g --no-warnings --quiet $ChannelUrl 2>$null

        if ($LiveStreamUrl) {
            Write-Host "[!] Stream detected live! Grabbing snapshot and initiating capture..." -ForegroundColor Magenta

            # Automatic frame capture at broadcast start
            $LiveSnapshot = Join-Path $env:TEMP "live_start_$Date.jpg"
            & ffmpeg -y -ss 00:00:01 -i $LiveStreamUrl -frames:v 1 -q:v 2 $LiveSnapshot 2>$null

            $AlertStart = "🔴 *Live Stream Detected!*`n`n*Target:* $ChannelUrl`n*Started:* $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n*Segmenting:* 60-min chunks"
            
            if (Test-Path $LiveSnapshot) {
                Send-TelegramPhoto -ImagePath $LiveSnapshot -Caption $AlertStart
                Remove-Item -Path $LiveSnapshot -Force
            } else {
                Send-TelegramAlert -Message $AlertStart
            }

            # Define segmented output pattern
            # ffmpeg segmenter generates: stream_20261024_174900_part000.mp4, stream_20261024_174900_part001.mp4, etc.
            $OutputPattern = Join-Path $DestDir "stream_${Date}_part%03d.mp4"

            # Stream capture with 60-minute segment slicing and timestamp resetting
            yt-dlp `
                --downloader ffmpeg `
                --downloader-args "ffmpeg:-f segment -segment_time 3600 -reset_timestamps 1 -af aresample=async=1000 -movflags +faststart" `
                --no-part `
                --retries infinite `
                --fragment-retries infinite `
                --retry-sleep exp=1:10 `
                --socket-timeout 30 `
                -o $OutputPattern `
                $ChannelUrl

            # Post-session sweep: evaluate all generated parts for this run
            $GeneratedParts = Get-ChildItem -Path $DestDir -Filter "stream_${Date}_part*.mp4"
            $ValidPartsCount = 0
            $TotalSessionSize = 0

            foreach ($File in $GeneratedParts) {
                if ($File.Length -lt $MinFileSize) {
                    $DiscardMB = [math]::Round($File.Length / 1MB, 2)
                    Write-Host "[-] Discarding short fragment $($File.Name) ($DiscardMB MB)..." -ForegroundColor DarkGray
                    Remove-Item -Path $File.FullName -Force
                } else {
                    $ValidPartsCount++
                    $TotalSessionSize += $File.Length
                }
            }

            if ($ValidPartsCount -gt 0) {
                $TotalSizeMB = [math]::Round($TotalSessionSize / 1MB, 2)
                Write-Host "[+] Session finalized: $ValidPartsCount segments retained ($TotalSizeMB MB total)" -ForegroundColor Green

                $AlertFinish = "✅ *Recording Session Ended*`n`n*Segments Created:* $ValidPartsCount`n*Total Session Size:* $TotalSizeMB MB`n*Finished:* $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                Send-TelegramAlert -Message $AlertFinish
            }
        }
    }

    Start-Sleep -Seconds 15
}