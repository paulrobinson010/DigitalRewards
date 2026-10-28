namespace DigitalRewards.Tray;

/// <summary>A friendly, always-on-top notice that play time has run out.</summary>
internal sealed class TimeUpForm : Form
{
    public TimeUpForm(string message)
    {
        Text = "DigitalRewards";
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = true;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(24);

        var layout = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
        };
        layout.Controls.Add(new Label
        {
            Text = "Time's up!",
            Font = new Font(Font.FontFamily, 20, FontStyle.Bold),
            AutoSize = true,
        });
        layout.Controls.Add(new Label
        {
            Text = message,
            Font = new Font(Font.FontFamily, 11),
            AutoSize = true,
            MaximumSize = new Size(420, 0),
            Margin = new Padding(0, 8, 0, 16),
        });
        var ok = new Button { Text = "OK", AutoSize = true, DialogResult = DialogResult.OK };
        layout.Controls.Add(ok);
        AcceptButton = ok;
        Controls.Add(layout);
    }
}
