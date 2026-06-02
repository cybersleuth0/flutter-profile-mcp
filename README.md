# flutter_profile_mcp

> Ask Claude or Gemini **"why is my app slow?"** — get a real diagnosis with file names, line numbers, and specific fixes. Not generic advice.

[![pub.dev](https://img.shields.io/pub/v/flutter_profile_mcp.svg)](https://pub.dev/packages/flutter_profile_mcp)

---

## What is this?

Flutter DevTools shows you the data. This package makes the AI **understand** it.

It's an MCP server — a bridge between your Flutter app and AI assistants like Claude or Gemini. The AI connects to your running app, captures real performance data, and tells you exactly what's wrong and where to fix it.

```
You:   "My app feels slow when I scroll."

AI:    [takes screenshot — sees your product list screen]
       I can see a scrollable list. Please scroll it up and down now...

       [captures 6 seconds of frame data + CPU]

       ┌─ JANK DIAGNOSIS ──────────────────────────┐
       │ ✗ SEVERE — 100% frames over budget         │
       │   PRIMARY: _FeedScreenState._buildItem      │
       └────────────────────────────────────────────┘

       95.8% of CPU is spent in _buildItem().
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
   An Observatory debugger and profiler on iPhone is available at:
   ws://127.0.0.1:PORT/TOKEN=/ws
   ```
3. Tell your AI: **"Connect to my Flutter app at `<paste URI here>`"**
4. The AI connects, takes a screenshot, and guides you from there.

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
| Watch network | `"What HTTP requests is my app making right now?"` |

> **How it works:** The AI takes a screenshot first so it can see what's on your screen. Then it asks you to interact with the slow part of your app while it captures data. This gives much more accurate results than just running blindly.

---

## Requirements

- Flutter app running in **debug or profile mode**
  - Debug: `flutter run` — all features including widget rebuild tracking
  - Profile: `flutter run --profile` — more accurate performance numbers
  - Release: **not supported** — VM service is unavailable
- Dart SDK ≥ 3.4.0
- Any MCP-compatible AI (Claude Desktop, Claude Code, Gemini CLI, Cursor, etc.)

---

## What the AI can check

### Performance
| Problem | Tool used by AI |
|---------|----------------|
| Is my app janky? | `my_app_feels_slow` → frames + CPU diagnosis |
| Which functions are slow? | `get_cpu_hotspots` |
| Which widgets rebuild too often? | `get_widget_rebuild_counts` (debug mode) |
| What does my UI look like right now? | `take_screenshot` |
| Full performance report | `run_health_check` |

### Memory
| Problem | Tool used by AI |
|---------|----------------|
| How much memory is my app using? | `get_memory_usage` |
| Is something leaking? | `find_memory_leaks` / `app_uses_too_much_memory` |
| What grew between two moments? | `diff_memory_snapshots` |

### Debugging
| Problem | Tool used by AI |
|---------|----------------|
| Any errors in the last N seconds? | `get_error_logs` |
| What's the app printing? | `watch_logs` |
| What HTTP calls is the app making? | `watch_network` / `get_http_profile` |
| Show me the widget tree | `get_widget_tree` |
| Apply my code changes | `hot_reload` |

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

**Important:** Jank is measured on `build + raster` (actual CPU/GPU work), **not** `elapsed`. The `elapsed` field includes vsync idle time (~16ms at 60fps), which would make every frame appear janky even when the app is perfectly smooth.

---

## Contributing

PRs and tool ideas welcome. To add a new tool:

1. Register in `_registerTools()` in `lib/server.dart`
2. Add a `_handleXxx()` handler
3. Use `_service!.callServiceExtension()` for Flutter extensions or `VmService` methods directly
4. Return `_ok(text)` on success, `_friendlyError(e)` on failure

---

## License

MIT — see [LICENSE](LICENSE)
