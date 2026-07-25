using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Threading;
using System.Windows.Forms;

namespace WattBar.WindowsApp
{
    [DataContract]
    internal sealed class SettingsData
    {
        [DataMember] public int RefreshSeconds;
        [DataMember] public bool TrackEnergyUsage;
        [DataMember] public double AccumulatedEnergyWh;
        [DataMember] public double AccumulatedTrackingSeconds;
        [DataMember] public double SouthAfricaTariff;
        [DataMember] public double UnitedKingdomTariff;

        public static SettingsData CreateDefault()
        {
            return new SettingsData
            {
                RefreshSeconds = 5,
                TrackEnergyUsage = false,
                AccumulatedEnergyWh = 0,
                AccumulatedTrackingSeconds = 0,
                SouthAfricaTariff = 3.50,
                UnitedKingdomTariff = 0.2611
            };
        }

        public void Validate()
        {
            if (RefreshSeconds != 2 && RefreshSeconds != 5 &&
                RefreshSeconds != 10 && RefreshSeconds != 30)
            {
                RefreshSeconds = 5;
            }
            if (!IsFiniteNonNegative(AccumulatedEnergyWh))
            {
                AccumulatedEnergyWh = 0;
            }
            if (!IsFiniteNonNegative(AccumulatedTrackingSeconds))
            {
                AccumulatedTrackingSeconds = 0;
            }
            if (!IsFinitePositive(SouthAfricaTariff))
            {
                SouthAfricaTariff = 3.50;
            }
            if (!IsFinitePositive(UnitedKingdomTariff))
            {
                UnitedKingdomTariff = 0.2611;
            }
        }

        private static bool IsFiniteNonNegative(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value) && value >= 0;
        }

        private static bool IsFinitePositive(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value) && value > 0;
        }
    }

    internal sealed class SettingsStore
    {
        private readonly string _directory;
        private readonly string _path;
        private readonly DataContractJsonSerializer _serializer;

        public SettingsStore()
        {
            _directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WattBar");
            _path = Path.Combine(_directory, "settings.json");
            _serializer = new DataContractJsonSerializer(typeof(SettingsData));
        }

        public SettingsData Load()
        {
            try
            {
                if (!File.Exists(_path))
                {
                    return SettingsData.CreateDefault();
                }

                using (FileStream stream = File.OpenRead(_path))
                {
                    SettingsData settings = _serializer.ReadObject(stream) as SettingsData;
                    if (settings == null)
                    {
                        return SettingsData.CreateDefault();
                    }
                    settings.Validate();
                    return settings;
                }
            }
            catch
            {
                return SettingsData.CreateDefault();
            }
        }

        public void Save(SettingsData settings)
        {
            settings.Validate();
            Directory.CreateDirectory(_directory);
            string temporaryPath = _path + ".tmp";

            using (FileStream stream = new FileStream(
                temporaryPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.None))
            {
                _serializer.WriteObject(stream, settings);
                stream.Flush(true);
            }

            if (File.Exists(_path))
            {
                string backupPath = _path + ".bak";
                try
                {
                    File.Replace(temporaryPath, _path, backupPath, true);
                    if (File.Exists(backupPath))
                    {
                        File.Delete(backupPath);
                    }
                    return;
                }
                catch
                {
                    if (File.Exists(backupPath))
                    {
                        File.Delete(backupPath);
                    }
                }
            }

            File.Copy(temporaryPath, _path, true);
            File.Delete(temporaryPath);
        }
    }

    internal sealed class PowerReading
    {
        public double? SystemWatts;
        public int? BatteryPercent;
        public string PowerState;
        public string Source;
        public DateTime TimestampUtc;
    }

    internal sealed class ExternalPowerSample
    {
        public double Watts;
        public double AgeSeconds;
    }

    internal static class ExternalPowerReader
    {
        public static string InputPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "WattBar",
                    "external-power-watts.txt");
            }
        }

        public static bool TryRead(
            double maximumAgeSeconds,
            DateTime nowUtc,
            out ExternalPowerSample sample)
        {
            sample = null;
            try
            {
                string path = InputPath;
                if (!File.Exists(path))
                {
                    return false;
                }

                double age = Math.Max(0, (nowUtc - File.GetLastWriteTimeUtc(path)).TotalSeconds);
                double watts;
                if (age > maximumAgeSeconds ||
                    !TryParseWatts(File.ReadAllText(path), out watts))
                {
                    return false;
                }

                sample = new ExternalPowerSample
                {
                    Watts = watts,
                    AgeSeconds = age
                };
                return true;
            }
            catch
            {
                return false;
            }
        }

        internal static bool TryParseWatts(string text, out double watts)
        {
            watts = 0;
            double value;
            if (!Double.TryParse(
                    text.Trim(),
                    NumberStyles.Float,
                    CultureInfo.InvariantCulture,
                    out value) ||
                Double.IsNaN(value) ||
                Double.IsInfinity(value) ||
                value < 0 ||
                value > 100000)
            {
                return false;
            }

            watts = value;
            return true;
        }
    }

    internal static class NativePowerReader
    {
        private const int SystemBatteryStateInformationLevel = 5;
        private const int UnknownRate = Int32.MinValue;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct SystemBatteryState
        {
            public byte AcOnLine;
            public byte BatteryPresent;
            public byte Charging;
            public byte Discharging;
            public byte Spare1;
            public byte Spare2;
            public byte Spare3;
            public byte Tag;
            public uint MaxCapacity;
            public uint RemainingCapacity;
            public int Rate;
            public uint EstimatedTime;
            public uint DefaultAlert1;
            public uint DefaultAlert2;
        }

        [DllImport("powrprof.dll")]
        private static extern uint CallNtPowerInformation(
            int informationLevel,
            IntPtr inputBuffer,
            uint inputBufferSize,
            out SystemBatteryState outputBuffer,
            uint outputBufferSize);

        public static PowerReading Read(double maximumExternalAgeSeconds)
        {
            DateTime now = DateTime.UtcNow;
            ExternalPowerSample externalSample;
            bool hasExternalSample = ExternalPowerReader.TryRead(
                maximumExternalAgeSeconds,
                now,
                out externalSample);

            SystemBatteryState state;
            uint status = CallNtPowerInformation(
                SystemBatteryStateInformationLevel,
                IntPtr.Zero,
                0,
                out state,
                (uint)Marshal.SizeOf(typeof(SystemBatteryState)));

            if (status != 0)
            {
                if (hasExternalSample)
                {
                    return FromExternal(
                        externalSample,
                        "External whole-device meter",
                        null,
                        now);
                }
                return Unavailable(
                    "Whole-device telemetry unavailable; external meter input inactive",
                    "System battery state unavailable (status " + status.ToString() + ")",
                    now);
            }

            if (state.BatteryPresent == 0)
            {
                if (hasExternalSample)
                {
                    return FromExternal(
                        externalSample,
                        "Desktop / no system battery",
                        null,
                        now);
                }
                return Unavailable(
                    "Whole-device telemetry not exposed by Windows; external meter input inactive",
                    "Desktop / no system battery",
                    now);
            }

            int? percent = null;
            if (state.MaxCapacity > 0 && state.MaxCapacity != UInt32.MaxValue &&
                state.RemainingCapacity != UInt32.MaxValue)
            {
                double value = 100.0 * state.RemainingCapacity / state.MaxCapacity;
                percent = (int)Math.Max(0, Math.Min(100, Math.Round(value)));
            }

            bool onAc = state.AcOnLine != 0;
            bool charging = state.Charging != 0;
            bool discharging = state.Discharging != 0;
            double? watts = null;
            string powerState;
            string source;

            if (!onAc && (discharging || state.Rate < 0) &&
                state.Rate != 0 && state.Rate != UnknownRate)
            {
                watts = Math.Abs((double)state.Rate) / 1000.0;
                powerState = "On battery";
                source = "Windows native battery discharge rate";
            }
            else if (onAc)
            {
                powerState = charging ? "Plugged in, charging" : "Plugged in";
                source = "System draw is not exposed by the Windows battery API while on AC";
            }
            else
            {
                powerState = "On battery";
                source = "Battery discharge rate is unavailable from this device";
            }

            if (hasExternalSample)
            {
                return FromExternal(externalSample, powerState, percent, now);
            }

            return new PowerReading
            {
                SystemWatts = watts,
                BatteryPercent = percent,
                PowerState = powerState,
                Source = source,
                TimestampUtc = now
            };
        }

        private static PowerReading FromExternal(
            ExternalPowerSample sample,
            string powerState,
            int? batteryPercent,
            DateTime now)
        {
            return new PowerReading
            {
                SystemWatts = sample.Watts,
                BatteryPercent = batteryPercent,
                PowerState = powerState,
                Source = String.Format(
                    "External whole-device meter ({0:F1} s old)",
                    sample.AgeSeconds),
                TimestampUtc = now
            };
        }

        private static PowerReading Unavailable(
            string source,
            string powerState,
            DateTime now)
        {
            return new PowerReading
            {
                SystemWatts = null,
                BatteryPercent = null,
                PowerState = powerState,
                Source = source,
                TimestampUtc = now
            };
        }
    }

    internal sealed class EnergyAccumulator
    {
        public double WattHours { get; private set; }
        public double ActiveSeconds { get; private set; }

        private double? _previousWatts;
        private DateTime? _previousDateUtc;

        public EnergyAccumulator(double wattHours, double activeSeconds)
        {
            WattHours = IsFiniteNonNegative(wattHours) ? wattHours : 0;
            ActiveSeconds = IsFiniteNonNegative(activeSeconds) ? activeSeconds : 0;
        }

        public void AddSample(double? watts, DateTime dateUtc, double maximumIntervalSeconds)
        {
            if (!watts.HasValue || !IsFiniteNonNegative(watts.Value))
            {
                Pause();
                return;
            }

            if (_previousWatts.HasValue && _previousDateUtc.HasValue)
            {
                double elapsed = (dateUtc - _previousDateUtc.Value).TotalSeconds;
                if (elapsed > 0 && elapsed <= maximumIntervalSeconds)
                {
                    double averageWatts = (_previousWatts.Value + watts.Value) / 2.0;
                    WattHours += averageWatts * elapsed / 3600.0;
                    ActiveSeconds += elapsed;
                }
            }

            _previousWatts = watts.Value;
            _previousDateUtc = dateUtc;
        }

        public void Pause()
        {
            _previousWatts = null;
            _previousDateUtc = null;
        }

        public void Reset()
        {
            WattHours = 0;
            ActiveSeconds = 0;
            Pause();
        }

        private static bool IsFiniteNonNegative(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value) && value >= 0;
        }
    }

    internal sealed class TariffDialog : Form
    {
        private readonly NumericUpDown _randRate;
        private readonly NumericUpDown _poundRate;

        public double SouthAfricaTariff
        {
            get { return Decimal.ToDouble(_randRate.Value); }
        }

        public double UnitedKingdomTariff
        {
            get { return Decimal.ToDouble(_poundRate.Value); }
        }

        public TariffDialog(double randRate, double poundRate)
        {
            Text = "Electricity Tariffs";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Padding = new Padding(12);

            Label explanation = new Label
            {
                Text = "Enter the unit rates from your electricity bills. " +
                       "Cost totals exclude standing charges.",
                AutoSize = true,
                MaximumSize = new Size(360, 0),
                Margin = new Padding(3, 3, 3, 10)
            };

            _randRate = CreateRateInput(randRate);
            _poundRate = CreateRateInput(poundRate);

            TableLayoutPanel fields = new TableLayoutPanel
            {
                AutoSize = true,
                ColumnCount = 2,
                RowCount = 2,
                Dock = DockStyle.Top
            };
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
            fields.Controls.Add(new Label
            {
                Text = "South Africa (R/kWh)",
                AutoSize = true,
                Anchor = AnchorStyles.Left
            }, 0, 0);
            fields.Controls.Add(_randRate, 1, 0);
            fields.Controls.Add(new Label
            {
                Text = "United Kingdom (£/kWh)",
                AutoSize = true,
                Anchor = AnchorStyles.Left
            }, 0, 1);
            fields.Controls.Add(_poundRate, 1, 1);

            Button save = new Button
            {
                Text = "Save",
                DialogResult = DialogResult.OK,
                AutoSize = true
            };
            Button cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                AutoSize = true
            };
            FlowLayoutPanel buttons = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.RightToLeft,
                AutoSize = true,
                Dock = DockStyle.Fill,
                Margin = new Padding(0, 12, 0, 0)
            };
            buttons.Controls.Add(cancel);
            buttons.Controls.Add(save);

            TableLayoutPanel content = new TableLayoutPanel
            {
                AutoSize = true,
                ColumnCount = 1,
                RowCount = 3,
                Dock = DockStyle.Fill
            };
            content.Controls.Add(explanation, 0, 0);
            content.Controls.Add(fields, 0, 1);
            content.Controls.Add(buttons, 0, 2);
            Controls.Add(content);

            AcceptButton = save;
            CancelButton = cancel;
        }

        private static NumericUpDown CreateRateInput(double value)
        {
            decimal safeValue = (decimal)Math.Max(0.0001, Math.Min(1000, value));
            return new NumericUpDown
            {
                DecimalPlaces = 4,
                Minimum = 0.0001M,
                Maximum = 1000M,
                Increment = 0.01M,
                Value = safeValue,
                Dock = DockStyle.Fill
            };
        }
    }

    internal sealed class WattBarContext : ApplicationContext
    {
        private const double PersistenceIntervalSeconds = 30;

        private readonly SettingsStore _settingsStore;
        private readonly SettingsData _settings;
        private readonly EnergyAccumulator _accumulator;
        private readonly NotifyIcon _notifyIcon;
        private readonly ContextMenuStrip _menu;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly ToolStripLabel _livePower;
        private readonly ToolStripLabel _powerState;
        private readonly ToolStripLabel _source;
        private readonly ToolStripMenuItem _track;
        private readonly ToolStripLabel _trackingTime;
        private readonly ToolStripLabel _energyUsed;
        private readonly ToolStripLabel _southAfricaCost;
        private readonly ToolStripLabel _unitedKingdomCost;
        private readonly ToolStripLabel _rates;
        private readonly ToolStripLabel _standingCharges;
        private readonly ToolStripMenuItem _reset;
        private readonly ToolStripMenuItem[] _intervalItems;

        private PowerReading _latestReading;
        private DateTime _lastPersistenceUtc;
        private bool _exiting;

        public WattBarContext()
        {
            _settingsStore = new SettingsStore();
            _settings = _settingsStore.Load();
            _accumulator = new EnergyAccumulator(
                _settings.AccumulatedEnergyWh,
                _settings.AccumulatedTrackingSeconds);
            _lastPersistenceUtc = DateTime.UtcNow;

            _menu = new ContextMenuStrip();
            _menu.ShowImageMargin = true;

            ToolStripLabel heading = StatusLabel("Watt Bar — Windows", true);
            _livePower = StatusLabel("Live power: measuring…", true);
            _powerState = StatusLabel("Power: measuring…", false);
            _source = StatusLabel("Whole-device source: measuring…", false);
            _source.ForeColor = SystemColors.GrayText;

            _track = new ToolStripMenuItem("Track Energy Usage & Cost");
            _track.Checked = _settings.TrackEnergyUsage;
            _track.Click += delegate
            {
                _settings.TrackEnergyUsage = !_settings.TrackEnergyUsage;
                _track.Checked = _settings.TrackEnergyUsage;
                if (!_settings.TrackEnergyUsage)
                {
                    _accumulator.Pause();
                    Persist(true);
                }
                RefreshReading();
            };

            _trackingTime = StatusLabel("", false);
            _energyUsed = StatusLabel("", false);
            _southAfricaCost = StatusLabel("", false);
            _unitedKingdomCost = StatusLabel("", false);
            _rates = StatusLabel("", false);
            _rates.ForeColor = SystemColors.GrayText;
            _standingCharges = StatusLabel("Standing charges excluded", false);
            _standingCharges.ForeColor = SystemColors.GrayText;

            ToolStripMenuItem tariffs = new ToolStripMenuItem("Electricity Tariffs…");
            tariffs.Click += delegate { EditTariffs(); };

            _reset = new ToolStripMenuItem("Reset Tracking Totals…");
            _reset.Click += delegate { ResetTracking(); };

            ToolStripMenuItem refreshNow = new ToolStripMenuItem("Refresh Now");
            refreshNow.ShortcutKeys = Keys.Control | Keys.R;
            refreshNow.Click += delegate { RefreshReading(); };

            ToolStripMenuItem refreshInterval = new ToolStripMenuItem("Refresh Interval");
            int[] intervals = new int[] { 2, 5, 10, 30 };
            _intervalItems = new ToolStripMenuItem[intervals.Length];
            for (int index = 0; index < intervals.Length; index++)
            {
                int seconds = intervals[index];
                ToolStripMenuItem item = new ToolStripMenuItem(seconds.ToString() + " seconds");
                item.Tag = seconds;
                item.Click += SetRefreshInterval;
                refreshInterval.DropDownItems.Add(item);
                _intervalItems[index] = item;
            }

            ToolStripMenuItem exit = new ToolStripMenuItem("Quit Watt Bar");
            exit.Click += delegate { ExitThread(); };

            _menu.Items.Add(heading);
            _menu.Items.Add(_livePower);
            _menu.Items.Add(_powerState);
            _menu.Items.Add(_source);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(_track);
            _menu.Items.Add(_trackingTime);
            _menu.Items.Add(_energyUsed);
            _menu.Items.Add(_southAfricaCost);
            _menu.Items.Add(_unitedKingdomCost);
            _menu.Items.Add(_rates);
            _menu.Items.Add(_standingCharges);
            _menu.Items.Add(tariffs);
            _menu.Items.Add(_reset);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(refreshNow);
            _menu.Items.Add(refreshInterval);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(exit);
            _menu.Opening += delegate { RefreshReading(); };

            _notifyIcon = new NotifyIcon
            {
                Icon = SystemIcons.Information,
                Text = "Watt Bar",
                ContextMenuStrip = _menu,
                Visible = true
            };
            _notifyIcon.MouseClick += delegate(object sender, MouseEventArgs eventArgs)
            {
                if (eventArgs.Button == MouseButtons.Left)
                {
                    _menu.Show(Cursor.Position);
                }
            };

            _timer = new System.Windows.Forms.Timer();
            _timer.Tick += delegate { RefreshReading(); };
            ApplyRefreshInterval();
            RefreshReading();
            _timer.Start();
        }

        private static ToolStripLabel StatusLabel(string text, bool emphasized)
        {
            ToolStripLabel label = new ToolStripLabel(text);
            label.AutoSize = true;
            label.Padding = new Padding(20, 2, 12, 2);
            label.Font = new Font(
                SystemFonts.MenuFont,
                emphasized ? FontStyle.Bold : FontStyle.Regular);
            label.ForeColor = SystemColors.MenuText;
            label.IsLink = false;
            return label;
        }

        private void RefreshReading()
        {
            try
            {
                _latestReading = NativePowerReader.Read(
                    Math.Max(15, _settings.RefreshSeconds * 2.5));
                if (_settings.TrackEnergyUsage)
                {
                    double maximumInterval = Math.Max(5, _settings.RefreshSeconds * 2.5);
                    _accumulator.AddSample(
                        _latestReading.SystemWatts,
                        _latestReading.TimestampUtc,
                        maximumInterval);
                    Persist(false);
                }
                else
                {
                    _accumulator.Pause();
                }
                UpdateDisplay();
            }
            catch (Exception error)
            {
                _latestReading = new PowerReading
                {
                    SystemWatts = null,
                    BatteryPercent = null,
                    PowerState = "Power telemetry unavailable",
                    Source = error.Message,
                    TimestampUtc = DateTime.UtcNow
                };
                _accumulator.Pause();
                UpdateDisplay();
            }
        }

        private void UpdateDisplay()
        {
            string watts = FormatWatts(_latestReading.SystemWatts);
            _livePower.Text = "Live power: " + watts;
            string percent = _latestReading.BatteryPercent.HasValue
                ? " · Battery " + _latestReading.BatteryPercent.Value.ToString() + "%"
                : "";
            _powerState.Text = "Power: " + _latestReading.PowerState + percent;
            _source.Text = "Whole-device source: " + _latestReading.Source;

            bool tracking = _settings.TrackEnergyUsage;
            _trackingTime.Visible = tracking;
            _energyUsed.Visible = tracking;
            _southAfricaCost.Visible = tracking;
            _unitedKingdomCost.Visible = tracking;
            _rates.Visible = tracking;
            _standingCharges.Visible = tracking;

            double kilowattHours = _accumulator.WattHours / 1000.0;
            _trackingTime.Text = "Tracking time: " + FormatDuration(_accumulator.ActiveSeconds);
            _energyUsed.Text = "Energy used: " + FormatEnergy(_accumulator.WattHours);
            _southAfricaCost.Text =
                "South Africa cost: " + FormatRand(kilowattHours * _settings.SouthAfricaTariff);
            _unitedKingdomCost.Text =
                "United Kingdom cost: " +
                FormatPounds(kilowattHours * _settings.UnitedKingdomTariff);
            _rates.Text = String.Format(
                "Rates: R {0:F4}/kWh and £{1:F4}/kWh",
                _settings.SouthAfricaTariff,
                _settings.UnitedKingdomTariff);
            _reset.Enabled = _accumulator.WattHours > 0 || _accumulator.ActiveSeconds > 0;

            for (int index = 0; index < _intervalItems.Length; index++)
            {
                _intervalItems[index].Checked =
                    (int)_intervalItems[index].Tag == _settings.RefreshSeconds;
            }

            string tooltip = _latestReading.SystemWatts.HasValue
                ? "Watt Bar | " + watts
                : "Watt Bar | Power draw unavailable";
            _notifyIcon.Text = tooltip.Length <= 63 ? tooltip : tooltip.Substring(0, 63);
        }

        private void EditTariffs()
        {
            using (TariffDialog dialog = new TariffDialog(
                _settings.SouthAfricaTariff,
                _settings.UnitedKingdomTariff))
            {
                if (dialog.ShowDialog() != DialogResult.OK)
                {
                    return;
                }
                _settings.SouthAfricaTariff = dialog.SouthAfricaTariff;
                _settings.UnitedKingdomTariff = dialog.UnitedKingdomTariff;
                Persist(true);
                UpdateDisplay();
            }
        }

        private void ResetTracking()
        {
            DialogResult result = MessageBox.Show(
                "This resets tracking time, accumulated watt-hours, and both cost totals to zero.",
                "Reset tracked usage?",
                MessageBoxButtons.OKCancel,
                MessageBoxIcon.Warning);
            if (result != DialogResult.OK)
            {
                return;
            }
            _accumulator.Reset();
            Persist(true);
            UpdateDisplay();
        }

        private void SetRefreshInterval(object sender, EventArgs eventArgs)
        {
            ToolStripMenuItem item = sender as ToolStripMenuItem;
            if (item == null)
            {
                return;
            }
            _settings.RefreshSeconds = (int)item.Tag;
            ApplyRefreshInterval();
            Persist(true);
            UpdateDisplay();
        }

        private void ApplyRefreshInterval()
        {
            _timer.Interval = _settings.RefreshSeconds * 1000;
        }

        private void Persist(bool force)
        {
            DateTime now = DateTime.UtcNow;
            if (!force && (now - _lastPersistenceUtc).TotalSeconds < PersistenceIntervalSeconds)
            {
                return;
            }
            _settings.AccumulatedEnergyWh = _accumulator.WattHours;
            _settings.AccumulatedTrackingSeconds = _accumulator.ActiveSeconds;
            _settingsStore.Save(_settings);
            _lastPersistenceUtc = now;
        }

        protected override void ExitThreadCore()
        {
            if (_exiting)
            {
                return;
            }
            _exiting = true;
            _timer.Stop();
            Persist(true);
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _menu.Dispose();
            _timer.Dispose();
            base.ExitThreadCore();
        }

        internal static string FormatWatts(double? watts)
        {
            return watts.HasValue ? String.Format("{0:F1} W", watts.Value) : "unavailable";
        }

        internal static string FormatEnergy(double wattHours)
        {
            double kilowattHours = wattHours / 1000.0;
            if (wattHours < 1)
            {
                return String.Format("{0:F3} Wh · {1:F5} kWh", wattHours, kilowattHours);
            }
            if (wattHours < 1000)
            {
                return String.Format("{0:F2} Wh · {1:F4} kWh", wattHours, kilowattHours);
            }
            return String.Format("{0:F3} kWh", kilowattHours);
        }

        internal static string FormatDuration(double seconds)
        {
            int totalSeconds = Math.Max(0, (int)Math.Floor(seconds));
            int days = totalSeconds / 86400;
            int hours = (totalSeconds % 86400) / 3600;
            int minutes = (totalSeconds % 3600) / 60;
            int remainingSeconds = totalSeconds % 60;
            if (days > 0)
            {
                return String.Format("{0}d {1}h {2}m", days, hours, minutes);
            }
            if (hours > 0)
            {
                return String.Format("{0}h {1}m", hours, minutes);
            }
            if (minutes > 0)
            {
                return String.Format("{0}m {1}s", minutes, remainingSeconds);
            }
            return remainingSeconds.ToString() + "s";
        }

        internal static string FormatRand(double value)
        {
            return value < 0.01
                ? String.Format("R {0:F4}", value)
                : String.Format("R {0:F2}", value);
        }

        internal static string FormatPounds(double value)
        {
            return value < 0.01
                ? String.Format("£{0:F4}", value)
                : String.Format("£{0:F2}", value);
        }
    }

    internal static class SelfTests
    {
        public static bool Run()
        {
            DateTime start = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            EnergyAccumulator accumulator = new EnergyAccumulator(0, 0);
            accumulator.AddSample(10, start, 4000);
            accumulator.AddSample(20, start.AddHours(1), 4000);
            if (!Near(accumulator.WattHours, 15) || !Near(accumulator.ActiveSeconds, 3600))
            {
                return false;
            }

            accumulator.Pause();
            accumulator.AddSample(100, start.AddHours(2), 4000);
            if (!Near(accumulator.ActiveSeconds, 3600))
            {
                return false;
            }
            accumulator.AddSample(100, start.AddHours(3), 4000);
            if (!Near(accumulator.WattHours, 115) || !Near(accumulator.ActiveSeconds, 7200))
            {
                return false;
            }
            accumulator.AddSample(100, start.AddHours(6), 4000);
            if (!Near(accumulator.ActiveSeconds, 7200))
            {
                return false;
            }

            double kilowattHours = 50.0 / 1000.0;
            if (!Near(kilowattHours * 3.50, 0.175) ||
                !Near(kilowattHours * 0.2611, 0.013055))
            {
                return false;
            }
            if (WattBarContext.FormatDuration(754) != "12m 34s" ||
                WattBarContext.FormatEnergy(50) != "50.00 Wh · 0.0500 kWh")
            {
                return false;
            }
            double parsedWatts;
            if (!ExternalPowerReader.TryParseWatts("42.75\n", out parsedWatts) ||
                !Near(parsedWatts, 42.75) ||
                ExternalPowerReader.TryParseWatts("-1", out parsedWatts) ||
                ExternalPowerReader.TryParseWatts("not watts", out parsedWatts))
            {
                return false;
            }

            accumulator.Reset();
            return Near(accumulator.WattHours, 0) && Near(accumulator.ActiveSeconds, 0);
        }

        private static bool Near(double left, double right)
        {
            return Math.Abs(left - right) < 0.000001;
        }
    }

    internal static class Program
    {
        private static Mutex _mutex;

        [STAThread]
        public static int Main(string[] arguments)
        {
            if (arguments.Length > 0 &&
                String.Equals(arguments[0], "--self-test", StringComparison.OrdinalIgnoreCase))
            {
                return SelfTests.Run() ? 0 : 1;
            }

            bool createdNew;
            _mutex = new Mutex(true, "Local\\WattBar.Windows", out createdNew);
            if (!createdNew)
            {
                MessageBox.Show(
                    "Watt Bar is already running in the system tray.",
                    "Watt Bar",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                _mutex.Dispose();
                return 0;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                Application.Run(new WattBarContext());
            }
            finally
            {
                _mutex.ReleaseMutex();
                _mutex.Dispose();
            }
            return 0;
        }
    }
}
