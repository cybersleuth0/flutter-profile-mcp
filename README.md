# flutter_profile_mcp

> Ask Claude or Gemini **"why is my app slow?"** — get a real diagnosis with file names, line numbers, and specific fixes. Not generic advice.

[![pub.dev](https://img.shields.io/pub/v/flutter_profile_mcp.svg)](https://pub.dev/packages/flutter_profile_mcp)

---

## Demo

[![Demo](https://raw.githubusercontent.com/cybersleuth0/flutter-profile-mcp/main/assets/demo_preview.gif)](https://github.com/cybersleuth0/flutter-profile-mcp/blob/main/assets/demo.mp4)

*Click to watch full video*

---

## What is this?

Flutter DevTools shows you the data. This package makes the AI **understand** it.

It's an MCP server — a bridge between your Flutter app and AI assistants like Claude or Gemini. The AI connects to your running app, captures real performance data, and tells you exactly what's wrong and where to fix it.

```
You:   "My app feels slow when I scroll."

AI:    [takes screenshot — sees your product list screen]
       I can see a scrollable list. Please scroll it up and down now...

       [captures 5 seconds of frames + CPU together]

       ┌─ JANK DIAGNOSIS (5s, frames + CPU captured together)
       │ ✗ SEVERE JANK — 34.0% frames over budget, 52.1fps
       │   TOP CPU: _FeedScreenState._buildItem (41.3% self)
       └──────────────────────────────────────────────

       41% of CPU is spent in your _buildItem().
       This function is running expensive work inside build().
       Fix: move heavy computation outside build() or use compute().
```

No manual charts. No guessing. Just answers.

---

## Quick start (3 steps)

### Step 1 — Install

```bash
dart pub global activate flutter_profile_mcp
```

### Step 2 — Add to your AI client

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "flutter-profile": {
      "command": "flutter-profile-mcp"
    }
  }
}
```

**Claude Code** — add to `~/.claude.json` (user-level) or your project's `.claude/settings.json`:
```json
{
  "mcpServers": {
    "flutter-profile": {
      "type": "stdio",
      "command": "flutter-profile-mcp"
    }
  }
}
```

**Gemini CLI** — add to `~/.gemini/settings.json`:
```json
{
  "mcpServers": {
    "flutter-profile": {
      "command": "flutter-profile-mcp"
    }
  }
}
```

Restart your AI client after editing.

### Step 3 — Use it

1. Run your Flutter app: `flutter run`
2. Copy the VM service URI printed in the terminal — looks like:
   ```
   A Dart VM Service on Pixel 9 is available at: http://127.0.0.1:51438/u0hZrUtJpIA=/
   ```
   `http://`, `ws://` and DevTools links all work.
3. Tell your AI: **"Connect to my Flutter app at `<paste URI here>`"**
4. The AI connects, takes a screenshot, and guides you from there.

If the app restarts or the connection drops, the server reconnects to the same URI automatically.

---

## What to say to the AI

You don't need to know any tool names. Just describe the problem:

| Problem | What to say |
|---------|-------------|
| App scrolls/animates slowly | `"My app feels slow. Diagnose it."` |
| Specific screen is laggy | `"The patient list screen is slow. Find out why."` |
| Memory keeps growing | `"Is my app leaking memory?"` |
| App crashes with OOM | `"My app is using too much memory. Check it."` |
| General check | `"Run a health check on my app."` |
| See current screen | `"Take a screenshot of my app."` |
| Find errors | `"Show me any crashes or errors in the last 10 seconds."` |

> **How it works:** The AI takes a screenshot first so it can see what's on your screen. Then it asks you to interact with the slow part of your app while it captures data. This gives much more accurate results than just running blindly.

---

## Requirements

- Flutter app running in **debug or profile mode**
  - Debug: `flutter run` — every tool works. Timings are inflated (JIT, asserts); results say so.
  - Profile: `flutter run --profile` on a **physical device** — real performance numbers. Emulators can't run profile builds.
  - Release: **not supported** — VM service is unavailable
- Dart SDK ≥ 3.7.0 (to run the server)
- Any MCP-compatible AI (Claude Desktop, Claude Code, Gemini CLI, Cursor, etc.)

---

## Tools (18)

**Mode:** Both = debug or profile. Debug = needs `flutter run` without `--profile`; in profile mode these tools say so instead of failing silently.

### Setup
| Tool | What it does | Mode |
|---|---|---|
| `connect_to_app` | Connect to the running app (auto-reconnects) | Both |
| `get_app_info` | Dart/VM version, build mode, platform, service extensions | Both |
| `list_isolates` | Isolates (main + background workers) with their heap | Both |

### Performance
| Tool | What it does | Mode |
|---|---|---|
| `analyze_jank_causes` | **Start here when it's slow.** Frames + CPU over the same window → HEALTHY / MINOR / SEVERE / INSUFFICIENT DATA | Both |
| `capture_frame_timing` | FPS, jank %, worst frames split into build vs raster | Both |
| `get_cpu_hotspots` | Hot functions, split into your code / dependencies / Flutter framework | Both |
| `get_widget_rebuild_counts` | Most-rebuilt widgets with file:line, rebuilds/sec, widgets sharing a parent | Debug |
| `run_health_check` | Screenshot + FPS + memory in one call, with next step | Both |

### Memory
| Tool | What it does | Mode |
|---|---|---|
| `find_memory_leaks` | **Start here when memory grows.** GC → wait → GC → classes still growing, your code first | Both |
| `get_memory_usage` | Heap, external memory, top classes split into yours / dependencies / framework | Both |
| `get_memory_timeline` | Heap delta and GC rate over N seconds | Both |
| `get_class_instances` | Count and size of classes matching a name | Both |

### Debugging
| Tool | What it does | Mode |
|---|---|---|
| `watch_logs` | `print`/`debugPrint`, `log()`, and Flutter errors with the widget's file:line. `errors_only` for crashes | Both |
| `take_screenshot` | Current screen as an image, so the AI can see it | Debug |
| `get_widget_tree` | Widget hierarchy; single-child wrapper chains joined on one line | Debug |
| `eval_expression` | Evaluate Dart in the live app | Debug |
| `hot_reload` | Apply code changes via `flutter run` | Debug |
| `toggle_visual_debug` | Debug paint, repaint rainbow, performance overlay | Debug (overlay: Both) |

### Hands-free capture on Android
`analyze_jank_causes`, `capture_frame_timing` and `get_widget_rebuild_counts` accept `auto_scroll: true` — the server swipes the screen via `adb` during the capture, so results are repeatable without a human. Requires `adb` on PATH. With several devices attached, set `ANDROID_SERIAL` in the MCP server's env:
```json
"flutter-profile": { "command": "flutter-profile-mcp", "env": { "ANDROID_SERIAL": "emulator-5554" } }
```

---

## How the AI diagnoses performance

The AI doesn't just dump raw data — it interprets it:

1. **Takes a screenshot** to see what screen you're on
2. **Tells you what to do** — "scroll this list", "tap that button", "open the chart"
3. **Captures data** while you interact (frames, CPU, or widget rebuilds)
4. **Synthesizes a verdict** — HEALTHY / MINOR JANK / SEVERE JANK
5. **Names the culprit** — exact Dart function or widget with file:line
6. **Suggests the fix** — "move out of build()", "add const", "cancel subscription in dispose()"

This is the same data Flutter DevTools shows you — but explained in plain English.

---

## Advanced setup

### Multiple AI clients

The binary is already on your PATH after `dart pub global activate`. Same command works everywhere:
```json
"command": "flutter-profile-mcp"
```

### Build from source

```bash
git clone https://github.com/cybersleuth0/flutter-profile-mcp
cd flutter-profile-mcp
dart pub get
dart compile exe bin/flutter_devtools_mcp.dart -o flutter_devtools_mcp
```

Then point your config to the compiled binary path.

---

## How frame timing actually works

`capture_frame_timing` uses Flutter's `Flutter.Frame` extension event stream — the same source as Flutter DevTools' Performance tab.

**Important:** A frame is janky when its build time **or** its raster time exceeds the budget — the same rule as DevTools. The UI and raster threads run in parallel, so their times are not added. `elapsed` is not used: it includes vsync idle time (~16ms at 60fps), which would make every frame look janky.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Could not reach the app` | `flutter run` stopped or restarted — the URI changes every run. Copy the new one. The `port =` in a SocketException is your local port, not the app's. |
| `Hot reload unavailable` | Hot reload goes through `flutter run`. Start the app with `flutter run` (debug) and connect to the URI it printed. |
| `needs debug mode` | That tool uses the widget inspector, which profile builds don't have. Performance and memory tools still work. |
| `INSUFFICIENT DATA` | Under 30 frames rendered — Flutter only draws when something changes. Scroll/animate during the capture, or use `auto_scroll` on Android. |
| `flutter run` hangs after install on some Android phones (seen on Vivo) | The phone masks the VM service URL in its logs (`listening on ****`). Run with `--disable-service-auth-codes`, find the app's listening port (`adb shell cat /proc/net/tcp`, state `0A`), then `adb forward tcp:PORT tcp:PORT` and connect to `http://127.0.0.1:PORT/`. Hot reload is unavailable this way. |
| Raster times of 30–50ms on an emulator | Emulator GPU, not real jank. Confirm with `flutter run --profile` on a physical device. |

---

## Contributing

PRs and tool ideas welcome. To add a new tool:

1. Register in `_registerTools()` in `lib/server.dart`
2. Add a `_handleXxx()` handler
3. Use `_service!.callServiceExtension()` for Flutter extensions or `VmService` methods directly
4. Start with `if (!await _ensureConnected()) return _notConnected();`, return `_ok(text)` on success, `_err(e)` on failure

---

## License

MIT — see [LICENSE](LICENSE)
