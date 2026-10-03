# Changelog

All notable changes to dots are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/); versions track the app's
`MARKETING_VERSION` and the `vX.Y` release tags.

## [0.1] — 2026-10-03

First public release.

### Added
- **CPU mode:** per-core load as a matrix of dots, performance cores on top,
  efficiency cores with a hole; the matrix turns red as the chip nears its
  throttling temperature.
- **Memory mode:** used memory as a level meter, counted the way Activity
  Monitor does.
- **GPU mode:** GPU load, one bar per second.
- **Latency mode:** ICMP ping once a second with an adaptive scale; timeouts in
  red.
- **Battery mode** on Macs with a battery.
- Every mode takes the same space in the menu bar, so nothing shifts when you
  switch.
- Click opens Activity Monitor; right-click (or ⌥-click) opens the menu: mode,
  core legend, refresh rate (1–10 Hz) and Launch at Login.
