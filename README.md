# flutter_profile_mcp

> An MCP (Model Context Protocol) server that connects to a running Flutter app via `vm_service` and exposes 27 performance, memory, and debugging tools as AI-queryable actions.

Ask Claude or Gemini **"why is my app slow?"** and get an actual diagnosis — not generic advice.

---

## What it does

Flutter DevTools is powerful but hard to use. This MCP server bridges the gap: it speaks directly to the Dart VM, collects the same data DevTools collects, and translates it into plain English that an AI agent can reason about and explain.

```
You:    "Why is my app slow?"

AI:     [calls connect_to_app]
        Connected. VM 3.11 | isolate: main | debug mode | iOS arm64

        [calls capture_frame_timing duration=5]
        Frame Analysis — 198 frames (~38.4 fps) via Flutter.Frame events
        Budget: 16ms at 60fps
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Janky: 0/198 (0.0%) — GOOD
        Worst frame: 4.54ms work (Build: 2.92ms, Raster: 1.61ms)

        [calls get_widget_rebuild_counts duration=8]
        Widget Rebuild Counts:
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Text (product_list.dart:142)            62 rebuilds  ← EXCESSIVE
          SizedBox (product_list.dart:98)         60 rebuilds  ← EXCESSIVE
          SlideTransition (home_screen.dart:31)   29 rebuilds  ← HIGH
          BlocProvider (main.dart:44)             26 rebuilds  ← HIGH

        Animation widgets rebuilding (possible idle animation leak):
          SlideTransition (home_screen.dart:31): 29 rebuilds
          → ensure AnimationController.dispose() called

        [calls get_cpu_hotspots duration=5]
        CPU Hotspots (5.0s window, 678 samples)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          1.  1.6%   13.3%  RenderObject._paintWithContext
          2.  1.1%    1.3%  Duration.Duration

        Suggestions:
        • RenderObject._paintWithContext: 13.3% total — expensive call chain. Check callees.
```

---

## Requirements

- Flutter app running in **debug or profile mode** (`flutter run` or `flutter run --profile`)
- Dart SDK ≥ 3.4.0
- Any MCP-compatible client (Claude Desktop, Claude Code, Gemini CLI, etc.)

---

## Installation

### Option A — pub.dev (recommended, no git clone needed)

```bash
dart pub global activate flutter_profile_mcp
```

This installs the `flutter-profile-mcp` command globally. Use this path in your MCP config:

```bash
which flutter-profile-mcp
# e.g. /Users/you/.pub-cache/bin/flutter-profile-mcp
```

### Option B — compile from source

```bash
git clone https://github.com/cybersleuth0/flutter-profile-mcp
cd flutter-profile-mcp
dart pub get
dart compile exe bin/flutter_devtools_mcp.dart -o flutter_devtools_mcp
```

### Option C — run directly with Dart

```bash
git clone https://github.com/cybersleuth0/flutter-profile-mcp
cd flutter-profile-mcp
dart pub get
```

---

## Claude Desktop setup

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS):

```json
{
  "mcpServers": {
    "flutter-profile": {
      "command": "flutter-profile-mcp"
    }
  }
}
```

> **Note:** `flutter-profile-mcp` must be on your PATH. Run `dart pub global activate flutter_profile_mcp` first, then verify with `which flutter-profile-mcp`.

Restart Claude Desktop after editing.

---

## Claude Code / Gemini CLI setup

Add to your project's `.claude/settings.json` or `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "flutter-profile": {
      "command": "flutter-profile-mcp"
    }
  }
}
```

---

## Usage

1. Run your Flutter app: `flutter run`
2. Copy the VM service URI from terminal output — looks like `ws://127.0.0.1:PORT/TOKEN=/ws`
3. Tell the AI: **"Connect to my Flutter app at `<uri>`"**
4. AI will show a health summary + available actions automatically

---

## What to ask the AI

After connecting, use these prompts exactly — the AI knows what to do:

### Performance problems
```
"My app feels slow when I scroll. Diagnose it."
"Why is my app janky? Check the patient list screen."
"The chart screen is slow. Find out why."
"Run a full performance analysis while I use the app."
```

### Memory problems
```
"Check my app's memory usage."
"Is my app leaking memory?"
"Why is my heap at 90%?"
"Show me what's using the most memory."
```

### Widget rebuild problems
```
"Which widgets are rebuilding too often?"
"Find excessive rebuilds on the home screen."
"Why does my UI feel choppy even though frames are fast?"
```

### Errors and logs
```
"Show me any errors in the last 10 seconds."
"Watch the logs while I trigger the crash."
"What HTTP requests is my app making?"
```

### Visual debugging
```
"Take a screenshot of my app."
"Show me the widget tree."
"Enable the performance overlay."
```

### General diagnosis
```
"My app is slow. Look at my screen and tell me what to do."
"Run a complete health check on my app."
"Why is my app using so much memory?"
```

> **Tip:** The AI will take a screenshot first to see your screen, then ask you to interact with the specific part that's slow before capturing data. This gives much more accurate results.

---

## Tools (28)

### Connection
| Tool | Description |
|------|-------------|
| `connect_to_app` | Connect to running Flutter app via VM service URI |
| `get_app_info` | Flutter/Dart version, build mode, isolates, all registered service extensions |

### Performance
| Tool | Description |
|------|-------------|
| `take_screenshot` | Capture current app screen as PNG — AI uses this to see your UI before giving specific guidance |
| `capture_frame_timing` | Record frame times via Flutter.Frame stream, detect jank (>16ms), identify UI vs raster bottleneck |
| `get_cpu_hotspots` | CPU profile — top Dart functions by self-time and call-chain cost, with fix suggestions |
| `get_widget_rebuild_counts` | Track which widgets rebuild excessively with file:line context — the #1 cause of jank |
| `analyze_jank_causes` | Composite: frames + CPU → synthesized verdict + prioritized diagnosis |
| `enable_performance_overlay` | Toggle on-screen GPU/UI thread bars |
| `debug_frame_events` | Inspect raw timeline event names — use when frame capture returns 0 frames |

### Memory
| Tool | Description |
|------|-------------|
| `get_memory_usage` | Heap usage + top allocating classes |
| `get_memory_timeline` | Record heap + GC events over N seconds — detects growing heap |
| `force_gc` | Trigger GC, compare before/after — high retained = leak signal |
| `diff_memory_snapshots` | Snapshot A → interact → snapshot B → show class growers |
| `find_memory_leaks` | Automated: GC → baseline → observe → GC → measure → leak candidates |
| `get_class_instances` | Instance count + size for any class by name |
| `watch_gc_pressure` | GC rate + avg pause → NORMAL / ELEVATED / CRITICAL verdict |
| `explain_memory_breakdown` | RSS vs Dart heap vs external vs raster in plain English |
| `disable_http_logging` | Disable HTTP logging to reduce memory overhead during profiling |

### Logging
| Tool | Description |
|------|-------------|
| `watch_logs` | Stream stdout/stderr/debugPrint for N seconds with optional filter |
| `get_error_logs` | Capture N seconds of output, return only error/exception lines |

### Network
| Tool | Description |
|------|-------------|
| `get_http_profile` | Recent HTTP requests with method, status, timing, size |
| `watch_network` | Live-stream new HTTP requests as they happen |
| `get_http_request_body` | Full request/response headers for a specific request ID |

### Navigation & Isolates
| Tool | Description |
|------|-------------|
| `get_navigation_stack` | Current route + full navigation stack — detect route leaks |
| `list_isolates` | All running isolates with heap usage |

### Visual Debugging
| Tool | Description |
|------|-------------|
| `toggle_visual_debug` | `debug_paint` (widget bounds) + `repaint_rainbow` (overdraw detection) |

### Code Evaluation
| Tool | Description |
|------|-------------|
| `eval_expression` | Evaluate Dart expression in live app context |

### Developer Workflow
| Tool | Description |
|------|-------------|
| `hot_reload` | Trigger hot reload — apply source changes without restarting |
| `get_widget_tree` | Full widget hierarchy as readable indented tree |

---

## Debug vs Profile mode

| Mode | Command | What works |
|------|---------|------------|
| Debug | `flutter run` | All 27 tools including widget inspector, rebuild counts |
| Profile | `flutter run --profile` | Performance tools (accurate numbers, no debug overhead) |
| Release | `flutter run --release` | **Nothing** — VM service not available |

For accurate frame/CPU numbers, use profile mode. For widget tree and rebuild tracking, use debug mode.

---

## How frame timing works

`capture_frame_timing` uses the `Flutter.Frame` extension event stream — the same source as Flutter DevTools' Performance tab. Flutter emits one event per frame containing pre-computed `build`, `raster`, and `elapsed` (wall time including vsync wait) in microseconds.

**Jank is measured on `build + raster` (actual CPU/GPU work), not `elapsed`.** `elapsed` always includes vsync idle time (~16ms at 60fps) which would make every frame appear janky.

---

## Architecture

```
flutter-profile-mcp/
├── bin/
│   └── flutter_devtools_mcp.dart     # Entry point — stdio MCP transport
├── lib/
│   ├── server.dart                   # MCPServer — all 27 tools registered
│   └── analysis/
│       ├── jank_analyzer.dart        # Flutter.Frame stream → frame data → jank report
│       ├── cpu_analyzer.dart         # CpuSamples → hotspot report (handles dynamic fn field)
│       └── rebuild_collector.dart    # RebuiltWidgets events → rebuild counts with file:line
```

Built with:
- [`dart_mcp`](https://pub.dev/packages/dart_mcp) — MCP server protocol
- [`vm_service`](https://pub.dev/packages/vm_service) — Dart VM service client

---

## Contributing

Tool ideas, bug reports, and PRs welcome.

To add a new tool:
1. Register it in `_registerTools()` in `lib/server.dart`
2. Add a `_handleXxx()` handler method
3. Use `_service!.callServiceExtension()` for Flutter extensions or direct `VmService` methods
4. Return `_ok(text)` on success, `_err(e)` on failure

---

## License

MIT — see [LICENSE](LICENSE)
