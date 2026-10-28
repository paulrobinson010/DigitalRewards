namespace DigitalRewards.Tray;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // One agent per user session.
        using var mutex = new Mutex(initiallyOwned: true, @"Local\DigitalRewards.Tray", out var createdNew);
        if (!createdNew)
        {
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }
}
