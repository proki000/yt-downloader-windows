# YT Downloader Windows

A small Windows desktop app for downloading videos you own, have permission to save, or that are legally reusable.

The app provides:

- A normal Windows `.exe` GUI with no terminal window.
- URL paste box, download folder picker, and progress log.
- Quality choices: `480p`, `720p`, `1080p`, `1440p (2K)`, and best available.
- Output container choices: `MP4` and `MKV`.
- Built-in buttons to install or update `yt-dlp` and `ffmpeg` into a local `tools/` folder.
- Multiple `ffmpeg` download sources, so one mirror failing does not stop setup.

## Download

Download the latest Windows build from [GitHub Releases](https://github.com/proki000/yt-downloader-windows/releases/latest).

1. Download `YT-Downloader-Windows.zip`.
2. Extract the zip file.
3. Run `YT Downloader.exe`.
4. Click `Install / Update Tools` the first time you open it.

## Important

Use this app only for videos you own, have permission to download, or that are legally reusable. It does not bypass DRM, paid, private, or login-only restrictions.

## Build From Source

This project uses the Windows .NET Framework compiler that ships with many Windows installs.

```powershell
.\Build.ps1
```

The build creates:

```text
YT Downloader.exe
```

## Files

- `YTDownloaderApp.cs` - native WinForms app source.
- `YTDownloader.ps1` - older PowerShell fallback GUI.
- `Start-YouTube-Downloader.cmd` - fallback launcher for the PowerShell version.
- `Build.ps1` - builds the C# app into `YT Downloader.exe`.
