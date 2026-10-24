$Source = "Sara_pvt_20240628.mp4"

$Scenes = @(
    @{ Start = "00:09:53"; End = "00:11:06"; Name = "Sara_pvt_20240628_fingering_doggy_1.mp4" },
    @{ Start = "00:11:11"; End = "00:12:40"; Name = "Sara_pvt_20240628_fingering_standing_2.mp4" },
	@{ Start = "00:12:57"; End = "00:14:11"; Name = "Sara_pvt_20240628_dildo_standing_3.mp4" },
	@{ Start = "00:15:00"; End = "00:17:20"; Name = "Sara_pvt_20240628_dildo_chair_4.mp4" },
	@{ Start = "00:17:20"; End = "00:19:46"; Name = "Sara_pvt_20240628_creamy_fingering_5.mp4" },
	@{ Start = "00:19:47"; End = "00:22:15"; Name = "Sara_pvt_20240628_squirt_6.mp4" },
	@{ Start = "00:32:01"; End = "00:35:42"; Name = "Sara_pvt_20240628_SF_7.mp4" },
	@{ Start = "00:39:55"; End = "00:42:49"; Name = "Sara_pvt_20240628_dildo_lush_8.mp4" },	
    @{ Start = "00:47:40"; End = "00:54:10"; Name = "Sara_pvt_20240628_BJ_9.mp4" }
)

foreach ($s in $Scenes) {
    Write-Host "[*] Extraction de $($s.Name)..." -ForegroundColor Cyan
    ffmpeg -ss $s.Start -to $s.End -i $Source -c copy -movflags +faststart $s.Name
}