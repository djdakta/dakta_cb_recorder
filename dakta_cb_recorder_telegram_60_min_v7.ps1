# ==========================================
# Configuration & État Partagé (Thread-Safe)
# ==========================================
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$SyncState = [hashtable]::Synchronized(@{
    ChannelUrl       = "https://chaturbate.com/avasykes/"
    DestDir          = "D:\Vidz\CB_Recorder"
    MinFileSize      = 10MB
    TelegramBotToken = "8902344508:AAFtXCS2YabKl4oJwrXnNF_kbYxVuq4NoWg"
    TelegramChatId   = "997463075"
    MonitoringActive = $true
    KillRequested    = $false
    MainPID          = $PID
    CurrentRecording = $false
})

# ==========================================
# Validation des Dépendances
# ==========================================
$Dependencies = @("yt-dlp", "ffmpeg")
$MissingDeps  = @()

foreach ($Dep in $Dependencies) {
    if (-not (Get-Command $Dep -ErrorAction SilentlyContinue)) {
        $MissingDeps += $Dep
    }
}

if ($MissingDeps.Count -gt 0) {
    Write-Host "[!] Dépendances manquantes dans le PATH : $($MissingDeps -join ', ')" -ForegroundColor Red
    exit 1
}

if (!(Test-Path -Path $SyncState.DestDir)) {
    New-Item -ItemType Directory -Path $SyncState.DestDir | Out-Null
}

# ==========================================
# Fonctions Telegram Thread Principal
# ==========================================
function Send-TelegramAlert {
    param ([string]$Message)
    $Uri = "https://api.telegram.org/bot" + $SyncState.TelegramBotToken + "/sendMessage"
    $Payload = @{
        chat_id                  = $SyncState.TelegramChatId
        text                     = $Message
        parse_mode               = "Markdown"
        disable_web_page_preview = $true
    } | ConvertTo-Json

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json; charset=utf-8" -Body $Payload -ErrorAction Stop
        return $Response.ok
    } catch { return $false }
}

function Send-TelegramPhoto {
    param (
        [string]$ImagePath,
        [string]$Caption = ""
    )
    $Uri = "https://api.telegram.org/bot" + $SyncState.TelegramBotToken + "/sendPhoto"
    try {
        $HttpClient = New-Object System.Net.Http.HttpClient
        $Content = New-Object System.Net.Http.MultipartFormDataContent

        $Content.Add((New-Object System.Net.Http.StringContent($SyncState.TelegramChatId)), "chat_id")
        if ($Caption) {
            $Content.Add((New-Object System.Net.Http.StringContent($Caption)), "caption")
            $Content.Add((New-Object System.Net.Http.StringContent("Markdown")), "parse_mode")
        }

        $FileStream = [System.IO.File]::OpenRead($ImagePath)
        $Content.Add((New-Object System.Net.Http.StreamContent($FileStream)), "photo", [System.IO.Path]::GetFileName($ImagePath))

        $Response = $HttpClient.PostAsync($Uri, $Content).Result
        $FileStream.Close()
        $HttpClient.Dispose()
        return $Response.IsSuccessStatusCode
    } catch { return $false }
}

# ==========================================
# Démarrage du Runspace Telegram
# ==========================================
$TelegramWorkerScript = {
    param($Sync)

    function Send-WorkerMsg {
        param([string]$Text)
        $Uri = "https://api.telegram.org/bot" + $Sync.TelegramBotToken + "/sendMessage"
        $Body = @{
            chat_id                  = $Sync.TelegramChatId
            text                     = $Text
            parse_mode               = "Markdown"
            disable_web_page_preview = $true
        } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json; charset=utf-8" -Body $Body -ErrorAction Stop | Out-Null
        } catch {}
    }

    function Send-WorkerPhoto {
        param([string]$ImagePath, [string]$Caption = "")
        $Uri = "https://api.telegram.org/bot" + $Sync.TelegramBotToken + "/sendPhoto"
        try {
            $Client = New-Object System.Net.Http.HttpClient
            $Form = New-Object System.Net.Http.MultipartFormDataContent
            $Form.Add((New-Object System.Net.Http.StringContent($Sync.TelegramChatId)), "chat_id")
            if ($Caption) {
                $Form.Add((New-Object System.Net.Http.StringContent($Caption)), "caption")
                $Form.Add((New-Object System.Net.Http.StringContent("Markdown")), "parse_mode")
            }
            $FileStream = [System.IO.File]::OpenRead($ImagePath)
            $Form.Add((New-Object System.Net.Http.StreamContent($FileStream)), "photo", [System.IO.Path]::GetFileName($ImagePath))
            $null = $Client.PostAsync($Uri, $Form).Result
            $FileStream.Close()
            $Client.Dispose()
        } catch {}
    }

    $LastUpdateId = 0

    while (-not $Sync.KillRequested) {
        $NextOffset = [int64]$LastUpdateId + 1
        $Uri = "https://api.telegram.org/bot" + $Sync.TelegramBotToken + "/getUpdates?offset=$NextOffset&timeout=2"

        try {
            $Updates = Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop
            if ($Updates.ok -and ($Updates.result.Count -gt 0)) {
                foreach ($Update in $Updates.result) {
                    $LastUpdateId = $Update.update_id

                    if ($null -eq $Update.message -or $null -eq $Update.message.text) { continue }
                    if ($Update.message.chat.id.ToString() -ne $Sync.TelegramChatId.ToString()) { continue }

                    $Text = $Update.message.text.Trim()

                    switch -Regex ($Text) {
                        '^/status$' {
                            $State = if ($Sync.MonitoringActive) { "Actif" } else { "En pause" }
                            $RecState = if ($Sync.CurrentRecording) { "Enregistrement EN COURS" } else { "En attente / Hors-ligne" }
                            $Reply = "Statut : $State`nActivite : $RecState`nCible : " + $Sync.ChannelUrl + "`nDossier : " + $Sync.DestDir
                            Send-WorkerMsg -Text $Reply
                        }
                        '^/disk$' {
                            $DriveItem = (Get-Item -Path $Sync.DestDir).PSDrive
                            $DriveLetter = $DriveItem.Name
                            $DriveInfo = Get-PSDrive -Name $DriveLetter

                            $FreeGB      = [math]::Round($DriveInfo.Free / 1GB, 2)
                            $UsedGB      = [math]::Round($DriveInfo.Used / 1GB, 2)
                            $TotalGB     = [math]::Round(($DriveInfo.Free + $DriveInfo.Used) / 1GB, 2)
                            $PercentFree = [math]::Round(($DriveInfo.Free / ($DriveInfo.Free + $DriveInfo.Used)) * 100, 1)

                            $FolderSizeMB = 0
                            $Files = Get-ChildItem -Path $Sync.DestDir -File -Recurse -ErrorAction SilentlyContinue
                            if ($Files) {
                                $FolderSizeMB = [math]::Round(($Files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
                            }

                            $DiskMsg = "Disque ${DriveLetter}:`nLibre : $FreeGB Go ($PercentFree %)`nUtilise : $UsedGB Go`nTotal : $TotalGB Go`nTaille dossier : $FolderSizeMB Mo"
                            Send-WorkerMsg -Text $DiskMsg
                        }
                        '^/snapshot$' {
                            Send-WorkerMsg -Text "Extraction du snapshot..."
                            $RawUrl = (& yt-dlp -f "b/bv*+ba/best" -g --no-warnings $Sync.ChannelUrl 2>$null | Where-Object { $_ -match "^https?://" } | Select-Object -First 1)

                            if (-not $RawUrl) {
                                Send-WorkerMsg -Text "Cible hors-ligne ou flux indisponible."
                            } else {
                                $SnapPath = Join-Path $env:TEMP ("snap_" + (Get-Date -Format 'HHmmss') + ".jpg")
                                & ffmpeg -y -ss 00:00:01 -i $RawUrl -frames:v 1 -q:v 2 $SnapPath 2>$null

                                if (Test-Path $SnapPath) {
                                    $Caption = "Apercu : " + $Sync.ChannelUrl + " a " + (Get-Date -Format 'HH:mm:ss')
                                    Send-WorkerPhoto -ImagePath $SnapPath -Caption $Caption
                                    Remove-Item -Path $SnapPath -Force
                                } else {
                                    Send-WorkerMsg -Text "Impossible de generer le snapshot."
                                }
                            }
                        }
                        '^/stop$' {
                            $Sync.MonitoringActive = $false
                            Get-Process -Name "yt-dlp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                            Send-WorkerMsg -Text "Surveillance en pause. Envoyez /start pour relancer."
                        }
                        '^/start$' {
                            $Sync.MonitoringActive = $true
                            Send-WorkerMsg -Text ("Surveillance reprise. Cible : " + $Sync.ChannelUrl)
                        }
                        '^/url\s+(https?://\S+)' {
                            $Sync.ChannelUrl = $Matches[1]
                            Get-Process -Name "yt-dlp" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                            Send-WorkerMsg -Text ("Cible mise a jour : " + $Sync.ChannelUrl)
                        }
                        '^/kill$' {
                            Send-WorkerMsg -Text "Arret force demande. Fermeture..."
                            $Sync.KillRequested = $true
                            Get-Process -Name "yt-dlp", "ffmpeg" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                            Stop-Process -Id $Sync.MainPID -Force
                        }
                    }
                }
            }
        } catch {}
        Start-Sleep -Milliseconds 800
    }
}

try {
    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.Open()
    $PowerShellInstance = [powershell]::Create()
    $PowerShellInstance.Runspace = $Runspace
    $null = $PowerShellInstance.AddScript($TelegramWorkerScript).AddArgument($SyncState)
    $AsyncResult = $PowerShellInstance.BeginInvoke()
} catch {
    Write-Host "[!] Erreur creation Runspace : $_" -ForegroundColor Red
    exit 1
}

# ==========================================
# Boucle Principale
# ==========================================
Write-Host "[*] CB_Recorder actif pour : $($SyncState.ChannelUrl)" -ForegroundColor Cyan
Write-Host "[*] Repertoire de stockage : $($SyncState.DestDir)" -ForegroundColor Cyan
Write-Host "[*] Ecouteur Telegram demarre." -ForegroundColor Green

$StartNotice = "Demon operationnel pour : " + $SyncState.ChannelUrl + "`nCommandes : /status, /disk, /snapshot, /stop, /start, /kill, /url <lien>"
Send-TelegramAlert -Message $StartNotice

while (-not $SyncState.KillRequested) {
    if ($SyncState.MonitoringActive) {
        $Date = Get-Date -Format "yyyyMMdd_HHmmss"

        $StreamUrl = (& yt-dlp -f "b/bv*+ba/best" -g --no-warnings $SyncState.ChannelUrl 2>$null | Where-Object { $_ -match "^https?://" } | Select-Object -First 1)

        if ($StreamUrl) {
            $SyncState.CurrentRecording = $true
            Write-Host "[!] Stream en direct detecte !" -ForegroundColor Magenta

            $LiveSnapshot = Join-Path $env:TEMP ("start_" + $Date + ".jpg")
            & ffmpeg -y -ss 00:00:01 -i $StreamUrl -frames:v 1 -q:v 2 $LiveSnapshot 2>$null

            $AlertStart = "Session live commencee pour " + $SyncState.ChannelUrl + " a " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            if (Test-Path $LiveSnapshot) {
                Send-TelegramPhoto -ImagePath $LiveSnapshot -Caption $AlertStart
                Remove-Item -Path $LiveSnapshot -Force
            } else {
                Send-TelegramAlert -Message $AlertStart
            }

            $MkvPattern = Join-Path $SyncState.DestDir ("raw_" + $Date + "_part%03d.mkv")

            & yt-dlp `
                -f "b/bv*+ba/best" `
                --downloader ffmpeg `
                --downloader-args "ffmpeg:-c copy -f segment -segment_time 3600 -reset_timestamps 1" `
                --no-part `
                --retries infinite `
                --fragment-retries infinite `
                --socket-timeout 30 `
                -o $MkvPattern `
                $SyncState.ChannelUrl

            $SyncState.CurrentRecording = $false

            # Transcodage post-session
            $RawFiles = Get-ChildItem -Path $SyncState.DestDir -Filter ("raw_" + $Date + "_part*.mkv")
            $TranscodedCount = 0

            foreach ($RawFile in $RawFiles) {
                if ($RawFile.Length -lt $SyncState.MinFileSize) {
                    $DiscardMB = [math]::Round($RawFile.Length / 1MB, 2)
                    Write-Host "[-] Fragment ignore ($DiscardMB Mo) : $($RawFile.Name)" -ForegroundColor DarkGray
                    Remove-Item -Path $RawFile.FullName -Force
                    continue
                }

                $FinalMp4Name = $RawFile.Name -replace "^raw_", "stream_" -replace "\.mkv$", ".mp4"
                $FinalMp4Path = Join-Path $SyncState.DestDir $FinalMp4Name

                Write-Host "[*] Transcodage : $($RawFile.Name) -> MP4..." -ForegroundColor Cyan

                & ffmpeg -y -i $RawFile.FullName -c:v copy -c:a aac -b:a 192k -af "aresample=async=1000" -movflags +faststart $FinalMp4Path 2>$null

                if (Test-Path $FinalMp4Path) {
                    $Mp4Item = Get-Item -Path $FinalMp4Path
                    $SizeMB  = [math]::Round($Mp4Item.Length / 1MB, 2)
                    Remove-Item -Path $RawFile.FullName -Force
                    $TranscodedCount++
                    Send-TelegramAlert -Message ("Segment finalise : " + $Mp4Item.Name + " (" + $SizeMB + " Mo)")
                }
            }
        } else {
            Write-Host "[-] Cible hors-ligne ($(Get-Date -Format 'HH:mm:ss'))..." -ForegroundColor DarkGray
        }
    }

    Start-Sleep -Seconds 15
}

$PowerShellInstance.Dispose()
$Runspace.Close()
$Runspace.Dispose()