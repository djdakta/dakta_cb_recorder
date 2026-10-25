# ==========================================
# Configuration
# ==========================================
$ChannelUrl       = "https://chaturbate.com/claudiarivera_1/"
$DestDir          = "D:\Vidz\CB_Recorder"
$MinFileSize      = 10MB

# Identifiants Telegram
$TelegramBotToken = "TG_TOKEN"
$TelegramChatId   = "TG_CHAT_ID"

# En-têtes HTTP pour éviter les erreurs 403 du CDN
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
$Referer   = "https://chaturbate.com/"

if (!(Test-Path -Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

# ==========================================
# Fonctions d'envoi Telegram (Unidirectionnel)
# ==========================================
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Send-TelegramAlert {
    param ([string]$Message)
    $Uri = "https://api.telegram.org/bot" + $TelegramBotToken + "/sendMessage"
    $Payload = @{
        chat_id                  = $TelegramChatId
        text                     = $Message
        parse_mode               = "HTML"
        disable_web_page_preview = $true
    } | ConvertTo-Json

    try {
        $null = Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json; charset=utf-8" -Body $Payload -ErrorAction Stop
    } catch {
        Write-Host "[-] Erreur Telegram Message : $($_.Exception.Message)" -ForegroundColor Red
    }
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
            $Content.Add((New-Object System.Net.Http.StringContent("HTML")), "parse_mode")
        }

        $FileStream = [System.IO.File]::OpenRead($ImagePath)
        $Content.Add((New-Object System.Net.Http.StreamContent($FileStream)), "photo", [System.IO.Path]::GetFileName($ImagePath))

        $Response = $HttpClient.PostAsync($Uri, $Content).Result
        if (-not $Response.IsSuccessStatusCode) {
            Write-Host "[-] Erreur Telegram Photo : $($Response.StatusCode) - $($Response.ReasonPhrase)" -ForegroundColor Red
        }
        $FileStream.Close()
        $HttpClient.Dispose()
    } catch {
        Write-Host "[-] Exception Telegram Photo : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ==========================================
# Boucle Principale
# ==========================================
Write-Host "[*] CB_Recorder initialise pour : $ChannelUrl" -ForegroundColor Cyan
Write-Host "[*] Repertoire de stockage      : $DestDir" -ForegroundColor Cyan

Send-TelegramAlert -Message ("*CB_Recorder demarre*`n`nSurveillance active pour : $ChannelUrl")

while ($true) {
    $Date = Get-Date -Format "yyyyMMdd_HHmmss"
    Write-Host "[-] Verification du flux en direct ($(Get-Date -Format 'HH:mm:ss'))..." -ForegroundColor DarkGray

    # Resolution des flux video et audio
    $Urls = @(& yt-dlp -f "b/bv*+ba/best" -g --no-warnings $ChannelUrl 2>$null | Where-Object { $_ -match "^https?://" })

    if ($Urls.Count -gt 0) {
        $VideoUrl = $Urls[0]
        $AudioUrl = if ($Urls.Count -gt 1) { $Urls[1] } else { $null }

        Write-Host "[!] Stream live detecte ! Extraction du snapshot..." -ForegroundColor Magenta

        # 1. Snapshot immediat envoye a Telegram
        $LiveSnapshot = Join-Path $env:TEMP ("snap_" + $Date + ".jpg")
        & ffmpeg -y -user_agent $UserAgent -referer $Referer -ss 00:00:01 -i $VideoUrl -frames:v 1 -q:v 2 $LiveSnapshot 2>$null

        $AlertStart = "🔴 <b>Live demarre !</b>`n`n<b>Cible :</b> $ChannelUrl`n<b>Debut :</b> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n<b>Decoupage :</b> Blocs de 60 min"
        if (Test-Path $LiveSnapshot) {
            Send-TelegramPhoto -ImagePath $LiveSnapshot -Caption $AlertStart
            Remove-Item -Path $LiveSnapshot -Force
        } else {
            Send-TelegramAlert -Message $AlertStart
        }

        # 2. Enregistrement direct via FFmpeg (synchrone et stable)
        $SegmentPattern = Join-Path $DestDir ("raw_" + $Date + "_part%03d.mkv")
        Write-Host "[*] Demarrage de l'enregistrement..." -ForegroundColor Cyan

        if ($AudioUrl) {
            & ffmpeg -y `
                -user_agent $UserAgent -referer $Referer -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 10000000 -i $VideoUrl `
                -user_agent $UserAgent -referer $Referer -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 10000000 -i $AudioUrl `
                -map 0:v:0 -map 1:a:0 `
                -c copy `
                -f segment `
                -segment_time 3600 `
                -reset_timestamps 1 `
                $SegmentPattern
        } else {
            & ffmpeg -y `
                -user_agent $UserAgent -referer $Referer -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -timeout 10000000 -i $VideoUrl `
                -c copy `
                -f segment `
                -segment_time 3600 `
                -reset_timestamps 1 `
                $SegmentPattern
        }

        Write-Host "[+] Session live terminee. Debut du transcodage..." -ForegroundColor Magenta

        # 3. Transcodage MP4, calage audio et notification finale
        $RawFiles = Get-ChildItem -Path $DestDir -Filter ("raw_" + $Date + "_part*.mkv")
        foreach ($RawFile in $RawFiles) {
            if ($RawFile.Length -lt $MinFileSize) {
                Write-Host "[-] Fragment ignore car trop court : $($RawFile.Name)" -ForegroundColor DarkGray
                Remove-Item -Path $RawFile.FullName -Force
                continue
            }

            $FinalMp4Name = $RawFile.Name -replace "^raw_", "stream_" -replace "\.mkv$", ".mp4"
            $FinalMp4Path = Join-Path $DestDir $FinalMp4Name

            Write-Host "[*] Transcodage : $($RawFile.Name) -> MP4..." -ForegroundColor Cyan
            & ffmpeg -y -i $RawFile.FullName -c:v copy -c:a aac -b:a 192k -af "aresample=async=1000" -movflags +faststart $FinalMp4Path 2>$null

            if (Test-Path $FinalMp4Path) {
                $Mp4Item = Get-Item -Path $FinalMp4Path
                $SizeMB  = [math]::Round($Mp4Item.Length / 1MB, 2)
                Remove-Item -Path $RawFile.FullName -Force
                Send-TelegramAlert -Message ("🎬 *Segment pret :* " + $Mp4Item.Name + " (" + $SizeMB + " Mo)")
            }
        }
    }

    Start-Sleep -Seconds 15
}
