# ==========================================
# Configuration
# ==========================================
$ChannelUrl       = "https://chaturbate.com/huba_booba/"
$DestDir          = "D:\Vidz\CB_Recorder"
$MinFileSize      = 10MB

# Identifiants Telegram Bot
$TelegramBotToken = "8902344508:AAFtXCS2YabKl4oJwrXnNF_kbYxVuq4NoWg"
$TelegramChatId   = "997463075"

# Drapeaux internes
$MonitoringActive = $true
$LastUpdateId = 0

# Purge des commandes en attente dans Telegram pour ne pas rejouer un vieux /kill
try {
    $FlushUri = "https://api.telegram.org/bot" + $TelegramBotToken + "/getUpdates?offset=-1"
    $Pending = Invoke-RestMethod -Uri $FlushUri -Method Get -ErrorAction Stop
    if ($Pending.ok -and ($Pending.result.Count -gt 0)) {
        $LastUpdateId = ($Pending.result | Select-Object -Last 1).update_id
        Write-Host "[*] File Telegram purgee (anciennes commandes ignorees)." -ForegroundColor DarkGray
    }
} catch {}

# Validation du répertoire de sortie
if (!(Test-Path -Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

# ==========================================
# Fonctions Telegram sécurisées
# ==========================================
function Send-TelegramAlert {
    param ([string]$Message)
    $Uri = "https://api.telegram.org/bot" + $TelegramBotToken + "/sendMessage"
    $Payload = @{
        chat_id                  = $TelegramChatId
        text                     = $Message
        parse_mode               = "Markdown"
        disable_web_page_preview = $true
    } | ConvertTo-Json

    try {
        $null = Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json; charset=utf-8" -Body $Payload -ErrorAction Stop
    } catch {}
}

function Send-TelegramPhoto {
    param (
        [string]$ImagePath,
        [string]$Caption = ""
    )
    $Uri = "https://api.telegram.org/bot" + $TelegramBotToken + "/sendPhoto"
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $HttpClient = New-Object System.Net.Http.HttpClient
        $Content = New-Object System.Net.Http.MultipartFormDataContent

        $Content.Add((New-Object System.Net.Http.StringContent($TelegramChatId)), "chat_id")
        if ($Caption) {
            $Content.Add((New-Object System.Net.Http.StringContent($Caption)), "caption")
            $Content.Add((New-Object System.Net.Http.StringContent("Markdown")), "parse_mode")
        }

        $FileStream = [System.IO.File]::OpenRead($ImagePath)
        $Content.Add((New-Object System.Net.Http.StreamContent($FileStream)), "photo", [System.IO.Path]::GetFileName($ImagePath))

        $null = $HttpClient.PostAsync($Uri, $Content).Result
        $FileStream.Close()
        $HttpClient.Dispose()
    } catch {}
}

function Process-TelegramCommands {
    $NextOffset = [int64]$script:LastUpdateId + 1
    $Uri = "https://api.telegram.org/bot" + $TelegramBotToken + "/getUpdates?offset=$NextOffset&timeout=1"

    try {
        $Updates = Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop
        if ($Updates.ok -and ($Updates.result.Count -gt 0)) {
            foreach ($Update in $Updates.result) {
                $script:LastUpdateId = $Update.update_id

                if ($null -eq $Update.message -or $null -eq $Update.message.text) { continue }
                if ($Update.message.chat.id.ToString() -ne $TelegramChatId.ToString()) { continue }

                $Text = $Update.message.text.Trim()

                switch -Regex ($Text) {
                    '^/status$' {
                        $State = if ($script:MonitoringActive) { "Actif" } else { "En pause" }
                        $Reply = "Statut : $State`nCible : $script:ChannelUrl`nDossier : $script:DestDir"
                        Send-TelegramAlert -Message $Reply
                    }
                    '^/disk$' {
                        $DriveItem   = (Get-Item -Path $script:DestDir).PSDrive
                        $DriveLetter = $DriveItem.Name
                        $DriveInfo   = Get-PSDrive -Name $DriveLetter

                        $FreeGB      = [math]::Round($DriveInfo.Free / 1GB, 2)
                        $UsedGB      = [math]::Round($DriveInfo.Used / 1GB, 2)
                        $TotalGB     = [math]::Round(($DriveInfo.Free + $DriveInfo.Used) / 1GB, 2)
                        $PercentFree = [math]::Round(($DriveInfo.Free / ($DriveInfo.Free + $DriveInfo.Used)) * 100, 1)

                        $FolderSizeMB = 0
                        $Files = Get-ChildItem -Path $script:DestDir -File -Recurse -ErrorAction SilentlyContinue
                        if ($Files) {
                            $FolderSizeMB = [math]::Round(($Files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
                        }

                        $DiskMsg = "Disque ${DriveLetter}:`nLibre : $FreeGB Go ($PercentFree %)`nUtilise : $UsedGB Go`nTotal : $TotalGB Go`nTaille dossier : $FolderSizeMB Mo"
                        Send-TelegramAlert -Message $DiskMsg
                    }
                    '^/stop$' {
                        $script:MonitoringActive = $false
                        Send-TelegramAlert -Message "Surveillance mise en pause. Envoyez /start pour relancer."
                    }
                    '^/start$' {
                        $script:MonitoringActive = $true
                        Send-TelegramAlert -Message ("Surveillance reprise pour : " + $script:ChannelUrl)
                    }
                    '^/url\s+(https?://\S+)' {
                        $script:ChannelUrl = $Matches[1]
                        Send-TelegramAlert -Message ("Cible mise a jour : " + $script:ChannelUrl)
                    }
                    '^/kill$' {
                        Send-TelegramAlert -Message "Arret force du recorder..."
                        Get-Process -Name "yt-dlp", "ffmpeg" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                        Stop-Process -Id $PID -Force
                    }
                }
            }
        }
    } catch {}
}

# ==========================================
# Boucle Principale
# ==========================================
Write-Host "[*] CB_Recorder initialise pour : $ChannelUrl" -ForegroundColor Cyan
Write-Host "[*] Repertoire de stockage      : $DestDir" -ForegroundColor Cyan

Send-TelegramAlert -Message ("CB_Recorder demarre pour : " + $ChannelUrl + "`nCommandes : /status, /disk, /stop, /start, /kill, /url <lien>")

while ($true) {
    Process-TelegramCommands

    if ($MonitoringActive) {
        $Date = Get-Date -Format "yyyyMMdd_HHmmss"
        Write-Host "[-] Verification du flux en direct ($(Get-Date -Format 'HH:mm:ss'))..." -ForegroundColor DarkGray

        # 1. Extraction des URLs de flux (Video + Audio)
        $Urls = @(& yt-dlp -f "b/bv*+ba/best" -g --no-warnings $ChannelUrl 2>$null | Where-Object { $_ -match "^https?://" })

        if ($Urls.Count -gt 0) {
            $VideoUrl = $Urls[0]
            $AudioUrl = if ($Urls.Count -gt 1) { $Urls[1] } else { $null }

            Write-Host "[!] Stream live detecte ! Envoi notification..." -ForegroundColor Magenta

            # 2. Snapshot Telegram immediat (base sur le flux video)
            $LiveSnapshot = Join-Path $env:TEMP ("snap_" + $Date + ".jpg")
            & ffmpeg -y -ss 00:00:01 -i $VideoUrl -frames:v 1 -q:v 2 $LiveSnapshot 2>$null

            $AlertStart = "🔴 *Live demarre !*`n`n*Cible :* $ChannelUrl`n*Debut :* $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n*Decoupage :* Segments de 60 min"
            if (Test-Path $LiveSnapshot) {
                Send-TelegramPhoto -ImagePath $LiveSnapshot -Caption $AlertStart
                Remove-Item -Path $LiveSnapshot -Force
            } else {
                Send-TelegramAlert -Message $AlertStart
            }

            # 3. Enregistrement direct par FFmpeg avec multiplexage
            $SegmentPattern = Join-Path $DestDir ("raw_" + $Date + "_part%03d.mkv")
            Write-Host "[*] Demarrage de l'enregistrement segmente..." -ForegroundColor Cyan

            if ($AudioUrl) {
                # Cas flux séparé Video + Audio
                & ffmpeg -y `
                    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 10000000 -i $VideoUrl `
                    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 10000000 -i $AudioUrl `
                    -map 0:v:0 -map 1:a:0 `
                    -c copy `
                    -f segment `
                    -segment_time 3600 `
                    -reset_timestamps 1 `
                    $SegmentPattern
            } else {
                # Cas flux combiné
                & ffmpeg -y `
                    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 10000000 -i $VideoUrl `
                    -c copy `
                    -f segment `
                    -segment_time 3600 `
                    -reset_timestamps 1 `
                    $SegmentPattern
            }

            # 4. Traitement post-session (Transcodage + Notification)
            $RawFiles = Get-ChildItem -Path $DestDir -Filter ("raw_" + $Date + "_part*.mkv")
            foreach ($RawFile in $RawFiles) {
                if ($RawFile.Length -lt $MinFileSize) {
                    Write-Host "[-] Fragment ignore car trop court : $($RawFile.Name)" -ForegroundColor DarkGray
                    Remove-Item -Path $RawFile.FullName -Force
                    continue
                }

                $FinalMp4Name = $RawFile.Name -replace "^raw_", "stream_" -replace "\.mkv$", ".mp4"
                $FinalMp4Path = Join-Path $DestDir $FinalMp4Name

                Write-Host "[*] Transcodage et calage audio : $($RawFile.Name) -> MP4..." -ForegroundColor Cyan
                & ffmpeg -y -i $RawFile.FullName -c:v copy -c:a aac -b:a 192k -af "aresample=async=1000" -movflags +faststart $FinalMp4Path 2>$null

                if (Test-Path $FinalMp4Path) {
                    $Mp4Item = Get-Item -Path $FinalMp4Path
                    $SizeMB  = [math]::Round($Mp4Item.Length / 1MB, 2)
                    Remove-Item -Path $RawFile.FullName -Force
                    Send-TelegramAlert -Message ("🎬 *Segment finalise :* " + $Mp4Item.Name + " (" + $SizeMB + " Mo)")
                }
            }
        }
    }

    Start-Sleep -Seconds 15
}