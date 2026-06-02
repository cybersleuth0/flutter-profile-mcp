# Changelog

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
