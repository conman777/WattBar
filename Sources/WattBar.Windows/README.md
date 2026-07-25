# Watt Bar for Windows

This is a native Windows system-tray implementation of Watt Bar. It keeps the
macOS application unchanged and uses Windows' own `CallNtPowerInformation`
system battery API.

## Run

From File Explorer, double-click `WattBar.Windows.cmd` in the repository root.
The launcher builds `WattBar.Windows.exe` the first time and starts it in the
notification area. Left- or right-click its tray icon to open the menu.

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

## Whole-device power capability

Windows' native battery state reports the current battery charge/discharge rate
in milliwatts. Watt Bar uses the absolute discharge rate as whole-laptop draw
while the machine is running on battery.

The same API does not provide universal total system or wall draw while the
laptop is plugged in, and desktops normally have no battery rate at all. Those
are supported capability states, not errors. Charging rate is not used as system
draw because it measures energy entering the battery and would produce a
misleading total.

For desktops, plugged-in laptops, or firmware that does not expose a valid
discharge rate, connect a plug-in power meter or smart plug and have its
integration update Watt Bar:

```powershell
.\Tools\Set-ExternalPowerSample.ps1 -Watts 42.7
```

This writes a numeric sample to:

```text
%LOCALAPPDATA%\WattBar\external-power-watts.txt
```

A fresh external sample is treated as the whole-device source and takes
precedence over battery telemetry. Samples older than 15 seconds or 2.5 refresh
intervals (whichever is longer) are rejected. Without either native discharge
power or a fresh external-meter sample, live watts show as unavailable and
energy accumulation pauses.

Tracking settings and totals are stored locally at:

```text
%LOCALAPPDATA%\WattBar\settings.json
```

No telemetry leaves the computer.
