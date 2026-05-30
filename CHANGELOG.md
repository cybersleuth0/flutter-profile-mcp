# Changelog

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
