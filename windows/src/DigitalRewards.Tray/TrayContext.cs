using System.Drawing.Drawing2D;
using DigitalRewards.Core;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Tray;

/// <summary>
/// The per-user agent: reports the foreground app to the service every 2 seconds, shows the balance
/// in the tray, warns at 10/5/1 minutes left, and runs the iCloud sign-in. It can't change anything.
/// </summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _signInItem;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly WarningTracker _warnings = new();
    private AgentStatus? _status;
    private bool _busy;
    private bool _signingIn;
    private TimeUpForm? _timeUp;
    private Icon? _currentIcon;
    private string _iconKey = "";
    private DateTimeOffset? _lastClosedSeen;

    public TrayContext()
    {
        _statusItem = new ToolStripMenuItem("Connecting…") { Enabled = false };
        _signInItem = new ToolStripMenuItem("Sign in to iCloud…", null, async (_, _) => await SignInAsync());
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_signInItem);

        _icon = new NotifyIcon
        {
            Text = "Go AFK",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => ShowStatusBalloon();
        SetIcon("…", Color.Gray);

        _timer = new System.Windows.Forms.Timer { Interval = 2000 };
        _timer.Tick += async (_, _) => await ReportAsync();
        _timer.Start();
    }

    private async Task ReportAsync()
    {
        if (_busy)
        {
            return;
        }
        _busy = true;
        try
        {
            var report = await Task.Run(ForegroundProbe.Capture);
            var response = await ServiceClient.SendAsync(new AgentRequest { Type = AgentRequestType.Report, Report = report }, TimeSpan.FromSeconds(5));
            Update(response);
        }
        finally
        {
            _busy = false;
        }
    }

    private void Update(AgentResponse response)
    {
        if (!response.Ok || response.Status is null)
        {
            _statusItem.Text = response.Error ?? "Service unavailable";
            SetIcon("!", Color.Gray);
            _icon.Text = "Go AFK: service not running";
            return;
        }

        var first = _status is null;
        var s = _status = response.Status;
        _signInItem.Visible = !s.SignedIn;
        if (!s.SignedIn)
        {
            _statusItem.Text = "Not signed in to iCloud";
            SetIcon("?", Color.Gray);
            _icon.Text = "Go AFK: sign in to iCloud";
            if (first && !_signingIn)
            {
                _icon.ShowBalloonTip(10000, "Go AFK", "Sign in with your iCloud account to start using your minutes. Right-click the tray icon.", ToolTipIcon.Info);
            }
            return;
        }

        if (s.SetupNeeded)
        {
            _statusItem.Text = "Finish joining your family on your iPhone";
            SetIcon("!", Color.DarkOrange);
            _icon.Text = "Go AFK: finish setup on your iPhone";
            if (first)
            {
                _icon.ShowBalloonTip(10000, "Go AFK", SetupMessages.ActivityNotShared, ToolTipIcon.Warning);
            }
            return;
        }

        var name = string.IsNullOrEmpty(s.ChildName) ? "" : s.ChildName + ": ";
        var left = s.Blocked ? "no play time left" : $"{s.MinutesAvailable} min left";
        _statusItem.Text = $"{name}balance {Minutes(s.Balance)} · {left}";
        _icon.Text = Truncate($"Go AFK: {Minutes(s.Balance)} · {left}", 63);
        SetIcon(s.Blocked ? "0" : Short(s.MinutesAvailable), s.Blocked ? Color.Firebrick : s.Balance < 0 ? Color.DarkOrange : Color.SeaGreen);

        if (s.LastClosedAt is { } closedAt && closedAt != _lastClosedSeen)
        {
            if (_lastClosedSeen is not null || DateTimeOffset.UtcNow - closedAt < TimeSpan.FromSeconds(10))
            {
                _icon.ShowBalloonTip(5000, "Go AFK", $"{s.LastClosedApp} was closed: no play time right now.", ToolTipIcon.Warning);
            }
            _lastClosedSeen = closedAt;
        }

        var warning = _warnings.Update(s.MinutesAvailable, s.Blocked, s.Playing);
        switch (warning.Kind)
        {
            case WarningKind.MinutesLeft:
                _icon.ShowBalloonTip(8000, "Go AFK",
                    warning.Minutes == 1 ? "1 minute of play time left. Time to save your game!" : $"{warning.Minutes} minutes of play time left.",
                    ToolTipIcon.Warning);
                break;
            case WarningKind.TimeUp:
                ShowTimeUp(s);
                break;
        }
    }

    private void ShowTimeUp(AgentStatus s)
    {
        if (_timeUp is { IsDisposed: false })
        {
            return;
        }
        var message = s.BlockReason switch
        {
            PlayReasons.OutsidePlayWindow => "It's outside your play hours right now.",
            PlayReasons.DailyCapReached => "You've reached today's play limit.",
            BlockDecision.Offline => "This PC hasn't been able to reach iCloud for a while. Connect to the internet to keep playing.",
            BlockDecision.NeverSynced => "This PC hasn't synced with iCloud yet. Connect to the internet.",
            _ => "You're out of minutes. Go for a walk to earn more!",
        };
        _timeUp = new TimeUpForm(message);
        _timeUp.FormClosed += (_, _) => _timeUp = null;
        _timeUp.Show();
        _timeUp.Activate();
    }

    private void ShowStatusBalloon()
    {
        if (_status is { SignedIn: true } s)
        {
            var reason = s.Blocked ? "Play is blocked right now." : $"You can play for {s.MinutesAvailable} more minutes.";
            _icon.ShowBalloonTip(6000, "Go AFK", $"Balance: {Minutes(s.Balance)}. {reason}", ToolTipIcon.Info);
        }
    }

    private async Task SignInAsync()
    {
        if (_signingIn)
        {
            return;
        }
        _signingIn = true;
        _signInItem.Enabled = false;
        try
        {
            var result = await SignInFlow.RunAsync(CancellationToken.None);
            if (result.Ok)
            {
                _icon.ShowBalloonTip(6000, "Go AFK", "Signed in. Your balance is now shown here.", ToolTipIcon.Info);
                Update(result);
            }
            else
            {
                MessageBox.Show(result.Error ?? "Sign-in failed.", "Go AFK", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
        finally
        {
            _signingIn = false;
            _signInItem.Enabled = true;
        }
    }

    private static string Minutes(int m) => m < 0 ? $"{m} min (debit)" : $"{m} min";

    private static string Short(int minutes) => minutes >= 1000 ? "999" : minutes.ToString(System.Globalization.CultureInfo.InvariantCulture);

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    /// <summary>Draws a round badge with the minutes left.</summary>
    private void SetIcon(string text, Color color)
    {
        var key = text + color.ToArgb();
        if (key == _iconKey)
        {
            return;
        }
        _iconKey = key;
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var brush = new SolidBrush(color);
            g.FillEllipse(brush, 0, 0, 31, 31);
            var size = text.Length >= 3 ? 10f : 14f;
            using var font = new Font("Segoe UI", size, FontStyle.Bold, GraphicsUnit.Pixel);
            using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(text, font, Brushes.White, new RectangleF(0, 0, 32, 32), sf);
        }
        var handle = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(handle).Clone();
        Native.DestroyIcon(handle);
        _icon.Icon = icon;
        _currentIcon?.Dispose();
        _currentIcon = icon;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Dispose();
            _icon.Visible = false;
            _icon.Dispose();
            _currentIcon?.Dispose();
            _timeUp?.Dispose();
        }
        base.Dispose(disposing);
    }
}
