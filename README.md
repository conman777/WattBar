# WattBar

WattBar is a lightweight macOS menu-bar utility for viewing live power telemetry.

It displays:

- Total system draw reported by `SystemLoad`
- Charger input reported by `SystemPowerIn`
- Battery charging or discharging power
- Estimated GPU power
- The most active applications by CPU and memory usage

## Requirements

- Apple silicon Mac
- macOS 13 or later
- Xcode command-line tools

## Build

```sh
./BuildWattBar.sh
open WattBar.app
```

Builds are ad-hoc signed by default. To use a specific signing identity:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./BuildWattBar.sh
```

## Power readings

WattBar keeps the major power values separate:

- **System draw** is the power currently consumed by the Mac.
- **Adapter input** includes both system consumption and battery charging.
- **Battery flow** is positive while charging and negative while discharging.

GPU power is estimated from Apple's IOReport energy counters. The top-app list
uses CPU activity as a useful indicator; it does not assign exact watts to each
application.

## Privacy

WattBar operates locally. It reads macOS power and process telemetry and does not
send that information to an external service.

## Notes

The GPU estimate uses the system-provided `libIOReport` interface. This interface
is not part of Apple's documented public SDK and may change in future macOS releases.
