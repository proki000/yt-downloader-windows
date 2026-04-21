Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ToolsDir = Join-Path $Script:AppRoot "tools"
$Script:YtDlpPath = Join-Path $Script:ToolsDir "yt-dlp.exe"
$Script:FfmpegBin = Join-Path $Script:ToolsDir "ffmpeg\bin"
$Script:FfmpegPath = Join-Path $Script:FfmpegBin "ffmpeg.exe"
$Script:ActiveProcess = $null
$Script:Busy = $false

function Get-DefaultVideoFolder {
    $folder = [Environment]::GetFolderPath("MyVideos")
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = Join-Path $env:USERPROFILE "Videos"
    }
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = $Script:AppRoot
    }
    return $folder
}

function Add-Log {
    param([string]$Message)

    if ($null -eq $Script:LogBox) { return }
    $line = "[{0}] {1}`r`n" -f (Get-Date -Format "HH:mm:ss"), $Message
    $Script:LogBox.AppendText($line)
    $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
    $Script:LogBox.ScrollToCaret()
}

function Add-RawLog {
    param([string]$Text)

    if ($null -eq $Script:LogBox -or [string]::IsNullOrEmpty($Text)) { return }
    $normalized = $Text -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    $normalized = $normalized -replace "`n", "`r`n"
    $Script:LogBox.AppendText($normalized)
    $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
    $Script:LogBox.ScrollToCaret()
}

function Set-Busy {
    param(
        [bool]$Busy,
        [string]$Status,
        [bool]$CanStop = $false
    )

    $Script:Busy = $Busy
    $Script:StatusLabel.Text = $Status
    $Script:DownloadButton.Enabled = -not $Busy
    $Script:ProbeButton.Enabled = -not $Busy
    $Script:ToolsButton.Enabled = -not $Busy
    $Script:BrowseButton.Enabled = -not $Busy
    $Script:OpenButton.Enabled = -not $Busy
    $Script:StopButton.Enabled = $Busy -and $CanStop

    if ($Busy) {
        $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    }
    else {
        $Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $Script:ProgressBar.Value = 0
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Test-RequiredTools {
    return ((Test-Path -LiteralPath $Script:YtDlpPath) -and (Test-Path -LiteralPath $Script:FfmpegPath))
}

function Update-ToolStatus {
    $yt = Test-Path -LiteralPath $Script:YtDlpPath
    $ff = Test-Path -LiteralPath $Script:FfmpegPath

    if ($yt -and $ff) {
        $Script:ToolStatusLabel.Text = "Tools: ready"
        $Script:ToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(34, 139, 70)
    }
    elseif ($yt) {
        $Script:ToolStatusLabel.Text = "Tools: ffmpeg missing"
        $Script:ToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 100, 30)
    }
    elseif ($ff) {
        $Script:ToolStatusLabel.Text = "Tools: yt-dlp missing"
        $Script:ToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 100, 30)
    }
    else {
        $Script:ToolStatusLabel.Text = "Tools: not installed"
        $Script:ToolStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 45, 45)
    }
}

function Confirm-Or-InstallTools {
    if (Test-RequiredTools) { return $true }

    $choice = [System.Windows.Forms.MessageBox]::Show(
        "This app needs yt-dlp and ffmpeg in its tools folder. Install them now?",
        "Install tools",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        Add-Log "Download cancelled because required tools are missing."
        return $false
    }

    Install-Tools
    return (Test-RequiredTools)
}

function Download-FileWithUi {
    param(
        [string]$Url,
        [string]$Destination
    )

    Add-Log ("Downloading {0}" -f $Url)
    $client = New-Object System.Net.WebClient
    $client.Headers.Add("User-Agent", "YT-Downloader-Windows")
    try {
        $task = $client.DownloadFileTaskAsync([Uri]$Url, $Destination)
        while (-not $task.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if ($task.IsFaulted) {
            throw $task.Exception.GetBaseException()
        }
        if ($task.IsCanceled) {
            throw "Download was cancelled."
        }
    }
    finally {
        $client.Dispose()
    }
}

function Download-FirstAvailableWithUi {
    param(
        [string[]]$Urls,
        [string]$Destination,
        [string]$Label
    )

    $lastError = $null
    for ($i = 0; $i -lt $Urls.Count; $i++) {
        try {
            Download-FileWithUi $Urls[$i] $Destination
            return
        }
        catch {
            $lastError = $_.Exception
            Add-Log ("{0} download source failed: {1}" -f $Label, $_.Exception.Message)
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            if ($i + 1 -lt $Urls.Count) {
                Add-Log ("Trying another {0} download source." -f $Label)
            }
        }
    }

    throw "All $Label download sources failed. Last error: $($lastError.Message)"
}

function Clear-SafeDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $toolsFull = [System.IO.Path]::GetFullPath($Script:ToolsDir)
    $targetFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $targetFull.StartsWith($toolsFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a folder outside the app tools directory: $targetFull"
    }

    if (Test-Path -LiteralPath $targetFull) {
        Remove-Item -LiteralPath $targetFull -Recurse -Force
    }
}

function Install-Tools {
    try {
        Set-Busy $true "Installing tools..."
        Add-Log "Installing/updating local tools."

        New-Item -ItemType Directory -Force -Path $Script:ToolsDir | Out-Null
        $tmpRoot = Join-Path $Script:ToolsDir "_tmp"
        Clear-SafeDirectory $tmpRoot
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

        $ytTemp = Join-Path $tmpRoot "yt-dlp.exe"
        Download-FileWithUi "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" $ytTemp
        Move-Item -LiteralPath $ytTemp -Destination $Script:YtDlpPath -Force
        Add-Log "yt-dlp installed."

        $ffZip = Join-Path $tmpRoot "ffmpeg.zip"
        $extractDir = Join-Path $tmpRoot "ffmpeg-extract"
        Download-FirstAvailableWithUi @(
            "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip",
            "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
        ) $ffZip "ffmpeg"
        Add-Log "Extracting ffmpeg. This can take a moment."
        Expand-Archive -LiteralPath $ffZip -DestinationPath $extractDir -Force

        $foundFfmpeg = Get-ChildItem -Path $extractDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
        if ($null -eq $foundFfmpeg) {
            throw "ffmpeg.exe was not found in the downloaded archive."
        }

        $sourceBin = $foundFfmpeg.Directory.FullName
        New-Item -ItemType Directory -Force -Path $Script:FfmpegBin | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceBin "ffmpeg.exe") -Destination $Script:FfmpegBin -Force
        $ffprobe = Join-Path $sourceBin "ffprobe.exe"
        if (Test-Path -LiteralPath $ffprobe) {
            Copy-Item -LiteralPath $ffprobe -Destination $Script:FfmpegBin -Force
        }

        Clear-SafeDirectory $tmpRoot
        Add-Log "ffmpeg installed."
        Add-Log "Tools are ready."
    }
    catch {
        Add-Log ("Tool install failed: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Tool install failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        Update-ToolStatus
        Set-Busy $false "Ready"
    }
}

function Quote-Argument {
    param([string]$Argument)

    if ($null -eq $Argument) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '"', '\"'
    return '"' + $escaped + '"'
}

function Join-ArgumentList {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object { Quote-Argument $_ }) -join " ")
}

function Read-NewText {
    param(
        [string]$Path,
        [ref]$Position
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $fs = $null
    $reader = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -lt [int64]$Position.Value) {
            $Position.Value = 0
        }
        $null = $fs.Seek([int64]$Position.Value, [System.IO.SeekOrigin]::Begin)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $reader = New-Object System.IO.StreamReader($fs, $encoding)
        $text = $reader.ReadToEnd()
        $Position.Value = $fs.Position
        if (-not [string]::IsNullOrEmpty($text)) {
            Add-RawLog $text
        }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $fs) { $fs.Dispose() }
    }
}

function Invoke-ExternalProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $argLine = Join-ArgumentList $Arguments

    Add-Log ("Starting {0}" -f ([System.IO.Path]::GetFileName($FilePath)))

    $process = New-Object System.Diagnostics.Process
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $argLine
    $startInfo.WorkingDirectory = $Script:AppRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $Script:ActiveProcess = $process
        Set-Busy $true "Working..." $true

        $stdoutReader = $process.StandardOutput
        $stderrReader = $process.StandardError
        $stdoutTask = $stdoutReader.ReadLineAsync()
        $stderrTask = $stderrReader.ReadLineAsync()
        $stdoutDone = $false
        $stderrDone = $false

        while ((-not $process.HasExited) -or (-not $stdoutDone) -or (-not $stderrDone)) {
            if ((-not $stdoutDone) -and $stdoutTask.IsCompleted) {
                $line = $null
                try {
                    $line = $stdoutTask.Result
                }
                catch {
                    Add-Log ("Output read failed: {0}" -f $_.Exception.Message)
                    $stdoutDone = $true
                }

                if ($null -eq $line) {
                    $stdoutDone = $true
                }
                elseif (-not $stdoutDone) {
                    Add-RawLog ($line + "`r`n")
                    $stdoutTask = $stdoutReader.ReadLineAsync()
                }
            }

            if ((-not $stderrDone) -and $stderrTask.IsCompleted) {
                $line = $null
                try {
                    $line = $stderrTask.Result
                }
                catch {
                    Add-Log ("Error stream read failed: {0}" -f $_.Exception.Message)
                    $stderrDone = $true
                }

                if ($null -eq $line) {
                    $stderrDone = $true
                }
                elseif (-not $stderrDone) {
                    Add-RawLog ($line + "`r`n")
                    $stderrTask = $stderrReader.ReadLineAsync()
                }
            }

            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }

        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        $Script:ActiveProcess = $null
        $process.Dispose()
    }
}

function Stop-ActiveProcess {
    if ($null -eq $Script:ActiveProcess) { return }

    try {
        if (-not $Script:ActiveProcess.HasExited) {
            Add-Log "Stopping current job..."
            & taskkill.exe /PID $Script:ActiveProcess.Id /T /F | Out-Null
        }
    }
    catch {
        Add-Log ("Stop failed: {0}" -f $_.Exception.Message)
    }
}

function Get-SelectedHeight {
    $text = [string]$Script:QualityBox.SelectedItem
    switch -Wildcard ($text) {
        "480p*" { return "480" }
        "720p*" { return "720" }
        "1080p*" { return "1080" }
        "1440p*" { return "1440" }
        default { return "best" }
    }
}

function Get-FormatSelector {
    param(
        [string]$Height,
        [string]$Container
    )

    if ($Container -eq "MP4") {
        if ($Height -eq "best") {
            return "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/best[ext=mp4]"
        }
        return "bv*[height<=$Height][ext=mp4]+ba[ext=m4a]/b[height<=$Height][ext=mp4]/best[height<=$Height][ext=mp4]"
    }

    if ($Height -eq "best") {
        return "bv*+ba/best"
    }
    return "bv*[height<=$Height]+ba/b[height<=$Height]/best[height<=$Height]"
}

function Get-ValidatedUrl {
    $url = $Script:UrlBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https?://') {
        [System.Windows.Forms.MessageBox]::Show(
            "Paste a valid YouTube URL first.",
            "Missing link",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $null
    }
    return $url
}

function Get-OutputFolder {
    $folder = $Script:FolderBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = Get-DefaultVideoFolder
        $Script:FolderBox.Text = $folder
    }

    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    return $folder
}

function Download-Video {
    if (-not (Confirm-Or-InstallTools)) { return }

    $url = Get-ValidatedUrl
    if ($null -eq $url) { return }

    try {
        $folder = Get-OutputFolder
        $height = Get-SelectedHeight
        $container = [string]$Script:ContainerBox.SelectedItem
        $selector = Get-FormatSelector $height $container
        $extension = $container.ToLowerInvariant()
        $outputTemplate = Join-Path $folder ("%(title).180B [%(id)s].%(ext)s")

        $args = @(
            "--newline",
            "--windows-filenames",
            "--no-mtime",
            "--ffmpeg-location", $Script:FfmpegBin,
            "-f", $selector,
            "--merge-output-format", $extension,
            "-o", $outputTemplate
        )

        if (-not $Script:PlaylistBox.Checked) {
            $args += "--no-playlist"
        }

        $args += $url

        Add-Log ("Saving to {0}" -f $folder)
        Add-Log ("Quality: {0}, container: {1}" -f $Script:QualityBox.SelectedItem, $container)
        $exit = Invoke-ExternalProcess $Script:YtDlpPath $args

        if ($exit -eq 0) {
            Add-Log "Download finished."
            Set-Busy $false "Ready"
        }
        else {
            Add-Log ("Download failed with exit code {0}." -f $exit)
            Set-Busy $false "Failed"
        }
    }
    catch {
        Add-Log ("Download failed: {0}" -f $_.Exception.Message)
        Set-Busy $false "Failed"
    }
    finally {
        Update-ToolStatus
    }
}

function Check-Qualities {
    if (-not (Confirm-Or-InstallTools)) { return }

    $url = Get-ValidatedUrl
    if ($null -eq $url) { return }

    try {
        $args = @("-F")
        if (-not $Script:PlaylistBox.Checked) {
            $args += "--no-playlist"
        }
        $args += $url

        Add-Log "Checking available qualities."
        $exit = Invoke-ExternalProcess $Script:YtDlpPath $args
        if ($exit -eq 0) {
            Add-Log "Quality check finished."
            Set-Busy $false "Ready"
        }
        else {
            Add-Log ("Quality check failed with exit code {0}." -f $exit)
            Set-Busy $false "Failed"
        }
    }
    catch {
        Add-Log ("Quality check failed: {0}" -f $_.Exception.Message)
        Set-Busy $false "Failed"
    }
    finally {
        Update-ToolStatus
    }
}

function Browse-Folder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose download folder"
    $dialog.SelectedPath = $Script:FolderBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Script:FolderBox.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
}

function Open-DownloadFolder {
    try {
        $folder = Get-OutputFolder
        Start-Process -FilePath $folder
    }
    catch {
        Add-Log ("Could not open folder: {0}" -f $_.Exception.Message)
    }
}

$Script:Form = New-Object System.Windows.Forms.Form
$Script:Form.Text = "YT Downloader"
$Script:Form.StartPosition = "CenterScreen"
$Script:Form.Size = New-Object System.Drawing.Size(860, 640)
$Script:Form.MinimumSize = New-Object System.Drawing.Size(760, 560)
$Script:Form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$Script:Form.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "YT Downloader"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(20, 16)
$Script:Form.Controls.Add($titleLabel)

$legalLabel = New-Object System.Windows.Forms.Label
$legalLabel.Text = "Only download videos you own, have permission to save, or that are legally reusable."
$legalLabel.AutoSize = $true
$legalLabel.ForeColor = [System.Drawing.Color]::FromArgb(95, 95, 95)
$legalLabel.Location = New-Object System.Drawing.Point(24, 54)
$Script:Form.Controls.Add($legalLabel)

$urlLabel = New-Object System.Windows.Forms.Label
$urlLabel.Text = "Video link"
$urlLabel.AutoSize = $true
$urlLabel.Location = New-Object System.Drawing.Point(24, 92)
$Script:Form.Controls.Add($urlLabel)

$Script:UrlBox = New-Object System.Windows.Forms.TextBox
$Script:UrlBox.Anchor = "Top, Left, Right"
$Script:UrlBox.Location = New-Object System.Drawing.Point(24, 114)
$Script:UrlBox.Size = New-Object System.Drawing.Size(804, 24)
$Script:Form.Controls.Add($Script:UrlBox)

$qualityLabel = New-Object System.Windows.Forms.Label
$qualityLabel.Text = "Quality"
$qualityLabel.AutoSize = $true
$qualityLabel.Location = New-Object System.Drawing.Point(24, 154)
$Script:Form.Controls.Add($qualityLabel)

$Script:QualityBox = New-Object System.Windows.Forms.ComboBox
$Script:QualityBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$Script:QualityBox.Location = New-Object System.Drawing.Point(24, 176)
$Script:QualityBox.Size = New-Object System.Drawing.Size(160, 24)
[void]$Script:QualityBox.Items.Add("480p")
[void]$Script:QualityBox.Items.Add("720p")
[void]$Script:QualityBox.Items.Add("1080p")
[void]$Script:QualityBox.Items.Add("1440p (2K)")
[void]$Script:QualityBox.Items.Add("Best available")
$Script:QualityBox.SelectedIndex = 2
$Script:Form.Controls.Add($Script:QualityBox)

$containerLabel = New-Object System.Windows.Forms.Label
$containerLabel.Text = "Container"
$containerLabel.AutoSize = $true
$containerLabel.Location = New-Object System.Drawing.Point(204, 154)
$Script:Form.Controls.Add($containerLabel)

$Script:ContainerBox = New-Object System.Windows.Forms.ComboBox
$Script:ContainerBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$Script:ContainerBox.Location = New-Object System.Drawing.Point(204, 176)
$Script:ContainerBox.Size = New-Object System.Drawing.Size(140, 24)
[void]$Script:ContainerBox.Items.Add("MP4")
[void]$Script:ContainerBox.Items.Add("MKV")
$Script:ContainerBox.SelectedIndex = 0
$Script:Form.Controls.Add($Script:ContainerBox)

$Script:PlaylistBox = New-Object System.Windows.Forms.CheckBox
$Script:PlaylistBox.Text = "Playlist mode"
$Script:PlaylistBox.AutoSize = $true
$Script:PlaylistBox.Location = New-Object System.Drawing.Point(364, 178)
$Script:Form.Controls.Add($Script:PlaylistBox)

$Script:ToolStatusLabel = New-Object System.Windows.Forms.Label
$Script:ToolStatusLabel.AutoSize = $true
$Script:ToolStatusLabel.Location = New-Object System.Drawing.Point(486, 181)
$Script:Form.Controls.Add($Script:ToolStatusLabel)

$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Text = "Save to"
$folderLabel.AutoSize = $true
$folderLabel.Location = New-Object System.Drawing.Point(24, 218)
$Script:Form.Controls.Add($folderLabel)

$Script:FolderBox = New-Object System.Windows.Forms.TextBox
$Script:FolderBox.Anchor = "Top, Left, Right"
$Script:FolderBox.Location = New-Object System.Drawing.Point(24, 240)
$Script:FolderBox.Size = New-Object System.Drawing.Size(684, 24)
$Script:FolderBox.Text = Get-DefaultVideoFolder
$Script:Form.Controls.Add($Script:FolderBox)

$Script:BrowseButton = New-Object System.Windows.Forms.Button
$Script:BrowseButton.Anchor = "Top, Right"
$Script:BrowseButton.Text = "Browse"
$Script:BrowseButton.Location = New-Object System.Drawing.Point(718, 238)
$Script:BrowseButton.Size = New-Object System.Drawing.Size(110, 28)
$Script:BrowseButton.Add_Click({ Browse-Folder })
$Script:Form.Controls.Add($Script:BrowseButton)

$buttonTop = 286
$Script:ToolsButton = New-Object System.Windows.Forms.Button
$Script:ToolsButton.Text = "Install / Update Tools"
$Script:ToolsButton.Location = New-Object System.Drawing.Point(24, $buttonTop)
$Script:ToolsButton.Size = New-Object System.Drawing.Size(150, 34)
$Script:ToolsButton.Add_Click({ Install-Tools })
$Script:Form.Controls.Add($Script:ToolsButton)

$Script:ProbeButton = New-Object System.Windows.Forms.Button
$Script:ProbeButton.Text = "Check Qualities"
$Script:ProbeButton.Location = New-Object System.Drawing.Point(186, $buttonTop)
$Script:ProbeButton.Size = New-Object System.Drawing.Size(126, 34)
$Script:ProbeButton.Add_Click({ Check-Qualities })
$Script:Form.Controls.Add($Script:ProbeButton)

$Script:DownloadButton = New-Object System.Windows.Forms.Button
$Script:DownloadButton.Text = "Download"
$Script:DownloadButton.Location = New-Object System.Drawing.Point(324, $buttonTop)
$Script:DownloadButton.Size = New-Object System.Drawing.Size(110, 34)
$Script:DownloadButton.BackColor = [System.Drawing.Color]::FromArgb(35, 105, 220)
$Script:DownloadButton.ForeColor = [System.Drawing.Color]::White
$Script:DownloadButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$Script:DownloadButton.Add_Click({ Download-Video })
$Script:Form.Controls.Add($Script:DownloadButton)

$Script:StopButton = New-Object System.Windows.Forms.Button
$Script:StopButton.Text = "Stop"
$Script:StopButton.Location = New-Object System.Drawing.Point(446, $buttonTop)
$Script:StopButton.Size = New-Object System.Drawing.Size(90, 34)
$Script:StopButton.Enabled = $false
$Script:StopButton.Add_Click({ Stop-ActiveProcess })
$Script:Form.Controls.Add($Script:StopButton)

$Script:OpenButton = New-Object System.Windows.Forms.Button
$Script:OpenButton.Text = "Open Folder"
$Script:OpenButton.Location = New-Object System.Drawing.Point(548, $buttonTop)
$Script:OpenButton.Size = New-Object System.Drawing.Size(110, 34)
$Script:OpenButton.Add_Click({ Open-DownloadFolder })
$Script:Form.Controls.Add($Script:OpenButton)

$Script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
$Script:ProgressBar.Anchor = "Top, Left, Right"
$Script:ProgressBar.Location = New-Object System.Drawing.Point(24, 336)
$Script:ProgressBar.Size = New-Object System.Drawing.Size(804, 12)
$Script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
$Script:Form.Controls.Add($Script:ProgressBar)

$Script:StatusLabel = New-Object System.Windows.Forms.Label
$Script:StatusLabel.Text = "Ready"
$Script:StatusLabel.AutoSize = $true
$Script:StatusLabel.Location = New-Object System.Drawing.Point(24, 356)
$Script:Form.Controls.Add($Script:StatusLabel)

$Script:LogBox = New-Object System.Windows.Forms.TextBox
$Script:LogBox.Anchor = "Top, Bottom, Left, Right"
$Script:LogBox.Location = New-Object System.Drawing.Point(24, 382)
$Script:LogBox.Size = New-Object System.Drawing.Size(804, 196)
$Script:LogBox.Multiline = $true
$Script:LogBox.ReadOnly = $true
$Script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$Script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 30)
$Script:LogBox.ForeColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
$Script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$Script:Form.Controls.Add($Script:LogBox)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($Script:ToolsButton, "Download or update yt-dlp and ffmpeg inside this app folder.")
$tip.SetToolTip($Script:ProbeButton, "Show formats that are available for the pasted link.")
$tip.SetToolTip($Script:DownloadButton, "Download the selected link using the chosen quality.")
$tip.SetToolTip($Script:StopButton, "Stop the active download.")
$tip.SetToolTip($Script:OpenButton, "Open the selected download folder.")

$Script:Form.Add_FormClosing({
    param($sender, $eventArgs)

    if ($Script:Busy -and $null -ne $Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "A download is still running. Stop it and close?",
            "Download running",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Stop-ActiveProcess
        }
        else {
            $eventArgs.Cancel = $true
        }
    }
})

Update-ToolStatus
Add-Log "Ready. Paste a link, choose a quality, and click Download."

[void]$Script:Form.ShowDialog()
