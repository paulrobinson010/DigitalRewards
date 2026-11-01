using System.Runtime.InteropServices;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Tray;

/// <summary>
/// Feeds <see cref="ActivityTracker"/> from the user's real input: low-level keyboard and mouse
/// hooks (ignoring input injected by software), XInput controllers, and display on/off.
/// Create and dispose on the UI thread: the hooks need its message loop.
/// If the hooks can't be installed, <see cref="IdleSeconds"/> falls back to Windows' own idle time.
/// </summary>
internal sealed class InputMonitor : IDisposable
{
    private readonly ActivityTracker _tracker = new(DateTimeOffset.UtcNow);
    private readonly HookProc _keyboardProc;
    private readonly HookProc _mouseProc;
    private IntPtr _keyboardHook;
    private IntPtr _mouseHook;
    private DateTimeOffset _lastHookEvent = DateTimeOffset.UtcNow;
    private DateTimeOffset _lastHookCheck = DateTimeOffset.UtcNow;
    private readonly System.Windows.Forms.Timer _padTimer;
    private readonly DisplayWindow _display;
    private bool _xinputMissing;

    public InputMonitor()
    {
        // Keep the delegates in fields so the GC can't collect them while Windows holds them.
        _keyboardProc = KeyboardHook;
        _mouseProc = MouseHook;
        InstallHooks();

        _padTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _padTimer.Tick += (_, _) =>
        {
            CheckHooks(DateTimeOffset.UtcNow);
            PollGamepads();
        };
        _padTimer.Start();

        _display = new DisplayWindow(on => _tracker.DisplayChanged(DateTimeOffset.UtcNow, on));
    }

    private void InstallHooks()
    {
        var module = GetModuleHandle(null);
        _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, module, 0);
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, module, 0);
        _lastHookEvent = DateTimeOffset.UtcNow;
    }

    private void UninstallHooks()
    {
        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }
        if (_mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }
    }

    /// <summary>
    /// Windows silently drops a low-level hook that answers too slowly. A dead hook would look
    /// like the child being idle forever, so if Windows has seen input the hooks haven't, reinstall.
    /// </summary>
    private void CheckHooks(DateTimeOffset now)
    {
        if (now - _lastHookCheck < TimeSpan.FromSeconds(30))
        {
            return;
        }
        _lastHookCheck = now;
        if (Native.IdleSeconds() < 5 && now - _lastHookEvent > TimeSpan.FromSeconds(60))
        {
            UninstallHooks();
            InstallHooks();
        }
    }

    private bool HooksInstalled => _keyboardHook != IntPtr.Zero && _mouseHook != IntPtr.Zero;

    /// <summary>Seconds since the child last really used the PC. Safe to call from any thread.</summary>
    public int IdleSeconds() => HooksInstalled ? _tracker.IdleSeconds(DateTimeOffset.UtcNow) : Native.IdleSeconds();

    private IntPtr KeyboardHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            _lastHookEvent = DateTimeOffset.UtcNow;
            var msg = (int)wParam;
            var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            if ((msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) && (info.flags & LLKHF_INJECTED) == 0)
            {
                _tracker.KeyDown(DateTimeOffset.UtcNow);
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    private IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            _lastHookEvent = DateTimeOffset.UtcNow;
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            if ((info.flags & LLMHF_INJECTED) == 0)
            {
                var now = DateTimeOffset.UtcNow;
                switch ((int)wParam)
                {
                    case WM_MOUSEMOVE:
                        _tracker.MouseMove(now, info.pt.X, info.pt.Y);
                        break;
                    case WM_LBUTTONDOWN or WM_RBUTTONDOWN or WM_MBUTTONDOWN or WM_XBUTTONDOWN or WM_MOUSEWHEEL or WM_MOUSEHWHEEL:
                        _tracker.MouseButtonOrWheel(now);
                        break;
                }
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    private void PollGamepads()
    {
        if (_xinputMissing)
        {
            return;
        }
        var now = DateTimeOffset.UtcNow;
        for (var i = 0; i < 4; i++)
        {
            uint result;
            XINPUT_STATE state;
            try
            {
                result = XInputGetState((uint)i, out state);
            }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
            {
                _xinputMissing = true;
                return;
            }
            if (result != 0)
            {
                _tracker.GamepadDisconnected(i);
                continue;
            }
            var g = state.Gamepad;
            _tracker.Gamepad(now, i, new GamepadState(g.wButtons, g.bLeftTrigger, g.bRightTrigger,
                                                      g.sThumbLX, g.sThumbLY, g.sThumbRX, g.sThumbRY));
        }
    }

    public void Dispose()
    {
        _padTimer.Dispose();
        _display.Dispose();
        UninstallHooks();
    }

    /// <summary>A hidden window that receives display on/off/dimmed notifications.</summary>
    private sealed class DisplayWindow : NativeWindow, IDisposable
    {
        private static Guid ConsoleDisplayState = new("6FE69556-704A-47A0-8F24-C28D936FDA47");
        private readonly Action<bool> _changed;
        private readonly IntPtr _registration;

        public DisplayWindow(Action<bool> changed)
        {
            _changed = changed;
            CreateHandle(new CreateParams());
            _registration = RegisterPowerSettingNotification(Handle, ref ConsoleDisplayState, DEVICE_NOTIFY_WINDOW_HANDLE);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_POWERBROADCAST && (int)m.WParam == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
            {
                var setting = Marshal.PtrToStructure<POWERBROADCAST_SETTING>(m.LParam);
                if (setting.PowerSetting == ConsoleDisplayState)
                {
                    // 0 = off, 1 = on, 2 = dimmed (still on).
                    _changed(setting.Data != 0);
                }
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (_registration != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(_registration);
            }
            DestroyHandle();
        }
    }

    // ---- Win32 ----

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_XBUTTONDOWN = 0x020B;
    private const int WM_MOUSEHWHEEL = 0x020E;
    private const uint LLKHF_INJECTED = 0x10;
    private const uint LLMHF_INJECTED = 0x01;
    private const int WM_POWERBROADCAST = 0x0218;
    private const int PBT_POWERSETTINGCHANGE = 0x8013;
    private const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XINPUT_GAMEPAD
    {
        public ushort wButtons;
        public byte bLeftTrigger;
        public byte bRightTrigger;
        public short sThumbLX;
        public short sThumbLY;
        public short sThumbRX;
        public short sThumbRY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct XINPUT_STATE
    {
        public uint dwPacketNumber;
        public XINPUT_GAMEPAD Gamepad;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct POWERBROADCAST_SETTING
    {
        public Guid PowerSetting;
        public uint DataLength;
        public byte Data;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("xinput1_4.dll")]
    private static extern uint XInputGetState(uint dwUserIndex, out XINPUT_STATE pState);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid powerSettingGuid, int flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterPowerSettingNotification(IntPtr handle);
}
