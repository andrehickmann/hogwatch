# hogwatch

Menu bar app for macOS (Apple Silicon) that shows system load at a glance and posts a notification
when it gets critical, naming the process behind it. Built after a Mac crawled at load 200 because
of forgotten test runs and two orphaned headless Chromiums that had been burning CPU for 15 days.

## Build and run

Needs the Xcode command line tools (Swift 6), macOS 15 or later. No dependencies, no Xcode project.

```sh
./build.sh           # build/Hogwatch.app
./build.sh install   # copy to ~/Applications and start (stops a running instance first)
./build.sh test      # self-check of the parsing and alert logic
```

On first start macOS asks whether hogwatch may send notifications — allow it.
`~/Applications/Hogwatch.app/Contents/MacOS/hogwatch --demo-alert` posts a test notification.
"Bei Anmeldung" in the panel starts it at login.

If the icon does not appear: on a MacBook with a notch, menu bar icons that do not fit are hidden
behind it. Cmd-drag other icons out of the menu bar, or move hogwatch further right.

## What it shows

| Tab | Content |
| --- | --- |
| CPU | load average, clock of performance/efficiency cores, top processes with origin (tool and working directory) |
| RAM | used memory split into apps, wired and compressed; pressure, swap; top processes by footprint (like Activity Monitor), VMs and XPC services named after their app |
| SSD | read/write MB/s, IOPS, top processes by disk IO (own processes only) |
| GPU | utilisation, clock, top processes |
| Temp | MacBook Pro 14" (M1 Pro) drawing with a heat map of the sensors; other Macs get a list. Throttling and low power mode |
| Docker | running containers with CPU, uptime, ports; stop button. The tab shows the container count |
| Ports | listening TCP ports of own processes (count in the tab, read every 10 s while the panel is open). Web servers open in the browser, others copy `localhost:<port>`; stop the process or container |

Above the tabs, a red banner lists **orphaned processes**: own processes whose parent died
(re-parented to launchd), that are no regular app, and that used more than 50 % CPU on average over
10 minutes. "Beenden" sends SIGTERM to the process and its children, SIGKILL after 3 s.
"Ignorieren" remembers the executable and tool.

The menu bar shows the 1-minute load; the background turns orange or red with the worst state
(load, memory pressure, throttling, orphans).

"Verlauf" opens a window with 15 minutes at 2 s resolution and 24 hours of minute averages,
kept in `~/Library/Application Support/hogwatch/history.jsonl`.

## Notifications

| When | Condition |
| --- | --- |
| Load critical | 1-min load ≥ 3 × cores for 2 min |
| Memory pressure | kernel level critical, or warning for 10 min |
| SSD | ≥ 200 MB/s or ≥ 3000 IOPS for 2 min |
| Throttling | thermal pressure moderate or worse for 1 min |
| Orphaned process | as described above, once per process |
| Container | ≥ 50 % CPU on average over 10 min, once per container |

Each alert fires at most every 15 minutes and only again after the value was back to normal.
Thresholds live in `Limits` in `Sources/Logic.swift`.

## Data sources

All readable without root:

- `ps` (setuid) for per-process CPU and memory — the only way to see root processes like `fseventsd`
- `proc_pid_rusage`, `KERN_PROCARGS2`, `proc_pidinfo` for disk IO, arguments and working directory (own processes)
- Mach `host_statistics`, `getloadavg`, sysctl (`vm.swapusage`, `kern.memorystatus_vm_pressure_level`)
- IOKit: `IOBlockStorageDriver` statistics, `IOAccelerator` utilisation and per-client GPU time
- Private APIs: `IOHIDEventSystemClient` (temperatures), `IOReport` (clock residencies), `com.apple.system.thermalpressurelevel`.
  If Apple removes them, those values show "–" and everything else keeps working.
- Docker Engine API over the Unix socket (via `curl`), `lsof` for listening ports

## Layout

```
Sources/Logic.swift        thresholds, parsers, sliding CPU window, alert gate (pure, tested)
Sources/Sensors.swift      sysctl, Mach, IOKit and private API readers
Sources/Sampler.swift      builds a snapshot: processes, Docker, ports
Sources/Monitor.swift      timer, history, alerts, actions, menu bar icon
Sources/Views.swift        panel, tabs, heat map
Sources/HistoryView.swift  history window
Sources/App.swift          app entry, notifications, --render dev aid
Tests/main.swift           self-check
```

`hogwatch --render <dir>` renders each tab to PNG and quits (development aid; scroll views stay empty).
