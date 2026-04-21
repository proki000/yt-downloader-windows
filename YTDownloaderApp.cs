using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace YTDownloaderWindows
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly string appRoot;
        private readonly string toolsDir;
        private readonly string ytDlpPath;
        private readonly string ffmpegBin;
        private readonly string ffmpegPath;

        private TextBox urlBox;
        private TextBox folderBox;
        private TextBox logBox;
        private ComboBox qualityBox;
        private ComboBox containerBox;
        private CheckBox playlistBox;
        private Label toolStatusLabel;
        private Label statusLabel;
        private ProgressBar progressBar;
        private Button toolsButton;
        private Button probeButton;
        private Button downloadButton;
        private Button stopButton;
        private Button browseButton;
        private Button openButton;

        private volatile bool busy;
        private Process activeProcess;
        private readonly object processLock = new object();

        public MainForm()
        {
            appRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            toolsDir = Path.Combine(appRoot, "tools");
            ytDlpPath = Path.Combine(toolsDir, "yt-dlp.exe");
            ffmpegBin = Path.Combine(toolsDir, "ffmpeg", "bin");
            ffmpegPath = Path.Combine(ffmpegBin, "ffmpeg.exe");

            BuildUi();
            UpdateToolStatus();
            AddLog("Ready. Paste a link, choose a quality, and click Download.");
        }

        private void BuildUi()
        {
            Text = "YT Downloader";
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(860, 640);
            MinimumSize = new Size(760, 560);
            Font = new Font("Segoe UI", 9f);
            BackColor = Color.FromArgb(247, 248, 250);

            Label titleLabel = new Label();
            titleLabel.Text = "YT Downloader";
            titleLabel.Font = new Font("Segoe UI Semibold", 18f);
            titleLabel.AutoSize = true;
            titleLabel.Location = new Point(20, 16);
            Controls.Add(titleLabel);

            Label legalLabel = new Label();
            legalLabel.Text = "Only download videos you own, have permission to save, or that are legally reusable.";
            legalLabel.AutoSize = true;
            legalLabel.ForeColor = Color.FromArgb(95, 95, 95);
            legalLabel.Location = new Point(24, 54);
            Controls.Add(legalLabel);

            Label urlLabel = new Label();
            urlLabel.Text = "Video link";
            urlLabel.AutoSize = true;
            urlLabel.Location = new Point(24, 92);
            Controls.Add(urlLabel);

            urlBox = new TextBox();
            urlBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            urlBox.Location = new Point(24, 114);
            urlBox.Size = new Size(804, 24);
            Controls.Add(urlBox);

            Label qualityLabel = new Label();
            qualityLabel.Text = "Quality";
            qualityLabel.AutoSize = true;
            qualityLabel.Location = new Point(24, 154);
            Controls.Add(qualityLabel);

            qualityBox = new ComboBox();
            qualityBox.DropDownStyle = ComboBoxStyle.DropDownList;
            qualityBox.Location = new Point(24, 176);
            qualityBox.Size = new Size(160, 24);
            qualityBox.Items.Add("480p");
            qualityBox.Items.Add("720p");
            qualityBox.Items.Add("1080p");
            qualityBox.Items.Add("1440p (2K)");
            qualityBox.Items.Add("Best available");
            qualityBox.SelectedIndex = 2;
            Controls.Add(qualityBox);

            Label containerLabel = new Label();
            containerLabel.Text = "Container";
            containerLabel.AutoSize = true;
            containerLabel.Location = new Point(204, 154);
            Controls.Add(containerLabel);

            containerBox = new ComboBox();
            containerBox.DropDownStyle = ComboBoxStyle.DropDownList;
            containerBox.Location = new Point(204, 176);
            containerBox.Size = new Size(140, 24);
            containerBox.Items.Add("MP4");
            containerBox.Items.Add("MKV");
            containerBox.SelectedIndex = 0;
            Controls.Add(containerBox);

            playlistBox = new CheckBox();
            playlistBox.Text = "Playlist mode";
            playlistBox.AutoSize = true;
            playlistBox.Location = new Point(364, 178);
            Controls.Add(playlistBox);

            toolStatusLabel = new Label();
            toolStatusLabel.AutoSize = true;
            toolStatusLabel.Location = new Point(486, 181);
            Controls.Add(toolStatusLabel);

            Label folderLabel = new Label();
            folderLabel.Text = "Save to";
            folderLabel.AutoSize = true;
            folderLabel.Location = new Point(24, 218);
            Controls.Add(folderLabel);

            folderBox = new TextBox();
            folderBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            folderBox.Location = new Point(24, 240);
            folderBox.Size = new Size(684, 24);
            folderBox.Text = GetDefaultVideoFolder();
            Controls.Add(folderBox);

            browseButton = new Button();
            browseButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            browseButton.Text = "Browse";
            browseButton.Location = new Point(718, 238);
            browseButton.Size = new Size(110, 28);
            browseButton.Click += delegate { BrowseFolder(); };
            Controls.Add(browseButton);

            int buttonTop = 286;
            toolsButton = new Button();
            toolsButton.Text = "Install / Update Tools";
            toolsButton.Location = new Point(24, buttonTop);
            toolsButton.Size = new Size(150, 34);
            toolsButton.Click += delegate { StartToolInstall(); };
            Controls.Add(toolsButton);

            probeButton = new Button();
            probeButton.Text = "Check Qualities";
            probeButton.Location = new Point(186, buttonTop);
            probeButton.Size = new Size(126, 34);
            probeButton.Click += delegate { StartQualityCheck(); };
            Controls.Add(probeButton);

            downloadButton = new Button();
            downloadButton.Text = "Download";
            downloadButton.Location = new Point(324, buttonTop);
            downloadButton.Size = new Size(110, 34);
            downloadButton.BackColor = Color.FromArgb(35, 105, 220);
            downloadButton.ForeColor = Color.White;
            downloadButton.FlatStyle = FlatStyle.Flat;
            downloadButton.Click += delegate { StartDownload(); };
            Controls.Add(downloadButton);

            stopButton = new Button();
            stopButton.Text = "Stop";
            stopButton.Location = new Point(446, buttonTop);
            stopButton.Size = new Size(90, 34);
            stopButton.Enabled = false;
            stopButton.Click += delegate { StopActiveProcess(); };
            Controls.Add(stopButton);

            openButton = new Button();
            openButton.Text = "Open Folder";
            openButton.Location = new Point(548, buttonTop);
            openButton.Size = new Size(110, 34);
            openButton.Click += delegate { OpenDownloadFolder(); };
            Controls.Add(openButton);

            progressBar = new ProgressBar();
            progressBar.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            progressBar.Location = new Point(24, 336);
            progressBar.Size = new Size(804, 12);
            progressBar.Style = ProgressBarStyle.Blocks;
            Controls.Add(progressBar);

            statusLabel = new Label();
            statusLabel.Text = "Ready";
            statusLabel.AutoSize = true;
            statusLabel.Location = new Point(24, 356);
            Controls.Add(statusLabel);

            logBox = new TextBox();
            logBox.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            logBox.Location = new Point(24, 382);
            logBox.Size = new Size(804, 196);
            logBox.Multiline = true;
            logBox.ReadOnly = true;
            logBox.ScrollBars = ScrollBars.Vertical;
            logBox.BackColor = Color.FromArgb(24, 26, 30);
            logBox.ForeColor = Color.FromArgb(235, 235, 235);
            logBox.Font = new Font("Consolas", 9f);
            Controls.Add(logBox);

            ToolTip tip = new ToolTip();
            tip.SetToolTip(toolsButton, "Download or update yt-dlp and ffmpeg inside this app folder.");
            tip.SetToolTip(probeButton, "Show formats that are available for the pasted link.");
            tip.SetToolTip(downloadButton, "Download the selected link using the chosen quality.");
            tip.SetToolTip(stopButton, "Stop the active download.");
            tip.SetToolTip(openButton, "Open the selected download folder.");

            FormClosing += OnFormClosing;
        }

        private string GetDefaultVideoFolder()
        {
            string folder = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            if (string.IsNullOrWhiteSpace(folder))
            {
                folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Videos");
            }
            if (string.IsNullOrWhiteSpace(folder))
            {
                folder = appRoot;
            }
            return folder;
        }

        private void AddLog(string message)
        {
            AddRawLog(string.Format("[{0}] {1}{2}", DateTime.Now.ToString("HH:mm:ss"), message, Environment.NewLine));
        }

        private void AddRawLog(string text)
        {
            if (IsDisposed || string.IsNullOrEmpty(text))
            {
                return;
            }

            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AddRawLog), text);
                return;
            }

            logBox.AppendText(text.Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "\r\n"));
            logBox.SelectionStart = logBox.TextLength;
            logBox.ScrollToCaret();
        }

        private void SetBusy(bool value, string status, bool canStop)
        {
            if (IsDisposed)
            {
                return;
            }

            if (InvokeRequired)
            {
                BeginInvoke(new Action<bool, string, bool>(SetBusy), value, status, canStop);
                return;
            }

            busy = value;
            statusLabel.Text = status;
            downloadButton.Enabled = !value;
            probeButton.Enabled = !value;
            toolsButton.Enabled = !value;
            browseButton.Enabled = !value;
            openButton.Enabled = !value;
            stopButton.Enabled = value && canStop;
            progressBar.Style = value ? ProgressBarStyle.Marquee : ProgressBarStyle.Blocks;
            if (!value)
            {
                progressBar.Value = 0;
            }
        }

        private bool TestRequiredTools()
        {
            return File.Exists(ytDlpPath) && File.Exists(ffmpegPath);
        }

        private void UpdateToolStatus()
        {
            if (IsDisposed)
            {
                return;
            }

            if (InvokeRequired)
            {
                BeginInvoke(new Action(UpdateToolStatus));
                return;
            }

            bool yt = File.Exists(ytDlpPath);
            bool ff = File.Exists(ffmpegPath);

            if (yt && ff)
            {
                toolStatusLabel.Text = "Tools: ready";
                toolStatusLabel.ForeColor = Color.FromArgb(34, 139, 70);
            }
            else if (yt)
            {
                toolStatusLabel.Text = "Tools: ffmpeg missing";
                toolStatusLabel.ForeColor = Color.FromArgb(190, 100, 30);
            }
            else if (ff)
            {
                toolStatusLabel.Text = "Tools: yt-dlp missing";
                toolStatusLabel.ForeColor = Color.FromArgb(190, 100, 30);
            }
            else
            {
                toolStatusLabel.Text = "Tools: not installed";
                toolStatusLabel.ForeColor = Color.FromArgb(180, 45, 45);
            }
        }

        private void StartToolInstall()
        {
            if (busy)
            {
                return;
            }

            SetBusy(true, "Installing tools...", false);
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    InstallToolsWorker();
                    AddLog("Tools are ready.");
                    SetBusy(false, "Ready", false);
                }
                catch (Exception ex)
                {
                    AddLog("Tool install failed: " + ex.Message);
                    ShowError("Tool install failed", ex.Message);
                    SetBusy(false, "Failed", false);
                }
                finally
                {
                    UpdateToolStatus();
                }
            });
        }

        private void InstallToolsWorker()
        {
            Directory.CreateDirectory(toolsDir);
            string tmpRoot = Path.Combine(toolsDir, "_tmp");
            ClearSafeDirectory(tmpRoot);
            Directory.CreateDirectory(tmpRoot);

            try
            {
                AddLog("Installing/updating local tools.");

                string ytTemp = Path.Combine(tmpRoot, "yt-dlp.exe");
                DownloadFile("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", ytTemp);
                File.Copy(ytTemp, ytDlpPath, true);
                AddLog("yt-dlp installed.");

                string ffZip = Path.Combine(tmpRoot, "ffmpeg.zip");
                string extractDir = Path.Combine(tmpRoot, "ffmpeg-extract");
                DownloadFirstAvailable(
                    new string[]
                    {
                        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip",
                        "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
                    },
                    ffZip,
                    "ffmpeg");
                AddLog("Extracting ffmpeg. This can take a moment.");
                ZipFile.ExtractToDirectory(ffZip, extractDir);

                string[] found = Directory.GetFiles(extractDir, "ffmpeg.exe", SearchOption.AllDirectories);
                if (found.Length == 0)
                {
                    throw new InvalidOperationException("ffmpeg.exe was not found in the downloaded archive.");
                }

                string sourceBin = Path.GetDirectoryName(found[0]);
                Directory.CreateDirectory(ffmpegBin);
                File.Copy(Path.Combine(sourceBin, "ffmpeg.exe"), Path.Combine(ffmpegBin, "ffmpeg.exe"), true);

                string ffprobe = Path.Combine(sourceBin, "ffprobe.exe");
                if (File.Exists(ffprobe))
                {
                    File.Copy(ffprobe, Path.Combine(ffmpegBin, "ffprobe.exe"), true);
                }

                AddLog("ffmpeg installed.");
            }
            finally
            {
                ClearSafeDirectory(tmpRoot);
            }
        }

        private void DownloadFile(string url, string destination)
        {
            AddLog("Downloading " + url);
            using (WebClient client = new WebClient())
            {
                client.Headers.Add("User-Agent", "YT-Downloader-Windows");
                client.DownloadFile(url, destination);
            }
        }

        private void DownloadFirstAvailable(string[] urls, string destination, string label)
        {
            Exception lastError = null;

            for (int i = 0; i < urls.Length; i++)
            {
                try
                {
                    DownloadFile(urls[i], destination);
                    return;
                }
                catch (Exception ex)
                {
                    lastError = ex;
                    AddLog(label + " download source failed: " + ex.Message);
                    if (File.Exists(destination))
                    {
                        File.Delete(destination);
                    }
                    if (i + 1 < urls.Length)
                    {
                        AddLog("Trying another " + label + " download source.");
                    }
                }
            }

            throw new InvalidOperationException("All " + label + " download sources failed.", lastError);
        }

        private void ClearSafeDirectory(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return;
            }

            string toolsFull = Path.GetFullPath(toolsDir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string targetFull = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!targetFull.StartsWith(toolsFull, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Refusing to remove a folder outside the app tools directory: " + targetFull);
            }

            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }

        private void StartQualityCheck()
        {
            if (busy)
            {
                return;
            }

            if (!EnsureToolsOrOfferInstall())
            {
                return;
            }

            string url = GetValidatedUrl();
            if (url == null)
            {
                return;
            }

            string[] args = BuildQualityArgs(url);
            RunYtDlp(args, "Checking available qualities.", "Quality check finished.", "Quality check failed");
        }

        private string[] BuildQualityArgs(string url)
        {
            if (playlistBox.Checked)
            {
                return new string[] { "-F", url };
            }
            return new string[] { "-F", "--no-playlist", url };
        }

        private void StartDownload()
        {
            if (busy)
            {
                return;
            }

            if (!EnsureToolsOrOfferInstall())
            {
                return;
            }

            string url = GetValidatedUrl();
            if (url == null)
            {
                return;
            }

            string folder;
            try
            {
                folder = GetOutputFolder();
            }
            catch (Exception ex)
            {
                ShowError("Folder error", ex.Message);
                return;
            }

            string height = GetSelectedHeight();
            string container = Convert.ToString(containerBox.SelectedItem);
            string selector = GetFormatSelector(height, container);
            string extension = container.ToLowerInvariant();
            string outputTemplate = Path.Combine(folder, "%(title).180B [%(id)s].%(ext)s");

            AddLog("Saving to " + folder);
            AddLog("Quality: " + Convert.ToString(qualityBox.SelectedItem) + ", container: " + container);

            string[] args = BuildDownloadArgs(url, selector, extension, outputTemplate);
            RunYtDlp(args, "Downloading...", "Download finished.", "Download failed");
        }

        private string[] BuildDownloadArgs(string url, string selector, string extension, string outputTemplate)
        {
            if (playlistBox.Checked)
            {
                return new string[]
                {
                    "--newline",
                    "--windows-filenames",
                    "--no-mtime",
                    "--ffmpeg-location", ffmpegBin,
                    "-f", selector,
                    "--merge-output-format", extension,
                    "-o", outputTemplate,
                    url
                };
            }

            return new string[]
            {
                "--newline",
                "--windows-filenames",
                "--no-mtime",
                "--ffmpeg-location", ffmpegBin,
                "-f", selector,
                "--merge-output-format", extension,
                "-o", outputTemplate,
                "--no-playlist",
                url
            };
        }

        private bool EnsureToolsOrOfferInstall()
        {
            if (TestRequiredTools())
            {
                return true;
            }

            DialogResult result = MessageBox.Show(
                this,
                "This app needs yt-dlp and ffmpeg in its tools folder. Install them now?",
                "Install tools",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question);

            if (result == DialogResult.Yes)
            {
                StartToolInstall();
            }
            else
            {
                AddLog("Action cancelled because required tools are missing.");
            }

            return false;
        }

        private string GetValidatedUrl()
        {
            string url = urlBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(url) || !url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(this, "Paste a valid YouTube URL first.", "Missing link", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return null;
            }
            return url;
        }

        private string GetOutputFolder()
        {
            string folder = folderBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(folder))
            {
                folder = GetDefaultVideoFolder();
                folderBox.Text = folder;
            }

            if (!Directory.Exists(folder))
            {
                Directory.CreateDirectory(folder);
            }

            return folder;
        }

        private string GetSelectedHeight()
        {
            string text = Convert.ToString(qualityBox.SelectedItem);
            if (text.StartsWith("480p"))
            {
                return "480";
            }
            if (text.StartsWith("720p"))
            {
                return "720";
            }
            if (text.StartsWith("1080p"))
            {
                return "1080";
            }
            if (text.StartsWith("1440p"))
            {
                return "1440";
            }
            return "best";
        }

        private string GetFormatSelector(string height, string container)
        {
            if (container == "MP4")
            {
                if (height == "best")
                {
                    return "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/best[ext=mp4]";
                }
                return "bv*[height<=" + height + "][ext=mp4]+ba[ext=m4a]/b[height<=" + height + "][ext=mp4]/best[height<=" + height + "][ext=mp4]";
            }

            if (height == "best")
            {
                return "bv*+ba/best";
            }
            return "bv*[height<=" + height + "]+ba/b[height<=" + height + "]/best[height<=" + height + "]";
        }

        private void RunYtDlp(string[] args, string startMessage, string successMessage, string failureMessage)
        {
            SetBusy(true, startMessage, true);
            AddLog(startMessage);

            ThreadPool.QueueUserWorkItem(delegate
            {
                int exitCode = -1;
                try
                {
                    exitCode = InvokeProcess(ytDlpPath, args);
                    if (exitCode == 0)
                    {
                        AddLog(successMessage);
                        SetBusy(false, "Ready", false);
                    }
                    else
                    {
                        AddLog(string.Format("{0} with exit code {1}.", failureMessage, exitCode));
                        SetBusy(false, "Failed", false);
                    }
                }
                catch (Exception ex)
                {
                    AddLog(failureMessage + ": " + ex.Message);
                    SetBusy(false, "Failed", false);
                }
                finally
                {
                    UpdateToolStatus();
                }
            });
        }

        private int InvokeProcess(string filePath, string[] args)
        {
            Process process = new Process();
            process.StartInfo.FileName = filePath;
            process.StartInfo.Arguments = JoinArguments(args);
            process.StartInfo.WorkingDirectory = appRoot;
            process.StartInfo.UseShellExecute = false;
            process.StartInfo.RedirectStandardOutput = true;
            process.StartInfo.RedirectStandardError = true;
            process.StartInfo.CreateNoWindow = true;

            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null)
                {
                    AddRawLog(e.Data + Environment.NewLine);
                }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null)
                {
                    AddRawLog(e.Data + Environment.NewLine);
                }
            };

            lock (processLock)
            {
                activeProcess = process;
            }

            try
            {
                AddLog("Starting " + Path.GetFileName(filePath));
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                process.CancelOutputRead();
                process.CancelErrorRead();
                return process.ExitCode;
            }
            finally
            {
                lock (processLock)
                {
                    if (ReferenceEquals(activeProcess, process))
                    {
                        activeProcess = null;
                    }
                }
                process.Dispose();
            }
        }

        private string JoinArguments(string[] args)
        {
            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < args.Length; i++)
            {
                if (i > 0)
                {
                    builder.Append(' ');
                }
                builder.Append(QuoteArgument(args[i]));
            }
            return builder.ToString();
        }

        private string QuoteArgument(string arg)
        {
            if (arg == null)
            {
                return "\"\"";
            }
            if (arg.Length > 0 && arg.IndexOfAny(new char[] { ' ', '\t', '\n', '\r', '"' }) < 0)
            {
                return arg;
            }

            StringBuilder builder = new StringBuilder();
            builder.Append('"');
            int backslashes = 0;
            for (int i = 0; i < arg.Length; i++)
            {
                char c = arg[i];
                if (c == '\\')
                {
                    backslashes++;
                }
                else if (c == '"')
                {
                    builder.Append('\\', backslashes * 2 + 1);
                    builder.Append('"');
                    backslashes = 0;
                }
                else
                {
                    builder.Append('\\', backslashes);
                    backslashes = 0;
                    builder.Append(c);
                }
            }
            builder.Append('\\', backslashes * 2);
            builder.Append('"');
            return builder.ToString();
        }

        private void StopActiveProcess()
        {
            Process process;
            lock (processLock)
            {
                process = activeProcess;
            }

            if (process == null)
            {
                return;
            }

            try
            {
                if (!process.HasExited)
                {
                    AddLog("Stopping current job...");
                    ProcessStartInfo startInfo = new ProcessStartInfo();
                    startInfo.FileName = "taskkill.exe";
                    startInfo.Arguments = "/PID " + process.Id + " /T /F";
                    startInfo.CreateNoWindow = true;
                    startInfo.UseShellExecute = false;
                    using (Process killer = Process.Start(startInfo))
                    {
                        if (killer != null)
                        {
                            killer.WaitForExit();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                AddLog("Stop failed: " + ex.Message);
            }
        }

        private void BrowseFolder()
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Choose download folder";
                dialog.SelectedPath = folderBox.Text;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    folderBox.Text = dialog.SelectedPath;
                }
            }
        }

        private void OpenDownloadFolder()
        {
            try
            {
                string folder = GetOutputFolder();
                Process.Start(folder);
            }
            catch (Exception ex)
            {
                AddLog("Could not open folder: " + ex.Message);
            }
        }

        private void ShowError(string title, string message)
        {
            if (IsDisposed)
            {
                return;
            }

            if (InvokeRequired)
            {
                BeginInvoke(new Action<string, string>(ShowError), title, message);
                return;
            }

            MessageBox.Show(this, message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (!busy)
            {
                return;
            }

            Process process;
            lock (processLock)
            {
                process = activeProcess;
            }

            if (process == null || process.HasExited)
            {
                return;
            }

            DialogResult choice = MessageBox.Show(
                this,
                "A download is still running. Stop it and close?",
                "Download running",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question);

            if (choice == DialogResult.Yes)
            {
                StopActiveProcess();
            }
            else
            {
                e.Cancel = true;
            }
        }
    }
}
