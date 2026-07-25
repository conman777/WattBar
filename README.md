# Watt Bar

Watt Bar is a lightweight power-telemetry utility with native menu-bar support
on macOS and native system-tray support on Windows.

The macOS version displays:

- Total system draw reported by `SystemLoad`
- Charger input reported by `SystemPowerIn`
- Battery charging or discharging power
- Estimated GPU power
- Optional accumulated energy, tracking time, and electricity costs
- The most active applications by CPU and memory usage

## macOS requirements

- Apple silicon Mac
- macOS 13 or later
- Xcode command-line tools

## Build on macOS

```sh
./BuildWattBar.sh
open WattBar.app
```

Builds are ad-hoc signed by default. To use a specific signing identity:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./BuildWattBar.sh
```

## Run on Windows

On Windows 10 or Windows 11, clone or download this repository and double-click:

```text
WattBar.Windows.cmd
```

The launcher builds `WattBar.Windows.exe` on first use and starts Watt Bar in
the Windows notification area. It uses Windows PowerShell 5.1 and .NET Framework
4.8, both included with current Windows 10/11 installations. The Windows build
has no NuGet, package-manager, or network dependency.

To build and run its automated tracking/formatting checks explicitly:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\BuildWattBar.Windows.ps1 -Test
```

The Windows tray menu provides live battery-discharge watts when the hardware
reports them or whole-device watts from an external meter bridge, persisted
tracking time and Wh/kWh totals, South Africa and United Kingdom costs, editable
tariffs, selectable refresh intervals, and reset controls. See
[the Windows-specific documentation](Sources/WattBar.Windows/README.md) for
telemetry limitations and packaging details.

## macOS power readings

Watt Bar keeps whole-device and battery/adapter values separate:

- **System draw** is the whole-device power reading used for tracking when
  macOS exposes `SystemLoad` or a fresh external-meter sample is present.
- **Adapter input** includes both system consumption and battery charging.
- **Battery flow** is positive while charging and negative while discharging.

GPU power is estimated from Apple's IOReport energy counters. The top-app list
uses CPU activity as a useful indicator; it does not assign exact watts to each
application.

Battery and charging information is supplementary. A desktop or Mac mini is a
normal Watt Bar target, but macOS does not provide a public, universal
whole-device wall-power value on that hardware. Without a valid native reading
or external-meter sample, Watt Bar reports the capability honestly and pauses
energy/cost accumulation rather than inventing watts.

## External whole-device meter bridge

On either platform, an external plug-in power meter or smart plug can provide
real whole-device watts to Watt Bar through a local numeric sample file. A fresh
external sample takes precedence over battery telemetry because it measures the
complete device at its power source.

On macOS, have the meter integration call:

```sh
./Tools/set-external-power-sample.sh 42.7
```

On Windows PowerShell, call:

```powershell
.\Tools\Set-ExternalPowerSample.ps1 -Watts 42.7
```

The helper writes only the numeric watts value, atomically, to the platform's
Watt Bar application-data directory. Update it at least once per refresh period.
Samples older than 15 seconds or 2.5 configured refresh intervals (whichever is
longer) are rejected, so a disconnected meter cannot silently keep accumulating
stale power.

## macOS energy and cost tracking

Choose **Track Energy Usage & Cost** in the menu to start or resume
tracking. WattBar integrates successive system-draw samples over time and stores
both the active tracking duration and accumulated total in watt-hours. Turning
tracking off pauses both values; the saved totals remain available when tracking
is turned on again. Use **Reset Tracking Totals…** to start new totals.

The displayed costs convert the total to kilowatt-hours
(`kWh = Wh / 1,000`) and multiply it by each configured per-kWh tariff. Choose
**Electricity Tariffs…** to enter the rates from your own bills. The initial
example rates are R3.50/kWh for South Africa and £0.2611/kWh for the UK. They
are not universal prices: tariffs vary by provider, municipality or region,
payment method, usage band, and time. The displayed totals exclude standing charges
and any other fixed fees.

Watt Bar does not invent energy usage for periods when the app is not running,
the Mac is asleep long enough to interrupt sampling, or system-load telemetry
is unavailable. On battery, macOS may only expose a whole-device discharge-rate
estimate. External meter accuracy is determined by the connected meter. As a
result, the source label should be considered part of every reading.

Tracking totals are saved in batches every 30 seconds and immediately when
tracking is paused, totals are reset, or the app quits normally. An unexpected
forced termination can lose up to the latest 30 seconds of tracking.

## Privacy

Watt Bar operates locally. It reads platform power telemetry (and process
telemetry for the macOS active-app list) and does not send that information to
an external service.

## Notes

The GPU estimate uses the system-provided `libIOReport` interface. This interface
is not part of Apple's documented public SDK and may change in future macOS releases.
