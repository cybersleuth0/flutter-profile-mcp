# Changelog

## 1.1.0

- hot_reload now goes through the `reloadSources` service registered by flutter run (fixes "Error while starting Kernel isolate task")
- analyze_jank_causes: frames + CPU captured concurrently over one window; verdict is INSUFFICIENT DATA under 30 frames and PARTIAL/INCOMPLETE when a sub-step fails; new `target_fps` param
- Auto-reconnect to the last URI after the VM service socket drops or hot restart; clear "Disconnected" errors with adb forward check on Android
- Picks the Flutter UI isolate instead of the first listed isolate
- Connect errors show input and tried URI; explain SocketException's local port; fix `/ws/ws` URI conversion
- Memory: stop reporting "% of heap capacity" as a limit (capacity grows on demand)
- Rebuild counts: labelled as summed over instances, with per-second and per-frame rates
- Debug-mode / Android-emulator caveat on frame verdicts
- `auto_scroll` option (Android, via adb) on capture_frame_timing, analyze_jank_causes, get_widget_rebuild_counts
- 33 → 18 tools. Merged: get_error_logs → watch_logs (errors_only);
  watch_gc_pressure → get_memory_timeline; explain_memory_breakdown → get_memory_usage; enable_performance_overlay → toggle_visual_debug.
  Removed: my_app_feels_slow, app_uses_too_much_memory, help (aliases), force_gc, diff_memory_snapshots (covered by find_memory_leaks),
  debug_frame_events + raw-timeline fallback, get_navigation_stack (its Flutter extension does not exist),
  HTTP tools (get_http_profile, get_http_request_body, watch_network, disable_http_logging) — use DevTools' Network tab;
  HTTP logging is no longer auto-enabled on connect
- watch_logs: captures dart:developer log() and structured Flutter errors (full text + widget file:line)
- "Your code" vs dependencies vs framework split in CPU hotspots, memory and leak reports, based on the app's root package
- find_memory_leaks: classes keyed by id (no more merged same-name classes), ignores VM-internal JIT objects, min growth 5
- Jank rule fixed: a frame is janky when build OR raster exceeds the budget (DevTools rule). It used to sum them, which double-counted pipelined threads and inflated jank
- connect_to_app accepts DevTools links (extracts the ?uri= VM service URI)
- FPS ignores idle gaps between interactions (no more false LOW FPS when the user pauses)
- Rebuild shared-parent groups are per file
- Rebuild counts skip the forced full-tree rebuild Flutter does when tracking starts (it was counted as ~1 rebuild per mounted widget on every run)
- get_widget_tree joins single-child wrapper chains on one line, so max_depth reaches real screens (bonorx has ~150 wrappers above its first screen)
- eval_expression shows object values via toString() (was just the type name)
- Removed noisy heuristics: ">100 instances = HIGH" in get_class_instances; GC pressure thresholds raised to 2/5 per sec
- CPU report warns when the app was idle (too few samples)
- Profile mode (tested on a physical Android phone): debug-only tools say so plainly; health check skips the screenshot; CPU report adds a framework section so time spent in Flutter itself (e.g. gesture dispatch) is visible
- eval_expression fixed: a running isolate was treated as paused, so every eval failed
- Screenshots fit 500x1000 at 1x (~90k base64 chars instead of ~1.7M)
- Upgrade dart_mcp 0.5.x, vm_service 15.x; SDK floor 3.7

## 1.0.8

- Add animated GIF demo preview to README
- Demo video linked from GitHub

## 1.0.7

- Beginner UX: run_health_check, my_app_feels_slow, app_uses_too_much_memory, help tools
- Rich instructions field guides AI tool selection automatically
- _nextSteps() hints in frame timing output
- _friendlyError() with human-readable connection error messages
- Tool descriptions rewritten: symptom-first "Use this when..." pattern
- Simplified connect output: 2-line guide instead of full menu
- README rewritten: problem-first, real example, what-to-say table

## 1.0.6

- Add take_screenshot tool — AI sees app screen before giving interaction guidance
- connect_to_app now shows memory health + guided tool menu on connect
- Android support: CPU profiler enable, scheduleFrame for frame timing
- CPU filter: resolvedUrl-based — works on iOS, Android, emulator without platform hacks
- Memory: show app classes (KB) separately from VM/framework classes — matches DevTools
- Tool descriptions include screenshot-first workflow for performance tools
- README: real user prompts guide

## 1.0.5

- Add pub.dev topics for discoverability
- Fix README example: replace app-specific filenames with generic ones

## 1.0.4

- Fix ready message: [flutter_devtools_mcp] → [flutter_profile_mcp]

## 1.0.3

- Fix README title (flutter_devtools_mcp → flutter_profile_mcp)

## 1.0.2

- Update README: add pub.dev install method, simplify MCP config

## 1.0.1

- Add `executables` entry so `dart pub global activate flutter_profile_mcp` installs `flutter-profile-mcp` command

## 1.0.0

- Initial release
- 27 tools for Flutter performance analysis via vm_service
- Frame timing via Flutter.Frame extension stream (same source as DevTools)
- Widget rebuild counts with file:line context and shared-parent detection
- CPU hotspots filtered to Dart user code, flags high call-chain cost
- Animation widget leak detection
- Jank diagnosis verdict box with synthesized PRIMARY cause
- Tested on iOS debug and profile mode, Dart VM 3.11 / service protocol 4.20
