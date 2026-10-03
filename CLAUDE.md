# dots — agent guide

Tiny **AppKit** menu bar monitor for **Apple Silicon**, macOS 14+. One status
item draws the active mode — CPU, Memory, GPU, Latency, Battery — as a small
glyph. Small by intent: keep it compact, no dependencies, no SwiftUI.

## Build / verify

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project dots.xcodeproj -scheme dots -configuration Debug -derivedDataPath build build
pkill -x dots; open build/Build/Products/Debug/dots.app
```

- Must build with **no warnings**. Sources are a synchronized folder group — new
  files need no `pbxproj` edits.
- No test suite. Verify by build, a fresh process (`ps -p <pid> -o lstart=`)
  and no `dots*` crash in `~/Library/Logs/DiagnosticReports/`.
- The agent can't screenshot or read the status item's size: state visual
  changes as unverified and ask the user to look.
- Measure CPU / wakeups on a **Release** build per mode (`top -stats
  pid,cpu,idlew`) before claiming an efficiency win.

## Rules

- **App Sandbox stays off** — it blocks the ICMP socket, IOKit sensors and the
  LaunchAgent in `~/Library/LaunchAgents`.
- **Every mode draws into one box** (`Layout`): same width and height, or the
  neighbouring menu bar items shift on mode switch. A new mode picks its bar /
  cell count to fill the box, never its own size.
- **No text or numbers in the glyph** — brightness, fill and bar height only.
- **Run only the visible mode's monitors** (`applySettings`); a monitor
  quantizes its value and fires `onUpdate` only when it changes.
- **Never block the main thread** on DNS or sockets — `LatencyMonitor` does
  them on its own queue.
- `TempMonitor` uses the private IOHIDEventSystem SPI; failure must degrade to
  "no red tint", never a crash.
- Launch at Login is a hand-written LaunchAgent plist, not `SMAppService`.

## Release

The repository publishes **code only**. Building, signing, notarizing and
distributing live in untracked local files — `CLAUDE.local.md` is the entry
point. `CHANGELOG.md` follows Keep a Changelog and tracks `MARKETING_VERSION`
and the `vX.Y` tags.
