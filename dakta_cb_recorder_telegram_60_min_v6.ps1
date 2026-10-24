# ==========================================
# Configuration
# ==========================================
$ChannelUrl       = "https://chaturbate.com/calimerrsa/"
$DestDir          = "D:\Vidz\CB_Recorder"
$MinFileSize      = 10MB

# Telegram Bot Credentials
$TelegramBotToken = "8902344508:AAFtXCS2YabKl4oJwrXnNF_kbYxVuq4NoWg"
$TelegramChatId   = "997463075"

# Internal operational flags
$MonitoringActive = $true
$LastUpdateId     = 0

# ==========================================
# Dependency Validation
# ==========================================
$Dependencies = @("yt-dlp", "ffmpeg")
$MissingDeps  = @()

foreach ($Dep in $Dependencies) {
    if (-not (Get-Command $Dep -ErrorAction SilentlyContinue)) {
        $MissingDeps += $Dep
    }
}

if ($MissingDeps.Count -gt 0) {
    Write-Host "[!] Missing required dependencies in system PATH: $($MissingDeps -join ', ')" -ForegroundColor Red
    Write-Host "[!] Ensure yt-dlp and FFmpeg are installed and accessible in %PATH%." -ForegroundColor Yellow
    Read-Host "Press Enter to exit..."
    exit 1
}

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

        $StringContentChatId = New-Object System.Net.Http.StringContent($TelegramChatId)
        $Content.Add($StringContentChatId, "chat_id")

        if ($Caption) {
            $StringContentCaption = New-Object System.Net.Http.StringContent($Caption)
            $Content.Add($StringContentCaption, "caption")
            $StringContentParse = New-Object System.Net.Http.StringContent("Markdown")
            $Content.Add($StringContentParse, "parse_mode")
        }

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
    $NextOffset = [int64]$script:LastUpdateId + 1
    $Uri = "https://api.telegram.org/bot$TelegramBotToken/getUpdates?offset=$NextOffset&timeout=1"

    try {
        $Updates = Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop

        if ($Updates.ok -and ($Updates.result.Count -gt 0)) {
            foreach ($Update in $Updates.result) {
                $script:LastUpdateId = $Update.update_id

                if ($null -eq $Update.message -or $null -eq $Update.message.text) {
                    continue
                }

                if ($Update.message.chat.id.ToString() -ne $TelegramChatId.ToString()) {
                    continue
                }

                $RawText = $Update.message.text.Trim()

                switch -Regex ($RawText) {
                    '^/status$' {
                        $State = if ($script:MonitoringActive) { "Active" } else { "Paused" }
                        $Reply = "Status: $State`nTarget: $script:ChannelUrl`nDir: $script:DestDir"
                        Send-TelegramAlert -Message $Reply
                    }
                    '^/stop$' {
                        $script:MonitoringActive = $false
                        Write-Host "[!] Monitoring paused via Telegram." -ForegroundColor Yellow
                        Send-TelegramAlert -Message "Monitoring paused. Send /start to resume."
                    }
                    '^/start$' {
                        $script:MonitoringActive = $true
                        Write-Host "[*] Monitoring resumed via Telegram." -ForegroundColor Green
                        Send-TelegramAlert -Message "Monitoring resumed. Watching: $script:ChannelUrl"
                    }
                    '^/disk$' {
                        $DriveItem = (Get-Item -Path $script:DestDir).PSDrive
                        $DriveName = $DriveItem.Name
                        $DriveInfo = Get-PSDrive -Name $DriveName

                        $FreeGB      = [math]::Round($DriveInfo.Free / 1GB, 2)
                        $UsedGB      = [math]::Round($DriveInfo.Used / 1GB, 2)
                        $TotalGB     = [math]::Round(($DriveInfo.Free + $DriveInfo.Used) / 1GB, 2)
                        $PercentFree = [math]::Round(($DriveInfo.Free / ($DriveInfo.Free + $DriveInfo.Used)) * 100, 1)

                        $FolderSizeMB = 0
                        $FolderFiles = Get-ChildItem -Path $script:DestDir -File -Recurse -ErrorAction SilentlyContinue
                        if ($FolderFiles) {
                            $FolderSizeMB = [math]::Round(($FolderFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
                        }

                        $DiskMsg = "Drive $DriveName - Free: $FreeGB GB ($PercentFree% free) | Used: $UsedGB GB | Total: $TotalGB GB | Rec Dir: $FolderSizeMB MB"
                        Send-TelegramAlert -Message $DiskMsg
                    }
                    '^/snapshot$' {
                        Send-TelegramAlert -Message "Fetching snapshot frame..."
                        $LiveStreamUrl = & yt-dlp -g --no-warnings --quiet $script:ChannelUrl 2>$null

                        if (-not $LiveStreamUrl) {
                            Send-TelegramAlert -Message "Target is currently offline."
                        } else {
                            $SnapshotTemp = Join-Path $env:TEMP "snap_$(Get-Date -Format 'HHmmss').jpg"
                            & ffmpeg -y -ss 00:00:01 -i $LiveStreamUrl -frames:v 1 -q:v 2 $SnapshotTemp 2>$null

                            if (Test-Path $SnapshotTemp) {
                                $Caption = "Preview: $script:ChannelUrl at $(Get-Date -Format 'HH:mm:ss')"
                                Send-TelegramPhoto -ImagePath $SnapshotTemp -Caption $Caption
                                Remove-Item -Path $SnapshotTemp -Force
                            } else {
                                Send-TelegramAlert -Message "Could not generate snapshot."
                            }
                        }
                    }
                    '^/url\s+(https?://\S+)' {
                        $script:ChannelUrl = $Matches[1]
                        Write-Host "[*] Target updated: $script:ChannelUrl" -ForegroundColor Cyan
                        Send-TelegramAlert -Message "Target updated to: $script:ChannelUrl"
                    }
                }
            }
        }
    }
    catch {
        # Network drops during polling do not crash the script
    }
}

# ==========================================
# Main Monitoring Loop
# ==========================================
Write-Host "[*] Active monitoring initialized for : $ChannelUrl" -ForegroundColor Cyan
Write-Host "[*] Destination folder                 : $DestDir" -ForegroundColor Cyan

Send-TelegramAlert -Message "Recorder online for $ChannelUrl`nCommands: /status, /disk, /snapshot, /stop, /start, /url <link>"

while ($true) {
    Process-TelegramCommands

    if ($MonitoringActive) {
        $Date = Get-Date -Format "yyyyMMdd_HHmmss"
        $LiveStreamUrl = & yt-dlp -g --no-warnings --quiet $ChannelUrl 2>$null

        if ($LiveStreamUrl) {
            Write-Host "[!] Stream detected live! Grabbing snapshot and initiating capture..." -ForegroundColor Magenta

            # Live snapshot at launch
            $LiveSnapshot = Join-Path $env:TEMP "start_$Date.jpg"
            & ffmpeg -y -ss 00:00:01 -i $LiveStreamUrl -frames:v 1 -q:v 2 $LiveSnapshot 2>$null

            $AlertStart = "Live stream started for $ChannelUrl (Segmenting: 60 min chunks)"
            if (Test-Path $LiveSnapshot) {
                Send-TelegramPhoto -ImagePath $LiveSnapshot -Caption $AlertStart
                Remove-Item -Path $LiveSnapshot -Force
            } else {
                Send-TelegramAlert -Message $AlertStart
            }

            # Capture live stream segmented into 60-minute MKV parts
            $MkvPattern = Join-Path $DestDir "raw_${Date}_part%03d.mkv"

            yt-dlp `
                --downloader ffmpeg `
                --downloader-args "ffmpeg_i:-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5" `
                --downloader-args "ffmpeg:-c copy -f segment -segment_time 3600 -reset_timestamps 1" `
                --no-part `
                --retries infinite `
                --fragment-retries infinite `
                --socket-timeout 30 `
                -o $MkvPattern `
                $ChannelUrl

            # ==========================================
            # Post-Session Transcoding: MKV -> MP4
            # ==========================================
            $RawFiles = Get-ChildItem -Path $DestDir -Filter "raw_${Date}_part*.mkv"
            $TranscodedCount = 0

            foreach ($RawFile in $RawFiles) {
                if ($RawFile.Length -lt $MinFileSize) {
                    $DiscardMB = [math]::Round($RawFile.Length / 1MB, 2)
                    Write-Host "[-] Discarding short fragment $($RawFile.Name) ($DiscardMB MB)..." -ForegroundColor DarkGray
                    Remove-Item -Path $RawFile.FullName -Force
                    continue
                }

                $FinalMp4Name = $RawFile.Name -replace "^raw_", "stream_" -replace "\.mkv$", ".mp4"
                $FinalMp4Path = Join-Path $DestDir $FinalMp4Name

                Write-Host "[*] Transcoding $($RawFile.Name) to MP4 with audio resync..." -ForegroundColor Cyan

                & ffmpeg -y -i $RawFile.FullName -c:v copy -c:a aac -b:a 192k -af "aresample=async=1000" -movflags +faststart $FinalMp4Path 2>$null

                if (Test-Path $FinalMp4Path) {
                    $Mp4Item = Get-Item -Path $FinalMp4Path
                    $SizeMB  = [math]::Round($Mp4Item.Length / 1MB, 2)
                    Write-Host "[+] Transcoded: $($Mp4Item.Name) ($SizeMB MB)" -ForegroundColor Green

                    Remove-Item -Path $RawFile.FullName -Force
                    $TranscodedCount++

                    $PartAlert = "Segment Ready: $($Mp4Item.Name) ($SizeMB MB) - Audio synced"
                    Send-TelegramAlert -Message $PartAlert
                }
            }

            if ($TranscodedCount -gt 0) {
                Write-Host "[+] Session complete: $TranscodedCount segment(s) transcoded." -ForegroundColor Green
            }
        }
    }

    Start-Sleep -Seconds 15
}