using System;
using System.Collections.Generic;
using System.Diagnostics;
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
        [DataMember] public bool? AsusDisplayEnabled;
        [DataMember] public bool? Lg24DisplayEnabled;
        [DataMember] public bool? Lg27DisplayEnabled;
        [DataMember] public List<PowerHistorySample> PowerHistory;

        public static SettingsData CreateDefault()
        {
            return new SettingsData
            {
                RefreshSeconds = 5,
                TrackEnergyUsage = true,
                AccumulatedEnergyWh = 0,
                AccumulatedTrackingSeconds = 0,
                SouthAfricaTariff = 3.50,
                UnitedKingdomTariff = 0.2611,
                AsusDisplayEnabled = true,
                Lg24DisplayEnabled = true,
                Lg27DisplayEnabled = true,
                PowerHistory = new List<PowerHistorySample>()
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
            if (!AsusDisplayEnabled.HasValue)
            {
                AsusDisplayEnabled = true;
            }
            if (!Lg24DisplayEnabled.HasValue)
            {
                Lg24DisplayEnabled = true;
            }
            if (!Lg27DisplayEnabled.HasValue)
            {
                Lg27DisplayEnabled = true;
            }
            if (PowerHistory == null)
            {
                PowerHistory = new List<PowerHistorySample>();
            }
            List<PowerHistorySample> normalizedHistory = PowerHistoryPolicy.Normalize(
                PowerHistory,
                DateTime.UtcNow);
            PowerHistory.Clear();
            PowerHistory.AddRange(normalizedHistory);
        }

        public bool IsDisplayEnabled(int index)
        {
            if (index == 0)
            {
                return AsusDisplayEnabled.GetValueOrDefault(true);
            }
            if (index == 1)
            {
                return Lg24DisplayEnabled.GetValueOrDefault(true);
            }
            return Lg27DisplayEnabled.GetValueOrDefault(true);
        }

        public void ToggleDisplay(int index)
        {
            bool enabled = !IsDisplayEnabled(index);
            if (index == 0)
            {
                AsusDisplayEnabled = enabled;
            }
            else if (index == 1)
            {
                Lg24DisplayEnabled = enabled;
            }
            else if (index == 2)
            {
                Lg27DisplayEnabled = enabled;
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

    [DataContract]
    internal sealed class PowerHistorySample
    {
        [DataMember] public DateTime TimestampUtc;
        [DataMember] public double Watts;
        [DataMember] public string Source;
    }

    internal static class PowerHistoryPolicy
    {
        public const int RetentionMonths = 6;
        public const int MaximumSamples = 55000;
        public const int MinimumIntervalSeconds = 300;

        public static List<PowerHistorySample> Normalize(
            List<PowerHistorySample> samples,
            DateTime nowUtc)
        {
            DateTime referenceUtc = nowUtc.ToUniversalTime();
            DateTime oldestAllowed = referenceUtc.AddMonths(-RetentionMonths);
            DateTime newestAllowed = referenceUtc.AddMinutes(5);
            List<PowerHistorySample> valid = new List<PowerHistorySample>();
            for (int index = 0; index < samples.Count; index++)
            {
                PowerHistorySample sample = samples[index];
                if (sample == null)
                {
                    continue;
                }

                DateTime timestamp = sample.TimestampUtc.ToUniversalTime();
                if (timestamp < oldestAllowed || timestamp > newestAllowed ||
                    !IsFiniteNonNegative(sample.Watts))
                {
                    continue;
                }

                valid.Add(new PowerHistorySample
                {
                    TimestampUtc = timestamp,
                    Watts = sample.Watts,
                    Source = String.IsNullOrEmpty(sample.Source)
                        ? "Unknown source"
                        : sample.Source
                });
            }

            valid.Sort(delegate(PowerHistorySample left, PowerHistorySample right)
            {
                return left.TimestampUtc.CompareTo(right.TimestampUtc);
            });
            while (valid.Count > MaximumSamples)
            {
                valid.RemoveAt(0);
            }
            return valid;
        }

        private static bool IsFiniteNonNegative(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value) && value >= 0;
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

    internal enum PowerCapability
    {
        NativeBattery,
        ExternalMeter,
        NoBattery,
        PluggedIn,
        BatteryRateUnavailable,
        ApiUnavailable
    }

    internal sealed class PowerReading
    {
        public double? SystemWatts;
        public double? CpuWatts;
        public double? CpuUtilizationPercent;
        public double? GpuWatts;
        public double? GpuUtilizationPercent;
        public double? ComponentWatts;
        public double? DisplayWatts;
        public double? TrackedWatts;
        public MonitorPowerReading[] Monitors;
        public int? BatteryPercent;
        public string PowerState;
        public string Source;
        public PowerCapability Capability;
        public DateTime TimestampUtc;
    }

    internal sealed class ComponentReading
    {
        public double? CpuWatts;
        public double? CpuUtilizationPercent;
        public double? GpuWatts;
        public double? GpuUtilizationPercent;
        public double? CombinedWatts;
    }

    internal enum MonitorPowerState
    {
        On,
        Standby,
        Off,
        Unknown
    }

    internal sealed class MonitorPowerProfile
    {
        public string MatchText;
        public string DisplayName;
        public double OnWatts;
        public double StandbyWatts;
        public double OffWatts;

        public static MonitorPowerProfile[] KnownDisplays()
        {
            return new MonitorPowerProfile[]
            {
                new MonitorPowerProfile
                {
                    MatchText = "AUS32F2",
                    DisplayName = "ASUS PG32UCDM",
                    OnWatts = 42.0,
                    StandbyWatts = 0.5,
                    OffWatts = 0.3
                },
                new MonitorPowerProfile
                {
                    MatchText = "GSM5B09",
                    DisplayName = "LG 24UD58",
                    OnWatts = 35.0,
                    StandbyWatts = 0.5,
                    OffWatts = 0.3
                },
                new MonitorPowerProfile
                {
                    MatchText = "GSM7707",
                    DisplayName = "LG 27UK650",
                    OnWatts = 29.8,
                    StandbyWatts = 0.3,
                    OffWatts = 0.3
                }
            };
        }
    }

    internal sealed class MonitorPowerReading
    {
        public string DisplayName;
        public double Watts;
        public MonitorPowerState State;
        public bool Detected;
        public bool ManuallyEnabled;
    }

    internal static class PowerMath
    {
        public static double? CombineKnownSources(
            double? pcWatts,
            double? displayWatts)
        {
            if (!pcWatts.HasValue && !displayWatts.HasValue)
            {
                return null;
            }
            return (pcWatts ?? 0) + (displayWatts ?? 0);
        }

        public static double MonitorWatts(
            MonitorPowerProfile profile,
            MonitorPowerState state,
            bool manuallyEnabled)
        {
            if (!manuallyEnabled)
            {
                return profile.OffWatts;
            }
            if (state == MonitorPowerState.Standby)
            {
                return profile.StandbyWatts;
            }
            if (state == MonitorPowerState.Off)
            {
                return profile.OffWatts;
            }
            return profile.OnWatts;
        }
    }

    internal sealed class MonitorTelemetryReader : IDisposable
    {
        private const byte PowerModeVcpCode = 0xD6;
        private readonly MonitorPowerProfile[] _profiles;
        private readonly List<MonitorDevice> _devices;
        private readonly MonitorEnumProc _enumerator;

        private sealed class MonitorDevice
        {
            public IntPtr Handle;
            public MonitorPowerProfile Profile;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PhysicalMonitor
        {
            public IntPtr Handle;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string Description;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRectangle
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct MonitorInfo
        {
            public int Size;
            public NativeRectangle Monitor;
            public NativeRectangle Work;
            public uint Flags;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string DeviceName;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DisplayDevice
        {
            public int Size;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string DeviceName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceString;

            public uint StateFlags;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceId;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string DeviceKey;
        }

        private delegate bool MonitorEnumProc(
            IntPtr monitor,
            IntPtr deviceContext,
            IntPtr rectangle,
            IntPtr data);

        [DllImport("user32.dll")]
        private static extern bool EnumDisplayMonitors(
            IntPtr deviceContext,
            IntPtr clipRectangle,
            MonitorEnumProc callback,
            IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetMonitorInfo(
            IntPtr monitor,
            ref MonitorInfo monitorInfo);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumDisplayDevices(
            string deviceName,
            uint deviceNumber,
            ref DisplayDevice displayDevice,
            uint flags);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
            IntPtr monitor,
            out uint numberOfPhysicalMonitors);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetPhysicalMonitorsFromHMONITOR(
            IntPtr monitor,
            uint physicalMonitorArraySize,
            [Out] PhysicalMonitor[] physicalMonitorArray);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetVCPFeatureAndVCPFeatureReply(
            IntPtr physicalMonitor,
            byte vcpCode,
            IntPtr vcpCodeType,
            out uint currentValue,
            out uint maximumValue);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool DestroyPhysicalMonitor(IntPtr physicalMonitor);

        public MonitorTelemetryReader()
        {
            _profiles = MonitorPowerProfile.KnownDisplays();
            _devices = new List<MonitorDevice>();
            _enumerator = EnumerateMonitor;
            try
            {
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, _enumerator, IntPtr.Zero);
            }
            catch (DllNotFoundException)
            {
            }
            catch (EntryPointNotFoundException)
            {
            }
        }

        public MonitorPowerReading[] Read(
            SettingsData settings,
            out double totalWatts)
        {
            MonitorPowerReading[] readings = new MonitorPowerReading[_profiles.Length];
            for (int index = 0; index < _profiles.Length; index++)
            {
                MonitorPowerProfile profile = _profiles[index];
                bool enabled = settings.IsDisplayEnabled(index);
                readings[index] = new MonitorPowerReading
                {
                    DisplayName = profile.DisplayName,
                    Watts = profile.OffWatts,
                    State = MonitorPowerState.Off,
                    Detected = false,
                    ManuallyEnabled = enabled
                };
            }

            for (int index = 0; index < _devices.Count; index++)
            {
                MonitorDevice device = _devices[index];
                int profileIndex = Array.IndexOf(_profiles, device.Profile);
                if (profileIndex < 0)
                {
                    continue;
                }

                uint currentValue;
                uint maximumValue;
                bool success = false;
                try
                {
                    success = GetVCPFeatureAndVCPFeatureReply(
                        device.Handle,
                        PowerModeVcpCode,
                        IntPtr.Zero,
                        out currentValue,
                        out maximumValue);
                }
                catch (DllNotFoundException)
                {
                    currentValue = 0;
                    maximumValue = 0;
                }
                catch (EntryPointNotFoundException)
                {
                    currentValue = 0;
                    maximumValue = 0;
                }

                MonitorPowerState state = success
                    ? StateFromVcp(currentValue)
                    : MonitorPowerState.Off;
                readings[profileIndex].State = state;
                readings[profileIndex].Detected = success;
                readings[profileIndex].Watts = PowerMath.MonitorWatts(
                    device.Profile,
                    state,
                    readings[profileIndex].ManuallyEnabled);
            }

            totalWatts = 0;
            for (int index = 0; index < readings.Length; index++)
            {
                totalWatts += readings[index].Watts;
            }
            return readings;
        }

        public void Dispose()
        {
            for (int index = 0; index < _devices.Count; index++)
            {
                try
                {
                    DestroyPhysicalMonitor(_devices[index].Handle);
                }
                catch (DllNotFoundException)
                {
                }
                catch (EntryPointNotFoundException)
                {
                }
            }
            _devices.Clear();
        }

        internal static MonitorPowerState StateFromVcp(uint value)
        {
            if (value == 1)
            {
                return MonitorPowerState.On;
            }
            if (value == 4 || value == 5)
            {
                return MonitorPowerState.Standby;
            }
            return MonitorPowerState.Unknown;
        }

        private bool EnumerateMonitor(
            IntPtr monitor,
            IntPtr deviceContext,
            IntPtr rectangle,
            IntPtr data)
        {
            MonitorPowerProfile profile = MatchProfile(ReadMonitorDeviceId(monitor));
            if (profile == null || ContainsProfile(profile))
            {
                return true;
            }

            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count) || count == 0)
            {
                return true;
            }

            PhysicalMonitor[] physicalMonitors = new PhysicalMonitor[count];
            if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physicalMonitors))
            {
                return true;
            }

            for (int index = 0; index < physicalMonitors.Length; index++)
            {
                if (index > 0)
                {
                    DestroyPhysicalMonitor(physicalMonitors[index].Handle);
                    continue;
                }
                _devices.Add(new MonitorDevice
                {
                    Handle = physicalMonitors[index].Handle,
                    Profile = profile
                });
            }
            return true;
        }

        private static string ReadMonitorDeviceId(IntPtr monitor)
        {
            MonitorInfo monitorInfo = new MonitorInfo
            {
                Size = Marshal.SizeOf(typeof(MonitorInfo))
            };
            if (!GetMonitorInfo(monitor, ref monitorInfo))
            {
                return "";
            }

            DisplayDevice displayDevice = new DisplayDevice
            {
                Size = Marshal.SizeOf(typeof(DisplayDevice))
            };
            return EnumDisplayDevices(
                monitorInfo.DeviceName,
                0,
                ref displayDevice,
                0)
                ? displayDevice.DeviceId ?? ""
                : "";
        }

        private MonitorPowerProfile MatchProfile(string deviceId)
        {
            for (int index = 0; index < _profiles.Length; index++)
            {
                if (deviceId.IndexOf(
                        _profiles[index].MatchText,
                        StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return _profiles[index];
                }
            }
            return null;
        }

        private bool ContainsProfile(MonitorPowerProfile profile)
        {
            for (int index = 0; index < _devices.Count; index++)
            {
                if (Object.ReferenceEquals(_devices[index].Profile, profile))
                {
                    return true;
                }
            }
            return false;
        }
    }

    internal sealed class ComponentTelemetryReader : IDisposable
    {
        private PerformanceCounter _cpuPower;
        private PerformanceCounter _cpuUtilization;

        public ComponentTelemetryReader()
        {
            _cpuPower = CreateCpuPowerCounter();
            _cpuUtilization = CreateCpuUtilizationCounter();
            Prime(_cpuPower);
            Prime(_cpuUtilization);
        }

        public ComponentReading Read()
        {
            ComponentReading reading = new ComponentReading
            {
                CpuWatts = ReadCounter(_cpuPower, 1000.0, 0, 2000),
                CpuUtilizationPercent = ReadUtilization(_cpuUtilization)
            };

            double gpuWatts;
            double gpuUtilization;
            if (NvidiaTelemetry.TryRead(out gpuWatts, out gpuUtilization))
            {
                reading.GpuWatts = gpuWatts;
                reading.GpuUtilizationPercent = gpuUtilization;
            }

            if (reading.CpuWatts.HasValue && reading.GpuWatts.HasValue)
            {
                reading.CombinedWatts = reading.CpuWatts.Value + reading.GpuWatts.Value;
            }
            return reading;
        }

        public void Dispose()
        {
            if (_cpuPower != null)
            {
                _cpuPower.Dispose();
                _cpuPower = null;
            }
            if (_cpuUtilization != null)
            {
                _cpuUtilization.Dispose();
                _cpuUtilization = null;
            }
        }

        internal static double? Normalize(
            double rawValue,
            double divisor,
            double minimum,
            double maximum)
        {
            if (Double.IsNaN(rawValue) ||
                Double.IsInfinity(rawValue) ||
                divisor <= 0)
            {
                return null;
            }
            double value = rawValue / divisor;
            return value >= minimum && value <= maximum ? (double?)value : null;
        }

        private static PerformanceCounter CreateCpuPowerCounter()
        {
            try
            {
                PerformanceCounterCategory category =
                    new PerformanceCounterCategory("Energy Meter");
                string packageInstance = null;
                foreach (string instance in category.GetInstanceNames())
                {
                    if (instance.EndsWith("_pkg", StringComparison.OrdinalIgnoreCase))
                    {
                        packageInstance = instance;
                        break;
                    }
                }
                return packageInstance == null
                    ? null
                    : new PerformanceCounter(
                        "Energy Meter",
                        "Power",
                        packageInstance,
                        true);
            }
            catch
            {
                return null;
            }
        }

        private static PerformanceCounter CreateCpuUtilizationCounter()
        {
            try
            {
                return new PerformanceCounter(
                    "Processor Information",
                    "% Processor Utility",
                    "_Total",
                    true);
            }
            catch
            {
                try
                {
                    return new PerformanceCounter(
                        "Processor",
                        "% Processor Time",
                        "_Total",
                        true);
                }
                catch
                {
                    return null;
                }
            }
        }

        private static void Prime(PerformanceCounter counter)
        {
            if (counter == null)
            {
                return;
            }
            try
            {
                counter.NextValue();
            }
            catch
            {
            }
        }

        private static double? ReadCounter(
            PerformanceCounter counter,
            double divisor,
            double minimum,
            double maximum)
        {
            if (counter == null)
            {
                return null;
            }
            try
            {
                return Normalize(counter.NextValue(), divisor, minimum, maximum);
            }
            catch
            {
                return null;
            }
        }

        private static double? ReadUtilization(PerformanceCounter counter)
        {
            if (counter == null)
            {
                return null;
            }
            try
            {
                double value = counter.NextValue();
                if (Double.IsNaN(value) || Double.IsInfinity(value))
                {
                    return null;
                }
                return Math.Max(0, Math.Min(100, value));
            }
            catch
            {
                return null;
            }
        }
    }

    internal static class NvidiaTelemetry
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct NvmlUtilization
        {
            public uint Gpu;
            public uint Memory;
        }

        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int nvmlInit_v2();

        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int nvmlDeviceGetHandleByIndex_v2(
            uint index,
            out IntPtr device);

        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int nvmlDeviceGetUtilizationRates(
            IntPtr device,
            out NvmlUtilization utilization);

        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int nvmlDeviceGetPowerUsage(
            IntPtr device,
            out uint milliwatts);

        private static readonly object Sync = new object();
        private static bool _initialized;
        private static bool _unavailable;
        private static IntPtr _device;

        public static bool TryRead(out double watts, out double utilizationPercent)
        {
            watts = 0;
            utilizationPercent = 0;
            lock (Sync)
            {
                if (!EnsureInitialized())
                {
                    return false;
                }
                try
                {
                    uint milliwatts;
                    NvmlUtilization utilization;
                    if (nvmlDeviceGetPowerUsage(_device, out milliwatts) != 0 ||
                        nvmlDeviceGetUtilizationRates(_device, out utilization) != 0)
                    {
                        return false;
                    }
                    double? normalizedWatts = ComponentTelemetryReader.Normalize(
                        milliwatts,
                        1000.0,
                        0,
                        2000);
                    double? normalizedUtilization = ComponentTelemetryReader.Normalize(
                        utilization.Gpu,
                        1,
                        0,
                        100);
                    if (!normalizedWatts.HasValue || !normalizedUtilization.HasValue)
                    {
                        return false;
                    }
                    watts = normalizedWatts.Value;
                    utilizationPercent = normalizedUtilization.Value;
                    return true;
                }
                catch (DllNotFoundException)
                {
                    _unavailable = true;
                    return false;
                }
                catch (EntryPointNotFoundException)
                {
                    _unavailable = true;
                    return false;
                }
            }
        }

        private static bool EnsureInitialized()
        {
            if (_initialized)
            {
                return true;
            }
            if (_unavailable)
            {
                return false;
            }
            try
            {
                if (nvmlInit_v2() != 0 ||
                    nvmlDeviceGetHandleByIndex_v2(0, out _device) != 0)
                {
                    _unavailable = true;
                    return false;
                }
                _initialized = true;
                return true;
            }
            catch (DllNotFoundException)
            {
                _unavailable = true;
                return false;
            }
            catch (EntryPointNotFoundException)
            {
                _unavailable = true;
                return false;
            }
        }
    }

    internal static class PowerCapabilityCopy
    {
        public static string GetGuidance(PowerCapability capability)
        {
            switch (capability)
            {
                case PowerCapability.NativeBattery:
                    return "Live power comes from the Windows battery discharge rate.";
                case PowerCapability.ExternalMeter:
                    return "Live whole-device power comes from a fresh external-meter sample.";
                case PowerCapability.NoBattery:
                    return "This PC has no system battery, so Windows cannot measure whole-device watts. " +
                           "Connect an external plug-in meter to enable live power and tracking.";
                case PowerCapability.PluggedIn:
                    return "Windows does not expose whole-device watts while this PC is plugged in. " +
                           "Unplug to use battery discharge data, or connect an external meter.";
                case PowerCapability.BatteryRateUnavailable:
                    return "This battery does not expose a discharge rate to Windows. " +
                           "Connect an external meter to enable live power and tracking.";
                default:
                    return "Windows could not read the system battery state. " +
                           "An external meter can still provide whole-device power.";
            }
        }
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
                    PowerCapability.ApiUnavailable,
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
                    PowerCapability.NoBattery,
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
                Capability = watts.HasValue
                    ? PowerCapability.NativeBattery
                    : (onAc
                        ? PowerCapability.PluggedIn
                        : PowerCapability.BatteryRateUnavailable),
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
                Capability = PowerCapability.ExternalMeter,
                TimestampUtc = now
            };
        }

        private static PowerReading Unavailable(
            string source,
            string powerState,
            PowerCapability capability,
            DateTime now)
        {
            return new PowerReading
            {
                SystemWatts = null,
                BatteryPercent = null,
                PowerState = powerState,
                Source = source,
                Capability = capability,
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

    internal sealed class PowerHistoryTracker
    {
        private readonly List<PowerHistorySample> _samples;

        public IList<PowerHistorySample> Samples
        {
            get { return _samples; }
        }

        public PowerHistoryTracker(List<PowerHistorySample> samples)
        {
            _samples = samples ?? new List<PowerHistorySample>();
        }

        public bool TryAdd(PowerReading reading)
        {
            if (!reading.TrackedWatts.HasValue ||
                !IsFiniteNonNegative(reading.TrackedWatts.Value))
            {
                return false;
            }

            DateTime timestampUtc = reading.TimestampUtc.ToUniversalTime();
            if (_samples.Count > 0)
            {
                DateTime previousTimestamp = _samples[_samples.Count - 1].TimestampUtc;
                if ((timestampUtc - previousTimestamp).TotalSeconds <
                    PowerHistoryPolicy.MinimumIntervalSeconds)
                {
                    return false;
                }
            }

            _samples.Add(new PowerHistorySample
            {
                TimestampUtc = timestampUtc,
                Watts = reading.TrackedWatts.Value,
                Source = DescribeSource(reading)
            });

            List<PowerHistorySample> normalized = PowerHistoryPolicy.Normalize(
                _samples,
                timestampUtc);
            _samples.Clear();
            _samples.AddRange(normalized);
            return true;
        }

        internal static string DescribeSource(PowerReading reading)
        {
            if (reading.SystemWatts.HasValue)
            {
                return reading.DisplayWatts.HasValue
                    ? "Whole-device + display estimate"
                    : "Whole-device";
            }
            if (reading.ComponentWatts.HasValue)
            {
                return reading.DisplayWatts.HasValue
                    ? "Component estimate + display estimate"
                    : "Component estimate";
            }
            if (reading.DisplayWatts.HasValue)
            {
                return "Display estimate only";
            }
            return "Unavailable";
        }

        private static bool IsFiniteNonNegative(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value) && value >= 0;
        }
    }

    internal sealed class PowerHistoryPeriodSummary
    {
        public string Label;
        public int SampleCount;
        public double TotalWatts;
        public double PeakWatts;
        public DateTime PeakTimestampUtc;

        public double AverageWatts
        {
            get { return SampleCount > 0 ? TotalWatts / SampleCount : 0; }
        }
    }

    internal static class PowerHistoryAnalyzer
    {
        public static List<PowerHistorySample> Recent(
            IList<PowerHistorySample> samples,
            int maximumSamples)
        {
            List<PowerHistorySample> recent = new List<PowerHistorySample>();
            int start = Math.Max(0, samples.Count - maximumSamples);
            for (int index = samples.Count - 1; index >= start; index--)
            {
                recent.Add(samples[index]);
            }
            return recent;
        }

        public static PowerHistorySample Peak(IList<PowerHistorySample> samples)
        {
            PowerHistorySample peak = null;
            for (int index = 0; index < samples.Count; index++)
            {
                if (peak == null || samples[index].Watts > peak.Watts)
                {
                    peak = samples[index];
                }
            }
            return peak;
        }

        public static PowerHistoryPeriodSummary[] ByTimeOfDay(
            IList<PowerHistorySample> samples)
        {
            PowerHistoryPeriodSummary[] summaries = new PowerHistoryPeriodSummary[]
            {
                new PowerHistoryPeriodSummary { Label = "Overnight 00-06" },
                new PowerHistoryPeriodSummary { Label = "Morning 06-12" },
                new PowerHistoryPeriodSummary { Label = "Afternoon 12-18" },
                new PowerHistoryPeriodSummary { Label = "Evening 18-24" }
            };

            for (int index = 0; index < samples.Count; index++)
            {
                PowerHistorySample sample = samples[index];
                int period = sample.TimestampUtc.ToLocalTime().Hour / 6;
                PowerHistoryPeriodSummary summary = summaries[period];
                summary.SampleCount++;
                summary.TotalWatts += sample.Watts;
                if (summary.SampleCount == 1 || sample.Watts > summary.PeakWatts)
                {
                    summary.PeakWatts = sample.Watts;
                    summary.PeakTimestampUtc = sample.TimestampUtc;
                }
            }
            return summaries;
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
            Padding = new Padding(20);
            BackColor = Color.FromArgb(9, 15, 27);
            ForeColor = Color.FromArgb(244, 247, 252);
            Font = new Font("Segoe UI", 9F);

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
                AutoSize = true,
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(52, 211, 153),
                ForeColor = Color.FromArgb(9, 15, 27),
                Padding = new Padding(10, 3, 10, 3)
            };
            save.FlatAppearance.BorderColor = Color.FromArgb(52, 211, 153);
            Button cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                AutoSize = true,
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(17, 27, 45),
                ForeColor = Color.FromArgb(244, 247, 252),
                Padding = new Padding(10, 3, 10, 3)
            };
            cancel.FlatAppearance.BorderColor = Color.FromArgb(37, 52, 75);
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
                Dock = DockStyle.Fill,
                BackColor = Color.FromArgb(17, 27, 45),
                ForeColor = Color.FromArgb(244, 247, 252),
                BorderStyle = BorderStyle.FixedSingle
            };
        }
    }

    internal sealed class WattBarContext : ApplicationContext
    {
        private const double PersistenceIntervalSeconds = 30;

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        private readonly SettingsStore _settingsStore;
        private readonly SettingsData _settings;
        private readonly EnergyAccumulator _accumulator;
        private readonly PowerHistoryTracker _historyTracker;
        private readonly ComponentTelemetryReader _componentTelemetry;
        private readonly MonitorTelemetryReader _monitorTelemetry;
        private readonly NotifyIcon _notifyIcon;
        private readonly ContextMenuStrip _menu;
        private readonly DashboardForm _dashboard;
        private readonly RegisteredWaitHandle _showDashboardRegistration;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly ToolStripLabel _menuPower;
        private readonly ToolStripLabel _menuState;
        private readonly ToolStripLabel _menuUptime;
        private readonly ToolStripMenuItem _track;
        private readonly ToolStripMenuItem _reset;
        private readonly ToolStripMenuItem[] _intervalItems;

        private PowerReading _latestReading;
        private DateTime _lastPersistenceUtc;
        private bool _exiting;

        public WattBarContext(EventWaitHandle showDashboardEvent)
        {
            _settingsStore = new SettingsStore();
            _settings = _settingsStore.Load();
            _accumulator = new EnergyAccumulator(
                _settings.AccumulatedEnergyWh,
                _settings.AccumulatedTrackingSeconds);
            _historyTracker = new PowerHistoryTracker(_settings.PowerHistory);
            _componentTelemetry = new ComponentTelemetryReader();
            _monitorTelemetry = new MonitorTelemetryReader();
            _lastPersistenceUtc = DateTime.MinValue;

            _dashboard = new DashboardForm();
            _dashboard.RefreshRequested += delegate { RefreshReading(); };
            _dashboard.HistoryRequested += delegate { ShowHistory(); };
            _dashboard.TrackingToggled += delegate { ToggleTracking(); };
            _dashboard.TariffsRequested += delegate { EditTariffs(); };
            _dashboard.ResetRequested += delegate { ResetTracking(); };
            _dashboard.MonitorToggleRequested += delegate
            {
                ToggleMonitor(_dashboard.RequestedMonitorIndex);
            };
            _dashboard.RefreshIntervalChanged += delegate
            {
                SetRefreshInterval(_dashboard.SelectedRefreshSeconds);
            };
            _showDashboardRegistration = ThreadPool.RegisterWaitForSingleObject(
                showDashboardEvent,
                delegate
                {
                    if (_exiting || _dashboard.IsDisposed)
                    {
                        return;
                    }
                    try
                    {
                        _dashboard.BeginInvoke(new MethodInvoker(ShowDashboard));
                    }
                    catch (InvalidOperationException)
                    {
                    }
                },
                null,
                Timeout.Infinite,
                false);

            _menu = new ContextMenuStrip
            {
                ShowImageMargin = false,
                BackColor = Color.FromArgb(17, 27, 45),
                ForeColor = Color.FromArgb(244, 247, 252),
                Font = new Font("Segoe UI", 9F),
                Padding = new Padding(6)
            };

            ToolStripMenuItem openDashboard = new ToolStripMenuItem("Open Power Dashboard");
            openDashboard.Font = new Font(_menu.Font, FontStyle.Bold);
            openDashboard.Click += delegate { ShowDashboard(); };

            ToolStripMenuItem history = new ToolStripMenuItem("View power history");
            history.Click += delegate { ShowHistory(); };

            _menuPower = StatusLabel("Measuring live power…", true);
            _menuState = StatusLabel("Checking Windows power capability", false);
            _menuState.ForeColor = Color.FromArgb(151, 166, 187);
            _menuUptime = StatusLabel("System uptime  --", false);
            _menuUptime.ForeColor = Color.FromArgb(151, 166, 187);

            _track = new ToolStripMenuItem("Start energy tracking");
            _track.Click += delegate { ToggleTracking(); };

            ToolStripMenuItem tariffs = new ToolStripMenuItem("Electricity tariffs…");
            tariffs.Click += delegate { EditTariffs(); };

            _reset = new ToolStripMenuItem("Reset tracking totals…");
            _reset.Click += delegate { ResetTracking(); };

            ToolStripMenuItem refreshNow = new ToolStripMenuItem("Refresh now");
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

            ToolStripMenuItem exit = new ToolStripMenuItem("Quit WattBar");
            exit.Click += delegate { ExitThread(); };

            _menu.Items.Add(openDashboard);
            _menu.Items.Add(history);
            _menu.Items.Add(_menuPower);
            _menu.Items.Add(_menuState);
            _menu.Items.Add(_menuUptime);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(_track);
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
                    ShowDashboard();
                }
            };
            _notifyIcon.DoubleClick += delegate { ShowDashboard(); };

            _timer = new System.Windows.Forms.Timer();
            _timer.Tick += delegate { RefreshReading(); };
            ApplyRefreshInterval();
            RefreshReading();
            Persist(true);
            _timer.Start();
            _dashboard.ShowDashboard();
        }

        private static ToolStripLabel StatusLabel(string text, bool emphasized)
        {
            ToolStripLabel label = new ToolStripLabel(text);
            label.AutoSize = true;
            label.Padding = new Padding(8, 3, 8, 3);
            label.Font = new Font(
                "Segoe UI",
                9F,
                emphasized ? FontStyle.Bold : FontStyle.Regular);
            label.ForeColor = Color.FromArgb(244, 247, 252);
            label.IsLink = false;
            return label;
        }

        private void RefreshReading()
        {
            ComponentReading components = _componentTelemetry.Read();
            double displayWatts;
            MonitorPowerReading[] monitors = _monitorTelemetry.Read(
                _settings,
                out displayWatts);
            try
            {
                _latestReading = NativePowerReader.Read(
                    Math.Max(15, _settings.RefreshSeconds * 2.5));
            }
            catch (Exception error)
            {
                _latestReading = new PowerReading
                {
                    SystemWatts = null,
                    BatteryPercent = null,
                    PowerState = "Power telemetry unavailable",
                    Source = error.Message,
                    Capability = PowerCapability.ApiUnavailable,
                    TimestampUtc = DateTime.UtcNow
                };
            }
            ApplyTelemetry(_latestReading, components, monitors, displayWatts);
            bool historyChanged = _historyTracker.TryAdd(_latestReading);

            if (_settings.TrackEnergyUsage)
            {
                double maximumInterval = Math.Max(5, _settings.RefreshSeconds * 2.5);
                _accumulator.AddSample(
                    _latestReading.TrackedWatts,
                    _latestReading.TimestampUtc,
                    maximumInterval);
            }
            else
            {
                _accumulator.Pause();
            }
            if (historyChanged || _settings.TrackEnergyUsage)
            {
                Persist(false);
            }
            UpdateDisplay();
        }

        private void UpdateDisplay()
        {
            double? displayedWatts = _latestReading.TrackedWatts;
            string watts = FormatWatts(displayedWatts);
            _menuPower.Text = _latestReading.TrackedWatts.HasValue
                ? "Tracked total  •  " + watts
                : (_latestReading.ComponentWatts.HasValue
                    ? "CPU + GPU  •  " + FormatWatts(_latestReading.ComponentWatts)
                    : "Power  •  Source needed");
            string percent = _latestReading.BatteryPercent.HasValue
                ? "  •  Battery " + _latestReading.BatteryPercent.Value.ToString() + "%"
                : "";
            _menuState.Text = _latestReading.PowerState + percent;
            _menuUptime.Text = "System uptime  -  " +
                WattBarContext.FormatDuration(WattBarContext.SystemUptimeSeconds());
            _track.Checked = _settings.TrackEnergyUsage;
            _track.Text = _settings.TrackEnergyUsage
                ? "Pause energy tracking"
                : "Start energy tracking";
            _reset.Enabled = _accumulator.WattHours > 0 || _accumulator.ActiveSeconds > 0;

            for (int index = 0; index < _intervalItems.Length; index++)
            {
                _intervalItems[index].Checked =
                    (int)_intervalItems[index].Tag == _settings.RefreshSeconds;
            }

            string tooltip = displayedWatts.HasValue
                ? "WattBar | " + watts
                : "WattBar | Power source needed";
            _notifyIcon.Text = tooltip.Length <= 63 ? tooltip : tooltip.Substring(0, 63);
            _dashboard.UpdateDashboard(
                _latestReading,
                _settings,
                _accumulator,
                _historyTracker.Samples);
        }

        private static void ApplyTelemetry(
            PowerReading target,
            ComponentReading components,
            MonitorPowerReading[] monitors,
            double displayWatts)
        {
            target.CpuWatts = components.CpuWatts;
            target.CpuUtilizationPercent = components.CpuUtilizationPercent;
            target.GpuWatts = components.GpuWatts;
            target.GpuUtilizationPercent = components.GpuUtilizationPercent;
            target.ComponentWatts = components.CombinedWatts;
            target.Monitors = monitors;
            target.DisplayWatts = displayWatts;
            double? pcWatts = target.SystemWatts.HasValue
                ? target.SystemWatts
                : target.ComponentWatts;
            target.TrackedWatts = PowerMath.CombineKnownSources(
                pcWatts,
                target.DisplayWatts);
        }

        private void ShowDashboard()
        {
            RefreshReading();
            _dashboard.ShowDashboard();
        }

        private void ShowHistory()
        {
            RefreshReading();
            string currentSource = _latestReading == null
                ? "unavailable"
                : _latestReading.Source;
            using (PowerHistoryForm dialog = new PowerHistoryForm(
                _historyTracker.Samples,
                currentSource))
            {
                dialog.ShowDialog(_dashboard);
            }
        }

        private void ToggleTracking()
        {
            _settings.TrackEnergyUsage = !_settings.TrackEnergyUsage;
            if (!_settings.TrackEnergyUsage)
            {
                _accumulator.Pause();
            }
            Persist(true);
            RefreshReading();
        }

        private void ToggleMonitor(int index)
        {
            if (index < 0 || index > 2)
            {
                return;
            }
            _settings.ToggleDisplay(index);
            Persist(true);
            RefreshReading();
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
            SetRefreshInterval((int)item.Tag);
        }

        private void SetRefreshInterval(int seconds)
        {
            _settings.RefreshSeconds = seconds;
            ApplyRefreshInterval();
            Persist(true);
            RefreshReading();
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
            _showDashboardRegistration.Unregister(null);
            Persist(true);
            _notifyIcon.Visible = false;
            _dashboard.CloseForExit();
            _dashboard.Dispose();
            _componentTelemetry.Dispose();
            _monitorTelemetry.Dispose();
            _notifyIcon.Dispose();
            _menu.Dispose();
            _timer.Dispose();
            base.ExitThreadCore();
        }

        internal static string FormatWatts(double? watts)
        {
            return watts.HasValue ? String.Format("{0:F1} W", watts.Value) : "unavailable";
        }

        internal static double SystemUptimeSeconds()
        {
            return GetTickCount64() / 1000.0;
        }

        internal static string FormatEnergy(double wattHours)
        {
            double kilowattHours = wattHours / 1000.0;
            if (wattHours < 1)
            {
                return String.Format(
                    CultureInfo.InvariantCulture,
                    "{0:F3} Wh · {1:F5} kWh",
                    wattHours,
                    kilowattHours);
            }
            if (wattHours < 1000)
            {
                return String.Format(
                    CultureInfo.InvariantCulture,
                    "{0:F2} Wh · {1:F4} kWh",
                    wattHours,
                    kilowattHours);
            }
            return String.Format(
                CultureInfo.InvariantCulture,
                "{0:F3} kWh",
                kilowattHours);
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
            if (!DashboardForm.ShouldHideOnMinimize(
                    FormWindowState.Minimized,
                    false) ||
                DashboardForm.ShouldHideOnMinimize(
                    FormWindowState.Normal,
                    false) ||
                DashboardForm.ShouldHideOnMinimize(
                    FormWindowState.Minimized,
                    true))
            {
                return false;
            }
            if (WattBarContext.FormatDuration((5 * 86400) + (3 * 3600) + (12 * 60)) != "5d 3h 12m")
            {
                return false;
            }
            List<PowerHistorySample> historySamples = new List<PowerHistorySample>();
            PowerHistoryTracker historyTracker = new PowerHistoryTracker(historySamples);
            PowerReading wholeDeviceReading = new PowerReading
            {
                TrackedWatts = 175,
                SystemWatts = 150,
                DisplayWatts = 25,
                TimestampUtc = start
            };
            if (!historyTracker.TryAdd(wholeDeviceReading) ||
                historySamples.Count != 1 ||
                historySamples[0].Source != "Whole-device + display estimate")
            {
                return false;
            }
            wholeDeviceReading.TimestampUtc = start.AddMinutes(4);
            if (historyTracker.TryAdd(wholeDeviceReading))
            {
                return false;
            }
            wholeDeviceReading.TrackedWatts = 210;
            wholeDeviceReading.TimestampUtc = start.AddMinutes(5);
            if (!historyTracker.TryAdd(wholeDeviceReading))
            {
                return false;
            }
            PowerHistoryPeriodSummary[] periodSummaries =
                PowerHistoryAnalyzer.ByTimeOfDay(historySamples);
            int summarySampleCount = 0;
            for (int index = 0; index < periodSummaries.Length; index++)
            {
                summarySampleCount += periodSummaries[index].SampleCount;
            }
            if (PowerHistoryAnalyzer.Peak(historySamples).Watts != 210 ||
                PowerHistoryAnalyzer.Recent(historySamples, 1).Count != 1 ||
                summarySampleCount != 2)
            {
                return false;
            }
            List<PowerHistorySample> oldHistory = new List<PowerHistorySample>
            {
                new PowerHistorySample
                {
                    TimestampUtc = start.AddMonths(-6).AddMinutes(-1),
                    Watts = 100,
                    Source = "old"
                },
                new PowerHistorySample
                {
                    TimestampUtc = start.AddMonths(-6).AddMinutes(1),
                    Watts = 100,
                    Source = "valid"
                }
            };
            List<PowerHistorySample> normalizedHistory = PowerHistoryPolicy.Normalize(
                oldHistory,
                start);
            if (normalizedHistory.Count != 1 || normalizedHistory[0].Source != "valid")
            {
                return false;
            }
            List<PowerHistorySample> cappedHistory = new List<PowerHistorySample>();
            for (int index = 0; index <= PowerHistoryPolicy.MaximumSamples; index++)
            {
                cappedHistory.Add(new PowerHistorySample
                {
                    TimestampUtc = start.AddMinutes(-index),
                    Watts = 100,
                    Source = "test"
                });
            }
            if (PowerHistoryPolicy.Normalize(cappedHistory, start).Count !=
                PowerHistoryPolicy.MaximumSamples)
            {
                return false;
            }
            SettingsData migrationSettings = SettingsData.CreateDefault();
            List<PowerHistorySample> historyReference = migrationSettings.PowerHistory;
            migrationSettings.Validate();
            if (!Object.ReferenceEquals(historyReference, migrationSettings.PowerHistory))
            {
                return false;
            }
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
            if (PowerCapabilityCopy.GetGuidance(PowerCapability.NoBattery)
                    .IndexOf("external", StringComparison.OrdinalIgnoreCase) < 0 ||
                PowerCapabilityCopy.GetGuidance(PowerCapability.PluggedIn)
                    .IndexOf("plugged in", StringComparison.OrdinalIgnoreCase) < 0)
            {
                return false;
            }
            double? normalizedCpuWatts = ComponentTelemetryReader.Normalize(
                107152.0,
                1000.0,
                0,
                2000);
            if (!normalizedCpuWatts.HasValue ||
                !Near(normalizedCpuWatts.Value, 107.152) ||
                ComponentTelemetryReader.Normalize(
                    Double.NaN,
                    1000.0,
                    0,
                    2000).HasValue ||
                ComponentTelemetryReader.Normalize(
                    5000000.0,
                    1000.0,
                    0,
                    2000).HasValue)
            {
                return false;
            }

            MonitorPowerProfile[] displays = MonitorPowerProfile.KnownDisplays();
            if (displays.Length != 3 ||
                !Near(PowerMath.MonitorWatts(
                    displays[0],
                    MonitorPowerState.On,
                    true), 42.0) ||
                !Near(PowerMath.MonitorWatts(
                    displays[1],
                    MonitorPowerState.On,
                    true), 35.0) ||
                !Near(PowerMath.MonitorWatts(
                    displays[2],
                    MonitorPowerState.On,
                    true), 29.8) ||
                !Near(PowerMath.MonitorWatts(
                    displays[2],
                    MonitorPowerState.Standby,
                    true), 0.3) ||
                !Near(PowerMath.MonitorWatts(
                    displays[0],
                    MonitorPowerState.On,
                    false), 0.3) ||
                MonitorTelemetryReader.StateFromVcp(1) != MonitorPowerState.On ||
                MonitorTelemetryReader.StateFromVcp(4) != MonitorPowerState.Standby ||
                MonitorTelemetryReader.StateFromVcp(5) != MonitorPowerState.Standby)
            {
                return false;
            }
            SettingsData defaults = SettingsData.CreateDefault();
            if (!defaults.TrackEnergyUsage ||
                !defaults.IsDisplayEnabled(0) ||
                !defaults.IsDisplayEnabled(1) ||
                !defaults.IsDisplayEnabled(2))
            {
                return false;
            }
            defaults.ToggleDisplay(1);
            if (defaults.IsDisplayEnabled(1))
            {
                return false;
            }
            defaults.ToggleDisplay(1);
            if (!defaults.IsDisplayEnabled(1))
            {
                return false;
            }
            double? trackedTotal = PowerMath.CombineKnownSources(
                140,
                42.0 + 35.0 + 29.8);
            double? oneDisplayOff = PowerMath.CombineKnownSources(
                140,
                42.0 + 35.0 + 0.3);
            if (!trackedTotal.HasValue ||
                !oneDisplayOff.HasValue ||
                !Near(trackedTotal.Value, 246.8) ||
                !Near(oneDisplayOff.Value, 217.3))
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
        private const string MutexName = "Local\\WattBar.Windows";
        private const string ShowDashboardEventName = "Local\\WattBar.Windows.ShowDashboard";
        private static Mutex _mutex;

        [STAThread]
        public static int Main(string[] arguments)
        {
            if (arguments.Length > 0 &&
                String.Equals(arguments[0], "--self-test", StringComparison.OrdinalIgnoreCase))
            {
                return SelfTests.Run() ? 0 : 1;
            }

            using (EventWaitHandle showDashboardEvent = new EventWaitHandle(
                false,
                EventResetMode.AutoReset,
                ShowDashboardEventName))
            {
                bool createdNew;
                _mutex = new Mutex(true, MutexName, out createdNew);
                if (!createdNew)
                {
                    showDashboardEvent.Set();
                    _mutex.Dispose();
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                try
                {
                    Application.Run(new WattBarContext(showDashboardEvent));
                }
                finally
                {
                    _mutex.ReleaseMutex();
                    _mutex.Dispose();
                }
            }
            return 0;
        }
    }
}
