# WattBar checks

Run the regression checks on an Apple silicon Mac with Xcode command-line tools:

```sh
./Tests/run.sh
```

To also exercise the native status display and menus, and read live network counters and system usage:

```sh
./Tests/run.sh --ui --live-network --live-system --menu-tracking
```

The UI checks briefly create a separate status item and keep settings in memory.
They do not change WattBar's preferences or saved energy totals, and leave no
files in ~/Library/Preferences. Live
network checks read interface counters only; they do not generate network traffic.
`--live-system` samples all-core CPU usage over one second and reads the two
macOS memory-pressure sysctls without privileges. Compare its available percentage
with `sysctl kern.memorystatus_vm_pressure_level kern.memorystatus_level` and
`memory_pressure | tail -1`.

Coverage includes 64-bit counters crossing 4 GiB, interface disconnect/reconnect,
counter resets and unavailable samples, CPU tick deltas and resets, memory pressure
percentage/level mapping (including unknown levels), idle-process RAM aggregation, energy
persistence and pause/reset behavior, typed power-flow formatting and the menu's
flow line, menu-bar graph bucketing, scaling, style and settings (including fixed 0–100% CPU
and memory graphs), warning tints, two-row panels with and without a fan,
menu actions, compact/full display combinations, stable status-item width,
aligned menu-bar columns, view-backed menu sections, asynchronous loading and
cancellation, CPU sensor metadata cache recovery, and fan speed readings
(fanless, stopped and invalid values). The optional
`--menu-tracking` check briefly opens a native test menu and verifies that
asynchronous results arrive before it closes.

Set `WATTBAR_TEST_OUTPUT` to a directory to save PNG captures of the menu
dashboard, menu sections and menu bar readout, in light and dark appearance.
Includes normal/warning/critical memory panels (with and without a fan), and CPU
normal/high plus memory normal/warning/critical/unknown graphs in both styles.

The menu deliberately displays a snapshot captured immediately before opening.
The status item resumes updating after the menu closes, avoiding AppKit anchor
resizing during menu tracking.
