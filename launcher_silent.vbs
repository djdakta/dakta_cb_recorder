Set objShell = CreateObject("WScript.Shell")
strCommand = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\Users\djdak\Documents\CB_Recorder\dakta_cb_recorder_telegram_60_min_v8.1.ps1"""
objShell.Run strCommand, 0, False