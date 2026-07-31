# Watt Bar for Windows

This is a native Windows system-tray implementation of Watt Bar. It keeps the
macOS application unchanged and uses Windows' own `CallNtPowerInformation`
system battery API.

## Run

From File Explorer, double-click `WattBar.Windows.cmd` in the repository root.
The launcher builds `WattBar.Windows.exe` the first time and opens its power
dashboard. Closing the dashboard keeps it running in the notification area.
Left-click the tray icon or launch WattBar again to reopen the dashboard.
Right-click the tray icon for quick actions.

The dashboard header and tray menu show the computer's current uptime in a
compact days/hours/minutes format, such as `5d 3h 12m`.

Requirements:

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- .NET Framework 4.8 (included with current Windows 10/11 installations)

## Build and test

In Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\BuildWattBar.Windows.ps1 -Test
```

The build uses the .NET Framework compiler already present on Windows and has
no package-manager or network dependency. The output is
`WattBar.Windows.exe`.

The repository build is not Authenticode-signed. Windows may show an
unrecognized-app warning for a downloaded executable; a publicly distributed
release should be signed with the publisher's Windows code-signing certificate.

## CPU and GPU component telemetry

WattBar reads CPU package power from the Windows `Energy Meter` performance
counter when the processor exposes an RAPL package instance. CPU utilization
comes from Windows processor performance counters.

On NVIDIA systems, WattBar reads GPU board power and GPU utilization directly
from the installed NVIDIA management library. These readers are local and do
not launch a command-line process on each refresh.

If whole-device power is unavailable but both CPU and GPU power are present,
WattBar measures their combined value. This remains a component estimate rather
than wall power: it excludes the motherboard, memory, storage, cooling,
peripherals, and power-supply conversion losses.

## Display power and sleep detection

This build includes researched profiles for the three displays detected on the
current system:

- ASUS ROG Swift OLED PG32UCDM: 42.0 W on, 0.5 W standby, 0.3 W off
- LG 24UD58: 35.0 W on, 0.5 W standby, 0.3 W off
- LG 27UK650: 29.8 W Energy Star on, 0.3 W standby/off

WattBar identifies these monitors through their Windows display IDs and polls
the standard DDC/CI VCP `0xD6` power-mode value. An on display contributes its
researched active figure; a sleeping or non-responding display contributes only
its standby/off figure. With all three on, displays add 106.8 W. The tracked
total is the available PC reading (whole-PC where available, otherwise measured
CPU + GPU) plus the live display total.

Each display row also has a persisted `ON`/`OFF` calculation control. Turning a
row off removes that model's active estimate immediately and retains only its
small off allowance. The control changes WattBar's calculation; it does not send
a hardware power-off command to the monitor.

These display values are researched model estimates. Actual draw varies with
brightness, HDR content, USB power delivery, and monitor settings.

Energy tracking starts automatically on a fresh installation. The dashboard
shows both an immediate cost-per-hour estimate from current watts and the
accumulated Wh/kWh and costs for tracked time. Tracking can still be paused and
resumed explicitly.

## Whole-device power capability

Windows' native battery state reports the current battery charge/discharge rate
in milliwatts. Watt Bar uses the absolute discharge rate as whole-laptop draw
while the machine is running on battery.

The same API does not provide universal total system or wall draw while the
laptop is plugged in, and desktops normally have no battery rate at all. Those
are supported capability states, not errors. Charging rate is not used as system
draw because it measures energy entering the battery and would produce a
misleading total.

For accurate total wall power on desktops, plugged-in laptops, or firmware that
does not expose a valid discharge rate, connect a plug-in power meter or smart
plug and have its integration update Watt Bar:

```powershell
.\Tools\Set-ExternalPowerSample.ps1 -Watts 42.7
```

This writes a numeric sample to:

```text
%LOCALAPPDATA%\WattBar\external-power-watts.txt
```

A fresh external sample is treated as the whole-PC source and takes precedence
over battery telemetry. Samples older than 15 seconds or 2.5 refresh intervals
(whichever is longer) are rejected. The display estimate is then added
separately, so external samples should not already include the monitors.

Tracking settings and totals are stored locally at:

```text
%LOCALAPPDATA%\WattBar\settings.json
```

No telemetry leaves the computer.
