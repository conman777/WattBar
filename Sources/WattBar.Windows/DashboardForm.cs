using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WattBar.WindowsApp
{
    internal static class GlassPalette
    {
        public static readonly Color Canvas = Color.FromArgb(9, 14, 26);
        public static readonly Color CanvasLight = Color.FromArgb(18, 28, 48);
        public static readonly Color GlassSurface = Color.FromArgb(23, 34, 54);
        public static readonly Color GlassBorder = Color.FromArgb(78, 255, 255, 255);
        public static readonly Color Text = Color.FromArgb(246, 248, 252);
        public static readonly Color Muted = Color.FromArgb(155, 170, 193);
        public static readonly Color Accent = Color.FromArgb(72, 225, 168);
        public static readonly Color AccentSoft = Color.FromArgb(42, 72, 225, 168);
        public static readonly Color Warning = Color.FromArgb(251, 191, 76);
        public static readonly Color WarningSoft = Color.FromArgb(44, 251, 191, 76);
    }

    internal static class GlassDrawing
    {
        public static GraphicsPath RoundedRectangle(Rectangle rectangle, int radius)
        {
            int diameter = Math.Max(2, radius * 2);
            GraphicsPath path = new GraphicsPath();
            path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
            path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
            path.AddArc(
                rectangle.Right - diameter,
                rectangle.Bottom - diameter,
                diameter,
                diameter,
                0,
                90);
            path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal class GlassPanel : Panel
    {
        private Color _accentColor = Color.Transparent;

        public Color AccentColor
        {
            get { return _accentColor; }
            set
            {
                _accentColor = value;
                Invalidate();
            }
        }

        public GlassPanel()
        {
            SetStyle(
                ControlStyles.UserPaint |
                ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.SupportsTransparentBackColor,
                true);
            BackColor = GlassPalette.GlassSurface;
            Padding = new Padding(18);
        }

        protected override void OnPaintBackground(PaintEventArgs eventArgs)
        {
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            if (bounds.Width <= 0 || bounds.Height <= 0)
            {
                return;
            }

            using (GraphicsPath path = GlassDrawing.RoundedRectangle(bounds, 18))
            using (SolidBrush fill = new SolidBrush(BackColor))
            using (Pen border = new Pen(GlassPalette.GlassBorder))
            {
                eventArgs.Graphics.FillPath(fill, path);
                eventArgs.Graphics.DrawPath(border, path);
            }

            if (_accentColor.A > 0)
            {
                using (SolidBrush accent = new SolidBrush(_accentColor))
                {
                    eventArgs.Graphics.FillRectangle(accent, 20, 0, Math.Max(48, Width / 4), 2);
                }
            }
        }
    }

    internal sealed class GlassButton : Control
    {
        private bool _hovered;
        private bool _pressed;
        private Color _accentColor = GlassPalette.Accent;
        private bool _filled;

        public Color AccentColor
        {
            get { return _accentColor; }
            set
            {
                _accentColor = value;
                Invalidate();
            }
        }

        public bool Filled
        {
            get { return _filled; }
            set
            {
                _filled = value;
                Invalidate();
            }
        }

        public GlassButton()
        {
            SetStyle(
                ControlStyles.UserPaint |
                ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.SupportsTransparentBackColor,
                true);
            BackColor = Color.Transparent;
            ForeColor = GlassPalette.Text;
            Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold);
            Cursor = Cursors.Hand;
            Size = new Size(112, 38);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            Color accent = Enabled ? _accentColor : Color.FromArgb(90, GlassPalette.Muted);
            Color fill;
            if (_filled)
            {
                int alpha = _pressed ? 210 : (_hovered ? 245 : 230);
                fill = Color.FromArgb(alpha, accent);
            }
            else
            {
                fill = _pressed
                    ? Color.FromArgb(56, accent)
                    : (_hovered ? Color.FromArgb(42, accent) : Color.FromArgb(18, 255, 255, 255));
            }

            using (GraphicsPath path = GlassDrawing.RoundedRectangle(bounds, 11))
            using (SolidBrush background = new SolidBrush(fill))
            using (Pen border = new Pen(_filled ? Color.FromArgb(180, accent) : Color.FromArgb(92, accent)))
            {
                eventArgs.Graphics.FillPath(background, path);
                eventArgs.Graphics.DrawPath(border, path);
            }

            Color textColor = !Enabled
                ? Color.FromArgb(120, GlassPalette.Muted)
                : (_filled ? GlassPalette.Canvas : ForeColor);
            TextRenderer.DrawText(
                eventArgs.Graphics,
                Text,
                Font,
                bounds,
                textColor,
                TextFormatFlags.HorizontalCenter |
                TextFormatFlags.VerticalCenter |
                TextFormatFlags.EndEllipsis);
        }

        protected override void OnMouseEnter(EventArgs eventArgs)
        {
            _hovered = true;
            Invalidate();
            base.OnMouseEnter(eventArgs);
        }

        protected override void OnMouseLeave(EventArgs eventArgs)
        {
            _hovered = false;
            _pressed = false;
            Invalidate();
            base.OnMouseLeave(eventArgs);
        }

        protected override void OnMouseDown(MouseEventArgs eventArgs)
        {
            if (eventArgs.Button == MouseButtons.Left)
            {
                _pressed = true;
                Invalidate();
            }
            base.OnMouseDown(eventArgs);
        }

        protected override void OnMouseUp(MouseEventArgs eventArgs)
        {
            _pressed = false;
            Invalidate();
            base.OnMouseUp(eventArgs);
        }
    }

    internal sealed class StatusPill : Control
    {
        private Color _pillColor = GlassPalette.Warning;

        public Color PillColor
        {
            get { return _pillColor; }
            set
            {
                _pillColor = value;
                Invalidate();
            }
        }

        public StatusPill()
        {
            SetStyle(
                ControlStyles.UserPaint |
                ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.SupportsTransparentBackColor,
                true);
            BackColor = Color.Transparent;
            Font = new Font("Segoe UI Semibold", 8F, FontStyle.Bold);
            ForeColor = GlassPalette.Canvas;
            Size = new Size(116, 28);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = GlassDrawing.RoundedRectangle(bounds, Height / 2))
            using (SolidBrush fill = new SolidBrush(_pillColor))
            {
                eventArgs.Graphics.FillPath(fill, path);
            }
            TextRenderer.DrawText(
                eventArgs.Graphics,
                Text,
                Font,
                bounds,
                ForeColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }

        protected override void OnTextChanged(EventArgs eventArgs)
        {
            Invalidate();
            base.OnTextChanged(eventArgs);
        }
    }

    internal sealed class MetricCard : GlassPanel
    {
        private readonly Label _value;

        public string Value
        {
            get { return _value.Text; }
            set { _value.Text = value; }
        }

        public MetricCard(string caption, Color accent)
        {
            AccentColor = Color.FromArgb(185, accent);
            Label title = new Label
            {
                AutoSize = false,
                Text = caption,
                Font = new Font("Segoe UI Semibold", 7.5F, FontStyle.Bold),
                ForeColor = GlassPalette.Muted,
                BackColor = Color.Transparent,
                Location = new Point(16, 16),
                Size = new Size(122, 18)
            };
            _value = new Label
            {
                AutoSize = false,
                Text = "—",
                Font = new Font("Segoe UI Semibold", 13F, FontStyle.Bold),
                ForeColor = GlassPalette.Text,
                BackColor = Color.Transparent,
                Location = new Point(16, 46),
                Size = new Size(122, 32),
                AutoEllipsis = true
            };
            Controls.Add(title);
            Controls.Add(_value);
        }
    }

    internal static class WindowBackdrop
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(
            IntPtr window,
            int attribute,
            ref int value,
            int valueSize);

        public static void Apply(IntPtr handle)
        {
            try
            {
                int enabled = 1;
                DwmSetWindowAttribute(handle, 20, ref enabled, sizeof(int));
                int roundCorners = 2;
                DwmSetWindowAttribute(handle, 33, ref roundCorners, sizeof(int));
                int transientBackdrop = 3;
                DwmSetWindowAttribute(handle, 38, ref transientBackdrop, sizeof(int));
            }
            catch (DllNotFoundException)
            {
            }
            catch (EntryPointNotFoundException)
            {
            }
        }
    }

    internal sealed class DashboardForm : Form
    {
        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(
            IntPtr window,
            int message,
            IntPtr parameter,
            IntPtr data);

        private const int NonClientLeftButtonDown = 0x00A1;
        private const int HitCaption = 0x0002;

        private readonly Label _updated;
        private readonly Label _watts;
        private readonly Label _liveCaption;
        private readonly Label _powerState;
        private readonly Label _source;
        private readonly StatusPill _statusPill;
        private readonly GlassPanel _guidancePanel;
        private readonly Label _guidance;
        private readonly Label _costSummary;
        private readonly MetricCard _cpuCard;
        private readonly MetricCard _gpuCard;
        private readonly MetricCard _timeCard;
        private readonly MetricCard _energyCard;
        private readonly GlassButton _trackingButton;
        private readonly GlassButton _refreshButton;
        private readonly GlassButton _tariffsButton;
        private readonly GlassButton _resetButton;
        private readonly GlassButton[] _intervalButtons;
        private readonly Label[] _displayNameLabels;
        private readonly Label[] _displayValueLabels;
        private readonly GlassButton[] _displayToggleButtons;
        private readonly Label _displayTotal;
        private int _selectedRefreshSeconds = 5;
        private int _requestedMonitorIndex;
        private bool _allowClose;

        public event EventHandler RefreshRequested;
        public event EventHandler TrackingToggled;
        public event EventHandler TariffsRequested;
        public event EventHandler ResetRequested;
        public event EventHandler RefreshIntervalChanged;
        public event EventHandler MonitorToggleRequested;

        public int SelectedRefreshSeconds
        {
            get { return _selectedRefreshSeconds; }
        }

        public int RequestedMonitorIndex
        {
            get { return _requestedMonitorIndex; }
        }

        public DashboardForm()
        {
            Text = "WattBar — Power Dashboard";
            StartPosition = FormStartPosition.Manual;
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            ClientSize = new Size(940, 640);
            MinimumSize = Size;
            MaximumSize = Size;
            BackColor = GlassPalette.Canvas;
            ForeColor = GlassPalette.Text;
            Font = new Font("Segoe UI", 9F, FontStyle.Regular);
            AutoScaleMode = AutoScaleMode.Dpi;
            DoubleBuffered = true;

            Panel titleBar = new Panel
            {
                BackColor = Color.Transparent,
                Location = new Point(0, 0),
                Size = new Size(940, 60)
            };
            StatusPill logo = new StatusPill
            {
                Text = "W",
                PillColor = GlassPalette.Accent,
                Font = new Font("Segoe UI Semibold", 11F, FontStyle.Bold),
                Location = new Point(24, 16),
                Size = new Size(30, 30)
            };
            Label brand = MakeLabel(
                "WATTBAR",
                62,
                13,
                160,
                26,
                15F,
                GlassPalette.Text,
                true);
            Label subtitle = MakeLabel(
                "POWER INTELLIGENCE",
                64,
                38,
                190,
                16,
                7.5F,
                GlassPalette.Accent,
                true);
            _updated = MakeLabel(
                "MEASURING…",
                650,
                20,
                180,
                24,
                8F,
                GlassPalette.Muted,
                true);
            _updated.TextAlign = ContentAlignment.MiddleRight;

            GlassButton minimize = new GlassButton
            {
                Text = "—",
                Location = new Point(842, 14),
                Size = new Size(36, 32),
                Font = new Font("Segoe UI", 11F)
            };
            GlassButton close = new GlassButton
            {
                Text = "×",
                Location = new Point(884, 14),
                Size = new Size(36, 32),
                AccentColor = Color.FromArgb(248, 113, 113),
                Font = new Font("Segoe UI", 13F)
            };
            minimize.Click += delegate { WindowState = FormWindowState.Minimized; };
            close.Click += delegate { Hide(); };

            titleBar.Controls.Add(logo);
            titleBar.Controls.Add(brand);
            titleBar.Controls.Add(subtitle);
            titleBar.Controls.Add(_updated);
            titleBar.Controls.Add(minimize);
            titleBar.Controls.Add(close);
            AttachDrag(titleBar);
            AttachDrag(brand);
            AttachDrag(subtitle);

            GlassPanel hero = new GlassPanel
            {
                Location = new Point(24, 76),
                Size = new Size(548, 240),
                AccentColor = GlassPalette.Accent
            };
            _statusPill = new StatusPill
            {
                Text = "MEASURING",
                Location = new Point(22, 20),
                Size = new Size(118, 28)
            };
            _liveCaption = MakeLabel(
                "LIVE POWER",
                22,
                65,
                180,
                18,
                8F,
                GlassPalette.Muted,
                true);
            _watts = MakeLabel(
                "—",
                20,
                84,
                224,
                78,
                44F,
                GlassPalette.Text,
                true);
            Label unit = MakeLabel(
                "WATTS",
                232,
                131,
                70,
                24,
                9F,
                GlassPalette.Muted,
                true);
            _powerState = MakeLabel(
                "Checking Windows power capability",
                294,
                69,
                224,
                44,
                11F,
                GlassPalette.Text,
                true);
            _source = MakeLabel(
                "Waiting for the first power sample…",
                294,
                116,
                224,
                76,
                9F,
                GlassPalette.Muted,
                false);
            hero.Controls.Add(_statusPill);
            hero.Controls.Add(_liveCaption);
            hero.Controls.Add(_watts);
            hero.Controls.Add(unit);
            hero.Controls.Add(_powerState);
            hero.Controls.Add(_source);

            _guidancePanel = new GlassPanel
            {
                Location = new Point(24, 332),
                Size = new Size(548, 108),
                AccentColor = GlassPalette.Warning
            };
            Label insightTitle = MakeLabel(
                "POWER SOURCE",
                20,
                15,
                160,
                18,
                8F,
                GlassPalette.Warning,
                true);
            _guidance = MakeLabel(
                "",
                20,
                38,
                505,
                53,
                9.5F,
                GlassPalette.Text,
                false);
            _guidancePanel.Controls.Add(insightTitle);
            _guidancePanel.Controls.Add(_guidance);

            GlassPanel controls = new GlassPanel
            {
                Location = new Point(24, 456),
                Size = new Size(548, 136)
            };
            _trackingButton = MakeButton("START TRACKING", 20, 20, 140, true);
            _refreshButton = MakeButton("REFRESH", 172, 20, 100, false);
            _tariffsButton = MakeButton("TARIFFS", 284, 20, 100, false);
            _resetButton = MakeButton("RESET", 396, 20, 100, false);
            _costSummary = MakeLabel(
                "TRACKED COST  •  R 0.00  •  £0.00",
                20,
                80,
                504,
                22,
                8F,
                GlassPalette.Muted,
                false);
            controls.Controls.Add(_trackingButton);
            controls.Controls.Add(_refreshButton);
            controls.Controls.Add(_tariffsButton);
            controls.Controls.Add(_resetButton);
            controls.Controls.Add(_costSummary);

            Label summaryTitle = MakeLabel(
                "COMPONENT TELEMETRY",
                592,
                78,
                200,
                22,
                8F,
                GlassPalette.Muted,
                true);
            _cpuCard = new MetricCard("CPU PACKAGE", GlassPalette.Accent)
            {
                Location = new Point(592, 108),
                Size = new Size(154, 104)
            };
            _gpuCard = new MetricCard("NVIDIA GPU", Color.FromArgb(96, 165, 250))
            {
                Location = new Point(762, 108),
                Size = new Size(154, 104)
            };
            _timeCard = new MetricCard("TRACKING TIME", Color.FromArgb(196, 181, 253))
            {
                Location = new Point(592, 224),
                Size = new Size(154, 104)
            };
            _energyCard = new MetricCard("ENERGY USED", Color.FromArgb(244, 114, 182))
            {
                Location = new Point(762, 224),
                Size = new Size(154, 104)
            };

            GlassPanel displays = new GlassPanel
            {
                Location = new Point(592, 344),
                Size = new Size(324, 248),
                AccentColor = Color.FromArgb(96, 165, 250)
            };
            Label displaysTitle = MakeLabel(
                "DISPLAY LOAD",
                20,
                16,
                140,
                20,
                9F,
                GlassPalette.Text,
                true);
            _displayTotal = MakeLabel(
                "0.0 W",
                184,
                14,
                114,
                22,
                10F,
                GlassPalette.Accent,
                true);
            _displayTotal.TextAlign = ContentAlignment.MiddleRight;
            _displayNameLabels = new Label[3];
            _displayValueLabels = new Label[3];
            _displayToggleButtons = new GlassButton[3];
            for (int index = 0; index < 3; index++)
            {
                _displayNameLabels[index] = MakeLabel(
                    "Detecting display...",
                    20,
                    47 + (index * 31),
                    130,
                    24,
                    8.5F,
                    GlassPalette.Text,
                    index == 0);
                _displayValueLabels[index] = MakeLabel(
                    "--",
                    149,
                    47 + (index * 31),
                    87,
                    24,
                    8F,
                    GlassPalette.Muted,
                    true);
                _displayValueLabels[index].TextAlign = ContentAlignment.MiddleRight;
                _displayToggleButtons[index] = MakeButton(
                    "ON",
                    247,
                    47 + (index * 31),
                    51,
                    false);
                _displayToggleButtons[index].Size = new Size(51, 24);
                _displayToggleButtons[index].Font =
                    new Font("Segoe UI Semibold", 7F, FontStyle.Bold);
                _displayToggleButtons[index].Tag = index;
                _displayToggleButtons[index].Click += SelectDisplayToggle;
                displays.Controls.Add(_displayNameLabels[index]);
                displays.Controls.Add(_displayValueLabels[index]);
                displays.Controls.Add(_displayToggleButtons[index]);
            }
            Label intervalLabel = MakeLabel(
                "SAMPLE",
                20,
                158,
                64,
                24,
                7.5F,
                GlassPalette.Muted,
                true);
            int[] intervals = new int[] { 2, 5, 10, 30 };
            _intervalButtons = new GlassButton[intervals.Length];
            for (int index = 0; index < intervals.Length; index++)
            {
                int seconds = intervals[index];
                GlassButton interval = MakeButton(
                    seconds.ToString() + "S",
                    92 + (index * 51),
                    153,
                    40,
                    false);
                interval.Size = new Size(44, 32);
                interval.Tag = seconds;
                interval.Click += SelectRefreshInterval;
                _intervalButtons[index] = interval;
            }
            Label privacy = MakeLabel(
                "DDC/CI STATE  •  RESEARCHED MODEL WATTS",
                20,
                211,
                278,
                18,
                7.5F,
                GlassPalette.Accent,
                true);
            displays.Controls.Add(displaysTitle);
            displays.Controls.Add(_displayTotal);
            displays.Controls.Add(intervalLabel);
            for (int index = 0; index < _intervalButtons.Length; index++)
            {
                displays.Controls.Add(_intervalButtons[index]);
            }
            displays.Controls.Add(privacy);

            Controls.Add(titleBar);
            Controls.Add(hero);
            Controls.Add(_guidancePanel);
            Controls.Add(controls);
            Controls.Add(summaryTitle);
            Controls.Add(_cpuCard);
            Controls.Add(_gpuCard);
            Controls.Add(_timeCard);
            Controls.Add(_energyCard);
            Controls.Add(displays);

            _trackingButton.Click += delegate { Raise(TrackingToggled); };
            _refreshButton.Click += delegate { Raise(RefreshRequested); };
            _tariffsButton.Click += delegate { Raise(TariffsRequested); };
            _resetButton.Click += delegate { Raise(ResetRequested); };
        }

        public void UpdateDashboard(
            PowerReading reading,
            SettingsData settings,
            EnergyAccumulator accumulator)
        {
            _updated.Text = "UPDATED  " + reading.TimestampUtc.ToLocalTime().ToString("HH:mm:ss");
            bool wholeDeviceAvailable = reading.SystemWatts.HasValue;
            bool componentsAvailable = reading.ComponentWatts.HasValue;
            bool displaysAvailable =
                reading.DisplayWatts.HasValue && reading.Monitors != null;
            double? displayedWatts = reading.TrackedWatts;
            _watts.Text = displayedWatts.HasValue
                ? displayedWatts.Value.ToString("F1")
                : "N/A";

            string battery = reading.BatteryPercent.HasValue
                ? "  •  Battery " + reading.BatteryPercent.Value.ToString() + "%"
                : "";
            if (wholeDeviceAvailable && displaysAvailable)
            {
                _liveCaption.Text = "PC + DISPLAY POWER";
                _powerState.Text = "Known-source total" + battery;
                _source.Text =
                    "Whole-PC reading plus the live state of three researched displays.";
                _guidance.Text =
                    "Display watts fall to standby/off automatically. If your external meter " +
                    "already includes the monitors, do not feed that combined value into WattBar.";
                _statusPill.Text = "LIVE + MODELS";
                _statusPill.PillColor = GlassPalette.Accent;
                _guidancePanel.AccentColor = GlassPalette.Accent;
            }
            else if (componentsAvailable && displaysAvailable)
            {
                _liveCaption.Text = "COMPONENTS + DISPLAYS";
                _powerState.Text = "Known-source estimate";
                _source.Text =
                    "Measured AMD CPU + NVIDIA GPU, plus live display power profiles.";
                _guidance.Text =
                    "Tracks the two measured components and each screen's current power state. " +
                    "The rest of the PC and PSU conversion losses are still excluded.";
                _statusPill.Text = "5 SOURCES";
                _statusPill.PillColor = Color.FromArgb(96, 165, 250);
                _guidancePanel.AccentColor = Color.FromArgb(96, 165, 250);
            }
            else if (wholeDeviceAvailable)
            {
                _liveCaption.Text = "WHOLE DEVICE POWER";
                _powerState.Text = reading.PowerState + battery;
                _source.Text = reading.Source;
                _guidance.Text = PowerCapabilityCopy.GetGuidance(reading.Capability);
                _statusPill.Text = "LIVE";
                _statusPill.PillColor = GlassPalette.Accent;
                _guidancePanel.AccentColor = GlassPalette.Accent;
            }
            else if (componentsAvailable)
            {
                _liveCaption.Text = "CPU + GPU POWER";
                _powerState.Text = "Measured component power";
                _source.Text =
                    "AMD CPU package + NVIDIA GPU. Excludes the rest of the PC and PSU losses.";
                _guidance.Text =
                    "Energy tracking uses the measured CPU + GPU total. " +
                    "It is a component estimate, not power drawn from the wall.";
                _statusPill.Text = "COMPONENTS";
                _statusPill.PillColor = Color.FromArgb(96, 165, 250);
                _guidancePanel.AccentColor = Color.FromArgb(96, 165, 250);
            }
            else
            {
                _liveCaption.Text = "LIVE POWER";
                _powerState.Text = reading.PowerState + battery;
                _source.Text = reading.Source;
                _guidance.Text = PowerCapabilityCopy.GetGuidance(reading.Capability);
                _statusPill.Text = "SOURCE NEEDED";
                _statusPill.PillColor = GlassPalette.Warning;
                _guidancePanel.AccentColor = GlassPalette.Warning;
            }

            double kilowattHours = accumulator.WattHours / 1000.0;
            _cpuCard.Value = FormatComponent(
                reading.CpuWatts,
                reading.CpuUtilizationPercent);
            _gpuCard.Value = FormatComponent(
                reading.GpuWatts,
                reading.GpuUtilizationPercent);
            _timeCard.Value = WattBarContext.FormatDuration(accumulator.ActiveSeconds);
            _energyCard.Value = accumulator.WattHours < 1000
                ? String.Format("{0:F1} Wh", accumulator.WattHours)
                : String.Format("{0:F2} kWh", kilowattHours);
            double liveKilowatts = reading.TrackedWatts.GetValueOrDefault() / 1000.0;
            _costSummary.Text = "NOW  " +
                WattBarContext.FormatRand(liveKilowatts * settings.SouthAfricaTariff) +
                "/h  •  " +
                WattBarContext.FormatPounds(
                    liveKilowatts * settings.UnitedKingdomTariff) +
                "/h    TRACKED  " +
                WattBarContext.FormatRand(kilowattHours * settings.SouthAfricaTariff) +
                "  •  " +
                WattBarContext.FormatPounds(
                    kilowattHours * settings.UnitedKingdomTariff);

            if (reading.Monitors != null)
            {
                int count = Math.Min(
                    reading.Monitors.Length,
                    _displayNameLabels.Length);
                for (int index = 0; index < count; index++)
                {
                    MonitorPowerReading monitor = reading.Monitors[index];
                    _displayNameLabels[index].Text = monitor.DisplayName;
                    _displayValueLabels[index].Text = String.Format(
                        "{0:F1} W  {1}",
                        monitor.Watts,
                        monitor.ManuallyEnabled
                            ? FormatMonitorState(monitor.State)
                            : "OFF");
                    _displayValueLabels[index].ForeColor =
                        monitor.ManuallyEnabled
                            ? MonitorStateColor(monitor.State)
                            : GlassPalette.Muted;
                    _displayToggleButtons[index].Text =
                        monitor.ManuallyEnabled ? "ON" : "OFF";
                    _displayToggleButtons[index].Filled = monitor.ManuallyEnabled;
                    _displayToggleButtons[index].AccentColor =
                        monitor.ManuallyEnabled
                            ? GlassPalette.Accent
                            : Color.FromArgb(248, 113, 113);
                }
            }
            _displayTotal.Text = reading.DisplayWatts.HasValue
                ? String.Format("{0:F1} W", reading.DisplayWatts.Value)
                : "--";

            _trackingButton.Text = settings.TrackEnergyUsage
                ? "PAUSE TRACKING"
                : "START TRACKING";
            _trackingButton.AccentColor =
                settings.TrackEnergyUsage ? GlassPalette.Warning : GlassPalette.Accent;
            _resetButton.Enabled =
                accumulator.WattHours > 0 || accumulator.ActiveSeconds > 0;

            _selectedRefreshSeconds = settings.RefreshSeconds;
            for (int index = 0; index < _intervalButtons.Length; index++)
            {
                int seconds = (int)_intervalButtons[index].Tag;
                _intervalButtons[index].Filled = seconds == settings.RefreshSeconds;
                _intervalButtons[index].AccentColor = Color.FromArgb(96, 165, 250);
            }
        }

        public void ShowDashboard()
        {
            if (!Visible)
            {
                PositionInWorkArea();
                Show();
            }
            if (WindowState == FormWindowState.Minimized)
            {
                WindowState = FormWindowState.Normal;
            }
            Activate();
            BringToFront();
        }

        public void CloseForExit()
        {
            _allowClose = true;
            Close();
        }

        protected override void OnHandleCreated(EventArgs eventArgs)
        {
            base.OnHandleCreated(eventArgs);
            WindowBackdrop.Apply(Handle);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle canvas = ClientRectangle;
            using (LinearGradientBrush background = new LinearGradientBrush(
                canvas,
                GlassPalette.CanvasLight,
                GlassPalette.Canvas,
                125F))
            {
                eventArgs.Graphics.FillRectangle(background, canvas);
            }

            Rectangle greenGlow = new Rectangle(-180, 260, 520, 520);
            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddEllipse(greenGlow);
                using (PathGradientBrush glow = new PathGradientBrush(path))
                {
                    glow.CenterColor = Color.FromArgb(38, GlassPalette.Accent);
                    glow.SurroundColors = new Color[] { Color.Transparent };
                    eventArgs.Graphics.FillEllipse(glow, greenGlow);
                }
            }

            Rectangle blueGlow = new Rectangle(690, -190, 420, 420);
            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddEllipse(blueGlow);
                using (PathGradientBrush glow = new PathGradientBrush(path))
                {
                    glow.CenterColor = Color.FromArgb(30, 96, 165, 250);
                    glow.SurroundColors = new Color[] { Color.Transparent };
                    eventArgs.Graphics.FillEllipse(glow, blueGlow);
                }
            }
        }

        protected override void OnResize(EventArgs eventArgs)
        {
            base.OnResize(eventArgs);
            if (Width <= 0 || Height <= 0)
            {
                return;
            }
            using (GraphicsPath path = GlassDrawing.RoundedRectangle(
                new Rectangle(0, 0, Width - 1, Height - 1),
                20))
            {
                Region = new Region(path);
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs eventArgs)
        {
            if (!_allowClose && eventArgs.CloseReason == CloseReason.UserClosing)
            {
                eventArgs.Cancel = true;
                Hide();
                return;
            }
            base.OnFormClosing(eventArgs);
        }

        private void PositionInWorkArea()
        {
            Screen screen = Screen.FromPoint(Cursor.Position);
            Rectangle area = screen.WorkingArea;
            Location = new Point(
                area.Left + Math.Max(0, (area.Width - Width) / 2),
                area.Top + Math.Max(0, (area.Height - Height) / 2));
        }

        private void AttachDrag(Control control)
        {
            control.MouseDown += DragWindow;
        }

        private void DragWindow(object sender, MouseEventArgs eventArgs)
        {
            if (eventArgs.Button != MouseButtons.Left)
            {
                return;
            }
            ReleaseCapture();
            SendMessage(
                Handle,
                NonClientLeftButtonDown,
                new IntPtr(HitCaption),
                IntPtr.Zero);
        }

        private static Label MakeLabel(
            string text,
            int x,
            int y,
            int width,
            int height,
            float size,
            Color color,
            bool bold)
        {
            return new Label
            {
                AutoSize = false,
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, height),
                Font = new Font(
                    bold ? "Segoe UI Semibold" : "Segoe UI",
                    size,
                    bold ? FontStyle.Bold : FontStyle.Regular),
                ForeColor = color,
                BackColor = Color.Transparent,
                AutoEllipsis = true
            };
        }

        private static GlassButton MakeButton(
            string text,
            int x,
            int y,
            int width,
            bool filled)
        {
            return new GlassButton
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, 38),
                Filled = filled,
                AccentColor = GlassPalette.Accent
            };
        }

        private void Raise(EventHandler handler)
        {
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private static string FormatComponent(double? watts, double? utilizationPercent)
        {
            if (!watts.HasValue && !utilizationPercent.HasValue)
            {
                return "Unavailable";
            }
            if (!watts.HasValue)
            {
                return String.Format("{0:F0}%", utilizationPercent.Value);
            }
            if (!utilizationPercent.HasValue)
            {
                return String.Format("{0:F1} W", watts.Value);
            }
            return String.Format(
                "{0:F1} W  ·  {1:F0}%",
                watts.Value,
                utilizationPercent.Value);
        }

        private static string FormatMonitorState(MonitorPowerState state)
        {
            if (state == MonitorPowerState.On)
            {
                return "ON";
            }
            if (state == MonitorPowerState.Standby)
            {
                return "SLEEP";
            }
            if (state == MonitorPowerState.Off)
            {
                return "OFF";
            }
            return "CHECK";
        }

        private static Color MonitorStateColor(MonitorPowerState state)
        {
            if (state == MonitorPowerState.On)
            {
                return GlassPalette.Accent;
            }
            if (state == MonitorPowerState.Unknown)
            {
                return GlassPalette.Warning;
            }
            return GlassPalette.Muted;
        }

        private void SelectRefreshInterval(object sender, EventArgs eventArgs)
        {
            GlassButton button = sender as GlassButton;
            if (button == null)
            {
                return;
            }
            _selectedRefreshSeconds = (int)button.Tag;
            for (int index = 0; index < _intervalButtons.Length; index++)
            {
                _intervalButtons[index].Filled =
                    ReferenceEquals(_intervalButtons[index], button);
            }
            Raise(RefreshIntervalChanged);
        }

        private void SelectDisplayToggle(object sender, EventArgs eventArgs)
        {
            GlassButton button = sender as GlassButton;
            if (button == null)
            {
                return;
            }
            _requestedMonitorIndex = (int)button.Tag;
            Raise(MonitorToggleRequested);
        }
    }
}
