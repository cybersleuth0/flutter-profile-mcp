# flutter_devtools_mcp

> An MCP (Model Context Protocol) server that connects to a running Flutter app via `vm_service` and exposes 26 performance, memory, and debugging tools as AI-queryable actions.

Ask Claude (or any MCP-compatible AI) **"why is my app slow?"** and get an actual diagnosis — not generic advice.

---

## What it does

Flutter DevTools is powerful but hard to use. This MCP server bridges the gap: it speaks directly to the Dart VM, collects the same data DevTools collects, and translates it into plain English that an AI agent can reason about and explain.

```
You:   "My app feels janky when I scroll. Why?"

Claude: [calls connect_to_app]
        Connected. VM 3.4, isolate: main

        [calls analyze_jank_causes]
        23% frames janky — MODERATE
        UI thread: ProductCard.build() = 8.4% CPU self-time
        → Wrap static children in const, cache expensive computations

        [calls get_widget_rebuild_counts]
        ProductCard: 143 rebuilds ← EXCESSIVE
        → Use BlocSelector to narrow rebuild scope
```

---

## Requirements

- Flutter app running in **debug or profile mode** (`flutter run` or `flutter run --profile`)
- Dart SDK ≥ 3.4.0
- Any MCP-compatible client (Claude Desktop, Claude Code, etc.)

---

## Installation

### Option A — compile (recommended)

```bash
git clone https://github.com/ayushshende/flutter_devtools_mcp
cd flutter_devtools_mcp
dart pub get
dart compile exe bin/flutter_devtools_mcp.dart -o flutter_devtools_mcp
```

### Option B — run directly with Dart

```bash
git clone https://github.com/ayushshende/flutter_devtools_mcp
cd flutter_devtools_mcp
dart pub get
```

---

## Claude Desktop setup

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS):

```json
{
  "mcpServers": {
    "flutter-devtools": {
      "command": "/absolute/path/to/flutter_devtools_mcp"
    }
  }
}
```

Or without compiling:

```json
{
  "mcpServers": {
    "flutter-devtools": {
      "command": "dart",
      "args": ["run", "/absolute/path/to/flutter_devtools_mcp/bin/flutter_devtools_mcp.dart"]
    }
  }
}
```

Restart Claude Desktop after editing.

---

## Claude Code setup

Add to your project's `.claude/settings.json`:

```json
{
  "mcpServers": {
    "flutter-devtools": {
      "command": "/absolute/path/to/flutter_devtools_mcp"
    }
  }
}
```

---

## Usage

1. Run your Flutter app: `flutter run`
2. Copy the VM service URI from terminal output — looks like `http://127.0.0.1:PORT/TOKEN=/`
3. Tell Claude: **"Connect to my Flutter app at `<uri>`"**
4. Ask anything:
   - "Why is my app slow?"
   - "Are there any memory leaks?"
   - "Which widgets rebuild too often?"
   - "Show me recent HTTP requests"
   - "What errors appeared in the last 5 seconds?"

---

## Tools (26)

### Connection
| Tool | Description |
|------|-------------|
| `connect_to_app` | Connect to running Flutter app via VM service URI |
| `get_app_info` | Flutter/Dart version, build mode, isolates, all registered service extensions |

### Performance
| Tool | Description |
|------|-------------|
| `capture_frame_timing` | Record frame times, detect jank (>16ms), identify UI vs raster bottleneck |
| `get_cpu_hotspots` | CPU profile — top functions by self-time with fix suggestions |
| `get_widget_rebuild_counts` | Track which widgets rebuild excessively (the #1 cause of jank) |
| `analyze_jank_causes` | Composite: frames + CPU → prioritized diagnosis with specific fixes |
| `enable_performance_overlay` | Toggle on-screen GPU/UI thread bars |

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
| `watch_network` | Live-stream new HTTP requests as they happen — catch slow APIs in real time |
| `get_http_request_body` | Full request/response headers for a specific request ID |

### Navigation & Isolates
| Tool | Description |
|------|-------------|
| `get_navigation_stack` | Current route + full navigation stack — detect route leaks |
| `list_isolates` | All running isolates with heap usage — background workers visible here |

### Visual Debugging
| Tool | Description |
|------|-------------|
| `toggle_visual_debug` | `debug_paint` (widget bounds) + `repaint_rainbow` (overdraw detection) |

### Code Evaluation
| Tool | Description |
|------|-------------|
| `eval_expression` | Evaluate Dart expression in live app context — inspect variable values, list lengths, object state |

### Developer Workflow
| Tool | Description |
|------|-------------|
| `hot_reload` | Trigger hot reload — apply source changes without restarting |
| `get_widget_tree` | Full widget hierarchy as readable indented tree |

---

## Debug vs Profile mode

| Mode | Command | What works |
|------|---------|------------|
| Debug | `flutter run` | All 26 tools including widget inspector, rebuild counts |
| Profile | `flutter run --profile` | Performance tools (more accurate numbers, no debug overhead) |
| Release | `flutter run --release` | **Nothing** — VM service not available |

For accurate frame/CPU numbers, use profile mode. For widget tree and rebuild tracking, use debug mode.

---

## Architecture

```
flutter_devtools_mcp/
├── bin/
│   └── flutter_devtools_mcp.dart   # Entry point — stdio MCP transport
├── lib/
│   ├── server.dart                  # MCPServer subclass — all 26 tools registered here
│   └── analysis/
│       ├── jank_analyzer.dart       # Timeline → frame data → jank report
│       ├── cpu_analyzer.dart        # CpuSamples → hotspot report
│       └── rebuild_collector.dart   # Flutter.RebuiltWidgets events → rebuild counts
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
