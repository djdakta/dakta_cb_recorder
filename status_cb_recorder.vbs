Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")
Set colProcesses = objWMIService.ExecQuery("SELECT Name, CommandLine FROM Win32_Process")

isRecording = False
isMonitoring = False

For Each objProcess in colProcesses
    cmd = objProcess.CommandLine
    name = LCase(objProcess.Name)
    
    If Not IsNull(cmd) Then
        If InStr(cmd, "dakta_cb_recorder") > 0 Then
            isMonitoring = True
        End If
        If name = "ffmpeg.exe" And InStr(cmd, "raw_") > 0 Then
            isRecording = True
        End If
    End If
Next

Set shellApp = CreateObject("WScript.Shell")

If isRecording Then
    title = "CB_Recorder : EN COURS"
    msg = "Enregistrement en direct ACTIF (FFmpeg en cours d'ecriture)."
    icon = 64
ElseIf isMonitoring Then
    title = "CB_Recorder : EN VEILLE"
    msg = "Demon actif en arriere-plan, en attente de direct."
    icon = 64
Else
    title = "CB_Recorder : INACTIF"
    msg = "Le demon est arrete (aucun processus actif)."
    icon = 48
End If

shellApp.Popup msg, 4, title, icon
