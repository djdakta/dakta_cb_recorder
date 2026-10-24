# Configuration
$ChannelUrl  = "https://chaturbate.com/calimerrsa/"
$DestDir     = "D:\Vidz\CB_Recorder"
$MinFileSize = 10MB # Ignore les captures avortées de moins de 10 Mo

if (!(Test-Path -Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

Write-Host "[*] Surveillance active pour : $ChannelUrl" -ForegroundColor Cyan
Write-Host "[*] Destination : $DestDir" -ForegroundColor Cyan

while ($true) {$Date = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputFile = Join-Path $DestDir "stream_$Date.mkv"

    # Capture HLS avec calage d'horodatage audio
    yt-dlp `
        -f "bv*+ba/b" `
        --remux-video mkv `
        --postprocessor-args "ffmpeg:-af aresample=async=1000" `
        --no-part `
        --retries infinite `
        --fragment-retries infinite `
        -o $OutputFile `
        $ChannelUrl

    # Vérification post-capture : nettoyage des fichiers résiduels ou trop courts
    if (Test-Path -Path $OutputFile) {
        $Item = Get-Item -Path$OutputFile
        if ($Item.Length -lt$MinFileSize) {
            Write-Host "[-] Fichier trop court ($([math]::Round($Item.Length / 1MB, 2)) Mo), suppression..." -ForegroundColor DarkGray
            Remove-Item -Path $OutputFile -Force
        } else {
            Write-Host "[+] Session enregistrée : $($Item.Name) ($([math]::Round($Item.Length / 1MB, 2)) Mo)" -ForegroundColor Green
        }
    }

    # Pause de 15 secondes avant la prochaine interrogation
    Start-Sleep -Seconds 15
}