import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'analysis/jank_analyzer.dart';
import 'analysis/cpu_analyzer.dart';
import 'analysis/rebuild_collector.dart';

final class FlutterDevToolsMCPServer extends MCPServer with ToolsSupport {
  FlutterDevToolsMCPServer({required StreamChannel<String> channel})
      : super.fromStreamChannel(
          channel,
          implementation: Implementation(
            name: 'flutter_devtools_mcp',
            version: '0.1.0',
          ),
          instructions:
              'Query a running Flutter app for performance data. '
              'Call connect_to_app first with the VM service URI printed by flutter run.',
        );

  VmService? _service;
  String? _isolateId;
  final _jank = JankAnalyzer();
  final _cpu = CpuAnalyzer();

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    return result;
  }

  void _registerTools() {
    registerTool(
      Tool(
        name: 'connect_to_app',
        description: 'Connect to a running Flutter app via its VM service URI. '
            'The URI is printed by flutter run, e.g.: http://127.0.0.1:PORT/TOKEN=/',
        inputSchema: ObjectSchema(
          properties: {
            'uri': StringSchema(
                description:
                    'VM service URI from flutter run output (http:// or ws://)'),
          },
          required: ['uri'],
        ),
      ),
      _handleConnect,
    );

    registerTool(
      Tool(
        name: 'capture_frame_timing',
        description:
            'Record frame render times for N seconds and identify janky frames '
            '(over 16ms at 60fps). Returns frame count, jank %, and worst frames.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Recording window in seconds (default: 3)'),
            'target_fps':
                NumberSchema(description: 'Target frame rate: 60 or 120 (default: 60)'),
          },
        ),
      ),
      _handleFrameTiming,
    );

    registerTool(
      Tool(
        name: 'get_cpu_hotspots',
        description:
            'Sample CPU usage and return top functions by self-time. '
            'Identifies which Dart code consumes the most CPU.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Sampling window in seconds (default: 2)'),
            'top_n': NumberSchema(
                description: 'Number of functions to return (default: 10)'),
          },
        ),
      ),
      _handleCpuHotspots,
    );

    registerTool(
      Tool(
        name: 'get_widget_rebuild_counts',
        description:
            'Track which widgets rebuild most often during user interaction. '
            'Excessive rebuilds are the #1 cause of Flutter jank.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Observation window in seconds (default: 5)'),
          },
        ),
      ),
      _handleRebuildCounts,
    );

    registerTool(
      Tool(
        name: 'get_memory_usage',
        description:
            'Get current heap memory usage and the top classes by allocation size.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleMemory,
    );

    registerTool(
      Tool(
        name: 'analyze_jank_causes',
        description:
            'Composite tool: captures frame timing + CPU profile together, '
            'then returns a prioritized diagnosis of why the app is janky with fix suggestions.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Total recording window in seconds (default: 5)'),
          },
        ),
      ),
      _handleJankDiagnosis,
    );

    registerTool(
      Tool(
        name: 'get_http_profile',
        description:
            'List recent HTTP requests made by the app with method, status, timing, and size.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': NumberSchema(
                description: 'Max number of requests to return (default: 20)'),
          },
        ),
      ),
      _handleHttpProfile,
    );

    registerTool(
      Tool(
        name: 'enable_performance_overlay',
        description:
            'Toggle the on-screen performance overlay bars on the running app. '
            'Top bar = GPU/raster thread, bottom bar = UI/Dart thread. Red = over budget.',
        inputSchema: ObjectSchema(
          properties: {
            'enabled': BooleanSchema(description: 'true to show, false to hide'),
          },
          required: ['enabled'],
        ),
      ),
      _handleOverlay,
    );

    registerTool(
      Tool(
        name: 'hot_reload',
        description:
            'Trigger a hot reload on the running Flutter app. '
            'Use after editing source files to apply changes without restarting. '
            'Only works in debug mode.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleHotReload,
    );

    registerTool(
      Tool(
        name: 'get_widget_tree',
        description:
            'Get the current widget tree as a readable hierarchy. '
            'Shows widget types, nesting depth, and child counts. '
            'Useful for spotting unnecessary nesting, missing const, or unexpected rebuilds.',
        inputSchema: ObjectSchema(
          properties: {
            'max_depth': NumberSchema(
                description: 'Max tree depth to display (default: 6)'),
          },
        ),
      ),
      _handleWidgetTree,
    );

    registerTool(
      Tool(
        name: 'toggle_visual_debug',
        description:
            'Toggle visual debugging overlays on the running app. '
            'debug_paint draws widget bounds/padding. '
            'repaint_rainbow colors layers that repaint (find overdraw). '
            'Both can be on simultaneously.',
        inputSchema: ObjectSchema(
          properties: {
            'debug_paint': BooleanSchema(
                description: 'Show widget bounds and padding lines'),
            'repaint_rainbow': BooleanSchema(
                description:
                    'Color repainting layers — cycling hue = repainting'),
          },
        ),
      ),
      _handleVisualDebug,
    );

    registerTool(
      Tool(
        name: 'get_memory_timeline',
        description:
            'Record RSS, heap usage, and GC events over N seconds. '
            'Detects memory leaks — a heap that grows and never drops after GC is a leak.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Recording window (default: 5)'),
          },
        ),
      ),
      _handleMemoryTimeline,
    );

    registerTool(
      Tool(
        name: 'force_gc',
        description:
            'Force a garbage collection then return heap before/after sizes. '
            'If heap stays high after GC, objects are being retained (possible leak).',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleForceGc,
    );

    registerTool(
      Tool(
        name: 'diff_memory_snapshots',
        description:
            'Take two heap snapshots with a pause between them. '
            'Reports which classes grew in instance count — the growers are your leak candidates.',
        inputSchema: ObjectSchema(
          properties: {
            'pause_seconds': NumberSchema(
                description:
                    'Seconds between snapshots — interact with app during this window (default: 5)'),
          },
        ),
      ),
      _handleMemoryDiff,
    );

    registerTool(
      Tool(
        name: 'find_memory_leaks',
        description:
            'Automated leak detection: force GC → baseline snapshot → wait → force GC → '
            'second snapshot → report classes still growing despite GC. '
            'High confidence leak signal.',
        inputSchema: ObjectSchema(
          properties: {
            'observe_seconds': NumberSchema(
                description:
                    'Seconds to observe between GC cycles (default: 5). Interact with app during this window.'),
          },
        ),
      ),
      _handleFindLeaks,
    );

    registerTool(
      Tool(
        name: 'get_class_instances',
        description:
            'Get instance count and total size for a specific class. '
            'Useful for checking if a widget/object is being over-retained.',
        inputSchema: ObjectSchema(
          properties: {
            'class_name': StringSchema(
                description: 'Class name to search for, e.g. _InheritedProviderScopeElement'),
          },
          required: ['class_name'],
        ),
      ),
      _handleClassInstances,
    );

    registerTool(
      Tool(
        name: 'watch_gc_pressure',
        description:
            'Monitor GC events for N seconds and report frequency, average pause, '
            'and whether GC pressure is normal, elevated, or critical.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Observation window (default: 5)'),
          },
        ),
      ),
      _handleGcPressure,
    );

    registerTool(
      Tool(
        name: 'explain_memory_breakdown',
        description:
            'Explain current memory in plain English: what RSS, allocated, Dart heap, '
            'external/native, and raster memory mean and whether the values look healthy.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleMemoryBreakdown,
    );

    registerTool(
      Tool(
        name: 'disable_http_logging',
        description:
            'Disable HTTP traffic logging to reduce memory overhead during profiling. '
            'Re-enable when done profiling.',
        inputSchema: ObjectSchema(
          properties: {
            'enabled': BooleanSchema(
                description: 'true = enable HTTP logging, false = disable it'),
          },
          required: ['enabled'],
        ),
      ),
      _handleHttpLogging,
    );

    // ── Logging ──────────────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'watch_logs',
        description:
            'Stream stdout/stderr/debugPrint output from the running Flutter app for N seconds. '
            'Returns all console output — the same as what you see in the flutter run terminal.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'How long to capture logs (default: 5)'),
            'filter': StringSchema(
                description: 'Optional substring filter — only return lines containing this string'),
          },
        ),
      ),
      _handleWatchLogs,
    );

    registerTool(
      Tool(
        name: 'get_error_logs',
        description:
            'Capture console output for N seconds and return only error/exception lines. '
            'Filters for: Error, Exception, FATAL, assert, Unhandled, FlutterError.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Capture window (default: 5)'),
          },
        ),
      ),
      _handleErrorLogs,
    );

    // ── Network ───────────────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'get_http_request_body',
        description:
            'Fetch the full request and response body for a specific HTTP request by its ID. '
            'Get IDs from get_http_profile.',
        inputSchema: ObjectSchema(
          properties: {
            'request_id': StringSchema(description: 'Request ID from get_http_profile'),
          },
          required: ['request_id'],
        ),
      ),
      _handleHttpRequestBody,
    );

    registerTool(
      Tool(
        name: 'watch_network',
        description:
            'Live-stream new HTTP requests as they happen for N seconds. '
            'Useful for catching the slow API call in real time during interaction.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Observation window (default: 5)'),
            'slow_threshold_ms': NumberSchema(
                description: 'Flag requests slower than this (default: 500ms)'),
          },
        ),
      ),
      _handleWatchNetwork,
    );

    // ── Navigation / State ────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'get_navigation_stack',
        description:
            'Get current route name and full navigation stack. '
            'Detects stuck navigation, leaked routes, and unexpected stack depth.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleNavigationStack,
    );

    registerTool(
      Tool(
        name: 'list_isolates',
        description:
            'List all running Dart isolates with their name, state, and heap usage. '
            'Background workers (compute, Isolate.spawn) show up here — each has its own heap.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleListIsolates,
    );

    // ── Code eval ────────────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'eval_expression',
        description:
            'Evaluate a Dart expression in the context of the running app and return the result. '
            'Useful for inspecting live state: variable values, list lengths, object properties. '
            'Example: "myController.text" or "Navigator.of(context).canPop()".',
        inputSchema: ObjectSchema(
          properties: {
            'expression': StringSchema(description: 'Dart expression to evaluate'),
            'frame_index': NumberSchema(
                description: 'Stack frame index to evaluate in (default: 0 = top frame)'),
          },
          required: ['expression'],
        ),
      ),
      _handleEvalExpression,
    );

    // ── App info ─────────────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'get_app_info',
        description:
            'Get Flutter version, Dart version, build mode (debug/profile/release), '
            'target platform, isolate count, and available service extensions. '
            'Run this first to understand the app environment.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleAppInfo,
    );

    registerTool(
      Tool(
        name: 'debug_frame_events',
        description:
            'Diagnostic tool: record timeline for N seconds and return all unique event names seen. '
            'Use this if capture_frame_timing returns no data — it shows what the engine actually emits.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Recording window (default: 3)'),
          },
        ),
      ),
      _handleDebugFrameEvents,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  CallToolResult _notConnected() => CallToolResult(
        content: [TextContent(text: 'Not connected. Call connect_to_app first.')],
        isError: true,
      );

  CallToolResult _ok(String text) =>
      CallToolResult(content: [TextContent(text: text)]);

  CallToolResult _err(Object e) => CallToolResult(
        content: [TextContent(text: 'Error: $e')],
        isError: true,
      );

  String _toWsUri(String uri) {
    var u = uri.trim();
    if (!u.startsWith('ws')) {
      u = u
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');
    }
    if (!u.endsWith('/ws')) {
      u = u.replaceAll(RegExp(r'/?$'), '/ws');
    }
    return u;
  }

  // ── Handlers ──────────────────────────────────────────────────────────────

  Future<CallToolResult> _handleConnect(CallToolRequest req) async {
    try {
      final uri = req.arguments!['uri'] as String;
      final wsUri = _toWsUri(uri);
      stderr.writeln('[mcp] connecting to $wsUri');
      _service = await vmServiceConnectUri(wsUri);
      final vm = await _service!.getVM();
      _isolateId = vm.isolates!.first.id!;
      final ver = await _service!.getVersion();
      return _ok(
          'Connected. VM ${ver.major}.${ver.minor} | isolate: ${vm.isolates!.first.name} ($_isolateId)');
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleFrameTiming(CallToolRequest req) async {
    if (_service == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;
      final fps = (req.arguments?['target_fps'] as num?)?.toInt() ?? 60;

      // Primary: Flutter.Frame extension stream (pre-computed FrameTiming — same as DevTools)
      final frames = await _jank.collectFromFrameTimings(
          _service!, _isolateId!, Duration(seconds: dur));

      if (frames.isNotEmpty) {
        final report =
            _jank.generateReport(frames, targetFps: fps, fromFrameTimings: true);
        return _ok(report);
      }

      // Fallback: parse raw timeline (profile mode or extension stream unavailable)
      await _service!.setVMTimelineFlags(['Embedder', 'Dart', 'GC', 'API']);
      await _service!.clearVMTimeline();
      await Future.delayed(Duration(seconds: dur));
      final timeline = await _service!.getVMTimeline();

      final fallbackFrames = _jank.parseFrames(timeline);
      if (fallbackFrames.isEmpty) {
        final counts = _jank.debugFrameCounts(timeline);
        final total = counts['total_events'] ?? 0;
        final uiCount = counts['ui_async_frames'] ?? 0;
        final rasterCount = counts['raster_frames'] ?? 0;
        if (total > 0) {
          return _ok(
              'Timeline captured $total events but no frames parsed.\n'
              'Raw frame markers: UI=$uiCount, Raster=$rasterCount\n\n'
              'App may have been idle. Interact during the recording window.\n'
              'Run debug_frame_events to inspect event names.');
        }
        return _ok(
            'No timeline events. Interact with app during the ${dur}s window.');
      }

      final counts = _jank.debugFrameCounts(timeline);
      final report = _jank.generateReport(fallbackFrames, targetFps: fps);
      final rawNote =
          'Raw: UI=${counts['ui_async_frames']} raster=${counts['raster_frames']} total=${counts['total_events']}';
      return _ok('$report\n[$rawNote]');
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleCpuHotspots(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 2;
      final topN = (req.arguments?['top_n'] as num?)?.toInt() ?? 10;

      final t0 = (await _service!.getVMTimelineMicros()).timestamp!;
      await Future.delayed(Duration(seconds: dur));
      final t1 = (await _service!.getVMTimelineMicros()).timestamp!;

      final samples =
          await _service!.getCpuSamples(_isolateId!, t0, t1 - t0);
      return _ok(_cpu.generateHotspotReport(samples, topN: topN));
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleRebuildCounts(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
      final collector = RebuildCollector();

      // Start listening BEFORE enabling — first event includes locations map
      collector.start(_service!);
      await _service!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: _isolateId,
        args: {'enabled': true},
      );
      await Future.delayed(Duration(seconds: dur));
      await _service!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: _isolateId,
        args: {'enabled': false},
      );

      return _ok(await collector.stopAndReport());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleMemory(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final mem = await _service!.getMemoryUsage(_isolateId!);
      final profile =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      final heapMB = (mem.heapUsage! / 1e6).toStringAsFixed(1);
      final capMB = (mem.heapCapacity! / 1e6).toStringAsFixed(1);
      final extMB = (mem.externalUsage! / 1e6).toStringAsFixed(1);
      final pct = (mem.heapUsage! / mem.heapCapacity! * 100).toStringAsFixed(0);

      final sb = StringBuffer();
      sb.writeln(
          'Memory: $heapMB MB heap ($pct% of $capMB MB) + $extMB MB external');
      sb.writeln('');
      sb.writeln('Top classes by memory:');

      final classes = (profile.members ?? [])
        ..sort((a, b) =>
            (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));

      for (final c in classes.take(10)) {
        if ((c.bytesCurrent ?? 0) == 0) continue;
        final name = c.classRef?.name ?? '?';
        final bytes = (c.bytesCurrent! / 1e6).toStringAsFixed(2);
        final inst = c.instancesCurrent ?? 0;
        sb.writeln(
            '  ${name.padRight(30)} $inst instances — $bytes MB');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleJankDiagnosis(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 6;
    final half = (dur / 2).ceil().clamp(2, 30);

    // Runs sequentially: half seconds for frames, then half for CPU = dur total
    final frameResult = await _handleFrameTiming(
      CallToolRequest(name: 'capture_frame_timing', arguments: {
        'duration_seconds': half,
        'target_fps': 60,
      }),
    );
    final cpuResult = await _handleCpuHotspots(
      CallToolRequest(name: 'get_cpu_hotspots', arguments: {
        'duration_seconds': half,
        'top_n': 5,
      }),
    );

    final frameTxt = (frameResult.content.first as TextContent).text;
    final cpuTxt = (cpuResult.content.first as TextContent).text;

    // Synthesize verdict from both reports
    final verdict = _synthesizeVerdict(frameTxt, cpuTxt);
    return _ok('$verdict\n'
        '(Recorded ${half}s frames + ${half}s CPU = ${half * 2}s total)\n\n'
        '━━ FRAME ANALYSIS ━━\n$frameTxt\n\n'
        '━━ CPU PROFILE ━━\n$cpuTxt');
  }

  String _synthesizeVerdict(String frameTxt, String cpuTxt) {
    final sb = StringBuffer();
    sb.writeln('┌─ JANK DIAGNOSIS ─────────────────────────────────────────┐');

    // Parse jank % from frame report
    final jankMatch = RegExp(r'Janky: \d+/\d+ \((\d+\.\d+)%\)').firstMatch(frameTxt);
    final jankPct = double.tryParse(jankMatch?.group(1) ?? '0') ?? 0;

    // Parse fps
    final fpsMatch = RegExp(r'~(\d+\.\d+) fps').firstMatch(frameTxt);
    final fps = double.tryParse(fpsMatch?.group(1) ?? '60') ?? 60;

    // Parse top CPU hotspot self%
    final cpuMatch = RegExp(r'1\.\s+([\d.]+)%\s+([\d.]+)%\s+(.+)').firstMatch(cpuTxt);
    final topSelfPct = double.tryParse(cpuMatch?.group(1) ?? '0') ?? 0;
    final topFn = cpuMatch?.group(3)?.trim() ?? '';

    if (jankPct == 0 && fps >= 55) {
      sb.writeln('│ ✓ HEALTHY — No jank detected. App running smoothly.      │');
    } else if (jankPct > 20) {
      sb.writeln('│ ✗ SEVERE JANK — $jankPct% frames over budget             │');
      if (topSelfPct > 5) {
        sb.writeln('│   PRIMARY: CPU bottleneck in $topFn');
      } else if (fps < 45) {
        sb.writeln('│   PRIMARY: Frame drops (${fps}fps) — UI thread blocked between frames');
      }
    } else if (fps < 50) {
      sb.writeln('│ ⚠ LOW FPS — ${fps}fps (target 60). Frames slow to start. │');
      sb.writeln('│   LIKELY: UI thread blocked by non-build work             │');
      sb.writeln('│   CHECK: scroll listeners, timers, BLoC stream emissions  │');
    } else {
      sb.writeln('│ ~ MINOR — $jankPct% jank, ${fps}fps                       │');
    }

    sb.writeln('└───────────────────────────────────────────────────────────┘');
    return sb.toString();
  }

  Future<CallToolResult> _handleHttpProfile(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 20;
      final profile = await _service!.getHttpProfile(_isolateId!);
      final requests = profile.requests.take(limit).toList();

      if (requests.isEmpty) return _ok('No HTTP requests recorded.');

      final sb = StringBuffer();
      sb.writeln('Recent HTTP requests:');
      for (final r in requests) {
        final ms = r.endTime != null
            ? r.endTime!.difference(r.startTime).inMilliseconds
            : -1;
        final msStr = ms >= 0 ? '${ms}ms' : 'pending';
        final flag = ms > 1000
            ? ' ← SLOW'
            : ms < 0
                ? ' ← PENDING'
                : '';
        final statusCode = r.response?.statusCode?.toString() ?? '?';
        sb.writeln(
            '  ${r.method.padRight(6)} ${r.uri.toString().padRight(50)} '
            '$statusCode  $msStr$flag');
      }
      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleOverlay(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final enabled = req.arguments!['enabled'] as bool;
      await _service!.callServiceExtension(
        'ext.flutter.showPerformanceOverlay',
        isolateId: _isolateId,
        args: {'enabled': enabled},
      );
      return _ok(enabled
          ? 'Performance overlay ON. Top bar = GPU thread, bottom bar = UI thread. Red = over budget.'
          : 'Performance overlay OFF.');
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleHotReload(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final report = await _service!.reloadSources(_isolateId!, force: false);
      final success = report.success ?? false;
      if (success) {
        return _ok('Hot reload successful.');
      } else {
        final notices = report.json?['notices'] as List<dynamic>? ?? [];
        final errors = notices
            .map((n) => n['message']?.toString() ?? n.toString())
            .join('\n');
        return CallToolResult(
          content: [TextContent(text: 'Hot reload failed:\n$errors')],
          isError: true,
        );
      }
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleWidgetTree(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final maxDepth = (req.arguments?['max_depth'] as num?)?.toInt() ?? 6;
      const group = 'mcp_widget_tree';

      final result = await _service!.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTree',
        isolateId: _isolateId,
        args: {'objectGroup': group},
      );

      // Dispose object group to free VM memory
      await _service!.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: _isolateId,
        args: {'objectGroup': group},
      );

      final root = result.json?['result'] as Map<String, dynamic>?;
      if (root == null) return _ok('No widget tree data returned.');

      final sb = StringBuffer();
      sb.writeln('Widget Tree (max depth $maxDepth):');
      sb.writeln('━' * 60);
      _writeNode(sb, root, 0, maxDepth);
      return _ok(sb.toString());
    } catch (e) {
      return _err(
          'Widget tree unavailable. App must run in debug mode. Error: $e');
    }
  }

  void _writeNode(
    StringBuffer sb,
    Map<String, dynamic> node,
    int depth,
    int maxDepth,
  ) {
    if (depth > maxDepth) return;
    final indent = '  ' * depth;
    final desc = node['description'] as String? ?? node['type'] as String? ?? '?';
    final hasChildren = node['hasChildren'] as bool? ?? false;
    final children = node['children'] as List<dynamic>? ?? [];
    final childCount = children.length;

    final suffix = hasChildren && childCount == 0
        ? ' [children not fetched]'
        : childCount > 0
            ? ' (${childCount}x)'
            : '';
    sb.writeln('$indent$desc$suffix');

    for (final child in children) {
      if (child is Map<String, dynamic>) {
        _writeNode(sb, child, depth + 1, maxDepth);
      }
    }
  }

  Future<CallToolResult> _handleVisualDebug(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    final args = req.arguments ?? {};
    final results = <String>[];

    try {
      if (args.containsKey('debug_paint')) {
        final on = args['debug_paint'] as bool;
        await _service!.callServiceExtension(
          'ext.flutter.debugPaint',
          isolateId: _isolateId,
          args: {'enabled': on},
        );
        results.add('debug_paint: ${on ? 'ON — widget bounds visible' : 'OFF'}');
      }

      if (args.containsKey('repaint_rainbow')) {
        final on = args['repaint_rainbow'] as bool;
        await _service!.callServiceExtension(
          'ext.flutter.repaintRainbow',
          isolateId: _isolateId,
          args: {'enabled': on},
        );
        results.add(
            'repaint_rainbow: ${on ? 'ON — cycling colors = repainting (bad). Static color = no repaint (good).' : 'OFF'}');
      }

      if (results.isEmpty) {
        return _ok(
            'No flags set. Pass debug_paint: true/false and/or repaint_rainbow: true/false.');
      }
      return _ok(results.join('\n'));
    } catch (e) {
      return _err(e);
    }
  }

  // ── Memory handlers ───────────────────────────────────────────────────────

  Future<CallToolResult> _handleMemoryTimeline(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;

      await _service!.streamListen(EventStreams.kGC);
      final gcEvents = <Event>[];
      final sub = _service!.onGCEvent.listen(gcEvents.add);

      final before = await _service!.getMemoryUsage(_isolateId!);

      await Future.delayed(Duration(seconds: dur));

      final after = await _service!.getMemoryUsage(_isolateId!);
      await sub.cancel();

      final heapBefore = before.heapUsage! / 1e6;
      final heapAfter = after.heapUsage! / 1e6;
      final delta = heapAfter - heapBefore;
      final gcCount = gcEvents.length;

      final sb = StringBuffer();
      sb.writeln('Memory Timeline (${dur}s window)');
      sb.writeln('━' * 50);
      sb.writeln('Heap start : ${heapBefore.toStringAsFixed(1)} MB');
      sb.writeln('Heap end   : ${heapAfter.toStringAsFixed(1)} MB');
      sb.writeln(
          'Delta      : ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} MB');
      sb.writeln('GC events  : $gcCount');
      sb.writeln('');

      if (delta > 10) {
        sb.writeln(
            'WARNING: Heap grew ${delta.toStringAsFixed(1)} MB in ${dur}s with no user action expected.');
        sb.writeln('→ Run find_memory_leaks for confirmation.');
      } else if (delta > 0 && gcCount == 0) {
        sb.writeln('Heap grew slightly with no GC — normal for active use.');
      } else {
        sb.writeln('Memory looks stable.');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleForceGc(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final before = await _service!.getMemoryUsage(_isolateId!);
      await _service!.getAllocationProfile(_isolateId!, gc: true);
      // Brief pause for GC to complete
      await Future.delayed(const Duration(milliseconds: 500));
      final after = await _service!.getMemoryUsage(_isolateId!);

      final beforeMB = before.heapUsage! / 1e6;
      final afterMB = after.heapUsage! / 1e6;
      final freed = beforeMB - afterMB;

      final sb = StringBuffer();
      sb.writeln('GC complete.');
      sb.writeln('Before: ${beforeMB.toStringAsFixed(1)} MB');
      sb.writeln('After : ${afterMB.toStringAsFixed(1)} MB');
      sb.writeln(
          'Freed : ${freed >= 0 ? freed.toStringAsFixed(1) : '0'} MB');
      sb.writeln('');

      if (freed < 1 && afterMB > 50) {
        sb.writeln(
            'Heap stayed high after GC (${afterMB.toStringAsFixed(1)} MB retained).');
        sb.writeln('→ Objects are being held. Run find_memory_leaks to identify which classes.');
      } else {
        sb.writeln('GC freed ${freed.toStringAsFixed(1)} MB — normal.');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleMemoryDiff(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final pause = (req.arguments?['pause_seconds'] as num?)?.toInt() ?? 5;

      final snap1 =
          await _service!.getAllocationProfile(_isolateId!, gc: true);
      await Future.delayed(Duration(seconds: pause));
      final snap2 =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      final before = <String, int>{};
      for (final c in snap1.members ?? []) {
        final name = c.classRef?.name;
        if (name != null) before[name] = c.instancesCurrent ?? 0;
      }

      final growers = <MapEntry<String, int>>[];
      for (final c in snap2.members ?? []) {
        final name = c.classRef?.name;
        if (name == null) continue;
        final delta = (c.instancesCurrent ?? 0) - (before[name] ?? 0);
        if (delta > 0) growers.add(MapEntry(name, delta));
      }

      growers.sort((a, b) => b.value.compareTo(a.value));

      final sb = StringBuffer();
      sb.writeln('Memory Diff (${pause}s between snapshots)');
      sb.writeln('━' * 50);

      if (growers.isEmpty) {
        sb.writeln('No class grew in instance count. No obvious leak.');
        return _ok(sb.toString());
      }

      sb.writeln('Classes with MORE instances after ${pause}s:');
      for (final e in growers.take(20)) {
        final flag = e.value > 20
            ? '  ← SUSPICIOUS'
            : e.value > 5
                ? '  ← elevated'
                : '';
        sb.writeln(
            '  ${e.key.padRight(40)} +${e.value} instances$flag');
      }

      final suspicious = growers.where((e) => e.value > 20).toList();
      if (suspicious.isNotEmpty) {
        sb.writeln('');
        sb.writeln('Investigate:');
        for (final e in suspicious.take(5)) {
          sb.writeln('  • ${e.key}: +${e.value} — check if navigation/dispose cleans these up');
        }
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleFindLeaks(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final observe =
          (req.arguments?['observe_seconds'] as num?)?.toInt() ?? 5;

      // Phase 1: force GC then baseline
      await _service!.getAllocationProfile(_isolateId!, gc: true);
      await Future.delayed(const Duration(milliseconds: 500));
      final baseline =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      final baselineCounts = <String, int>{};
      for (final c in baseline.members ?? []) {
        final name = c.classRef?.name;
        if (name != null) baselineCounts[name] = c.instancesCurrent ?? 0;
      }

      // Phase 2: observe
      await Future.delayed(Duration(seconds: observe));

      // Phase 3: force GC again then measure
      await _service!.getAllocationProfile(_isolateId!, gc: true);
      await Future.delayed(const Duration(milliseconds: 500));
      final after =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      final leaks = <MapEntry<String, int>>[];
      for (final c in after.members ?? []) {
        final name = c.classRef?.name;
        if (name == null) continue;
        final delta = (c.instancesCurrent ?? 0) - (baselineCounts[name] ?? 0);
        // Still growing after two GC cycles = strong leak signal
        if (delta > 0) leaks.add(MapEntry(name, delta));
      }

      leaks.sort((a, b) => b.value.compareTo(a.value));

      final sb = StringBuffer();
      sb.writeln('Leak Detection (GC → baseline → ${observe}s → GC → measure)');
      sb.writeln('━' * 60);

      if (leaks.isEmpty) {
        sb.writeln('No leaks detected. Instance counts stable after two GC cycles.');
        return _ok(sb.toString());
      }

      sb.writeln('Classes growing despite GC (leak candidates):');
      for (final e in leaks.take(15)) {
        final severity = e.value > 50
            ? 'HIGH'
            : e.value > 10
                ? 'MED '
                : 'LOW ';
        sb.writeln('  [$severity] ${e.key.padRight(40)} +${e.value} retained');
      }

      sb.writeln('');
      sb.writeln('Common causes:');
      sb.writeln('  • Static references holding widget/state objects');
      sb.writeln('  • Stream subscriptions not cancelled in dispose()');
      sb.writeln('  • AnimationController not disposed');
      sb.writeln('  • Navigator stack retaining old routes');
      sb.writeln('  • GlobalKey holding stale widget references');

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleClassInstances(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final className = req.arguments!['class_name'] as String;
      final profile =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      final matches = (profile.members ?? [])
          .where((c) =>
              c.classRef?.name
                  ?.toLowerCase()
                  .contains(className.toLowerCase()) ??
              false)
          .toList()
        ..sort((a, b) =>
            (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));

      if (matches.isEmpty) {
        return _ok('No class matching "$className" found in heap.');
      }

      final sb = StringBuffer();
      sb.writeln('Class instances matching "$className":');
      sb.writeln('━' * 50);
      for (final c in matches.take(10)) {
        final name = c.classRef?.name ?? '?';
        final inst = c.instancesCurrent ?? 0;
        final bytes = (c.bytesCurrent ?? 0) / 1024;
        sb.writeln(
            '  ${name.padRight(45)} $inst instances — ${bytes.toStringAsFixed(1)} KB');

        if (inst > 100) {
          sb.writeln(
              '    ↑ HIGH count. Check if these are being disposed correctly.');
        }
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleGcPressure(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;

      await _service!.streamListen(EventStreams.kGC);
      final gcEvents = <Event>[];
      final sub = _service!.onGCEvent.listen(gcEvents.add);

      await Future.delayed(Duration(seconds: dur));
      await sub.cancel();

      final sb = StringBuffer();
      sb.writeln('GC Pressure (${dur}s window)');
      sb.writeln('━' * 50);

      if (gcEvents.isEmpty) {
        sb.writeln('0 GC events — no pressure.');
        return _ok(sb.toString());
      }

      sb.writeln('GC events: ${gcEvents.length} in ${dur}s');
      sb.writeln(
          'Rate      : ${(gcEvents.length / dur).toStringAsFixed(1)} GC/sec');

      // Extract pause times from event data
      final pauses = <int>[];
      for (final e in gcEvents) {
        final ms = e.json?['durationMs'] as int?;
        if (ms != null) pauses.add(ms);
      }

      if (pauses.isNotEmpty) {
        final avg = pauses.reduce((a, b) => a + b) / pauses.length;
        final max = pauses.reduce((a, b) => a > b ? a : b);
        sb.writeln('Avg pause : ${avg.toStringAsFixed(1)} ms');
        sb.writeln('Max pause : $max ms');
      }

      sb.writeln('');
      final rate = gcEvents.length / dur;
      if (rate > 2) {
        sb.writeln('CRITICAL: >2 GC/sec. App allocating heavily in hot path.');
        sb.writeln('→ Find allocation hotspots with get_cpu_hotspots.');
        sb.writeln('→ Avoid creating objects inside build() or animation callbacks.');
      } else if (rate > 0.5) {
        sb.writeln('ELEVATED: frequent GC. Check for object creation in hot paths.');
      } else {
        sb.writeln('GC pressure NORMAL.');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleMemoryBreakdown(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final mem = await _service!.getMemoryUsage(_isolateId!);
      final vm = await _service!.getVM();

      final dartHeapMB = mem.heapUsage! / 1e6;
      final dartHeapCapMB = mem.heapCapacity! / 1e6;
      final externalMB = mem.externalUsage! / 1e6;
      final heapPct =
          (dartHeapMB / dartHeapCapMB * 100).toStringAsFixed(0);

      final sb = StringBuffer();
      sb.writeln('Memory Breakdown');
      sb.writeln('━' * 55);
      sb.writeln('');
      sb.writeln('Dart Heap    : ${dartHeapMB.toStringAsFixed(1)} MB used / ${dartHeapCapMB.toStringAsFixed(1)} MB capacity ($heapPct%)');
      sb.writeln('             → Your Dart objects (widgets, models, BLoCs, lists)');
      if (double.parse(heapPct) > 85) {
        sb.writeln('             ⚠ NEAR CAPACITY — GC will fire frequently');
      }
      sb.writeln('');
      sb.writeln('External     : ${externalMB.toStringAsFixed(1)} MB');
      sb.writeln('             → Native memory outside Dart GC (images, platform channels, FFI)');
      if (externalMB > 100) {
        sb.writeln('             ⚠ HIGH — check for uncached/large images or native buffers');
      }
      sb.writeln('');

      // RSS is not in getMemoryUsage — explain what DevTools shows
      sb.writeln('RSS (shown in DevTools)');
      sb.writeln('             → Total process memory including OS overhead,');
      sb.writeln('               Flutter engine, Skia/Impeller, JIT code cache.');
      sb.writeln('               RSS >> Dart Heap is normal (often 2-3x).');
      sb.writeln('');

      final totalKnown = dartHeapMB + externalMB;
      sb.writeln('Raster layers: track with DevTools Memory chart (not queryable via vm_service)');
      sb.writeln('');
      sb.writeln('Total accountable: ${totalKnown.toStringAsFixed(1)} MB (Dart + external)');

      // Isolate count
      final isolateCount = vm.isolates?.length ?? 1;
      if (isolateCount > 1) {
        sb.writeln('');
        sb.writeln('Note: $isolateCount isolates running. '
            'This only shows the main isolate heap. '
            'Background isolates have separate heaps.');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleHttpLogging(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final enabled = req.arguments!['enabled'] as bool;
      await _service!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: _isolateId,
        args: {'enabled': enabled},
      );
      return _ok(enabled
          ? 'HTTP logging enabled. Network requests will be captured in timeline.'
          : 'HTTP logging disabled. Reduces memory overhead — recommended during memory profiling.');
    } catch (e) {
      return _err(e);
    }
  }

  // ── Logging handlers ──────────────────────────────────────────────────────

  Future<CallToolResult> _handleWatchLogs(CallToolRequest req) async {
    if (_service == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
      final filter = req.arguments?['filter'] as String?;

      await _service!.streamListen(EventStreams.kStdout);
      await _service!.streamListen(EventStreams.kStderr);

      final lines = <String>[];
      final subs = <StreamSubscription>[];

      void onEvent(Event e) {
        final raw = e.bytes;
        if (raw == null) return;
        final decoded = utf8.decode(base64.decode(raw), allowMalformed: true).trim();
        if (decoded.isEmpty) return;
        if (filter != null && !decoded.contains(filter)) return;
        lines.add(decoded);
      }

      subs.add(_service!.onStdoutEvent.listen(onEvent));
      subs.add(_service!.onStderrEvent.listen(onEvent));

      await Future.delayed(Duration(seconds: dur));
      for (final s in subs) await s.cancel();

      if (lines.isEmpty) {
        return _ok(
            'No log output captured in ${dur}s${filter != null ? ' (filter: "$filter")' : ''}.');
      }
      return _ok(
          'Logs (${dur}s${filter != null ? ', filter: "$filter"' : ''}):\n${'━' * 50}\n${lines.join('\n')}');
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleErrorLogs(CallToolRequest req) async {
    if (_service == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;

      await _service!.streamListen(EventStreams.kStdout);
      await _service!.streamListen(EventStreams.kStderr);

      final errorLines = <String>[];
      final errorPatterns = RegExp(
          r'Error|Exception|FATAL|assert|Unhandled|FlutterError|══╡|crash',
          caseSensitive: false);

      final subs = <StreamSubscription>[];
      void onEvent(Event e) {
        final raw = e.bytes;
        if (raw == null) return;
        final decoded = utf8.decode(base64.decode(raw), allowMalformed: true).trim();
        if (decoded.isEmpty) return;
        if (errorPatterns.hasMatch(decoded)) errorLines.add(decoded);
      }

      subs.add(_service!.onStdoutEvent.listen(onEvent));
      subs.add(_service!.onStderrEvent.listen(onEvent));

      await Future.delayed(Duration(seconds: dur));
      for (final s in subs) await s.cancel();

      if (errorLines.isEmpty) {
        return _ok('No errors/exceptions in ${dur}s output.');
      }
      return _ok(
          'Errors found (${dur}s window):\n${'━' * 50}\n${errorLines.join('\n')}');
    } catch (e) {
      return _err(e);
    }
  }

  // ── Network handlers ──────────────────────────────────────────────────────

  Future<CallToolResult> _handleHttpRequestBody(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final id = req.arguments!['request_id'] as String;
      final result = await _service!.getHttpProfileRequest(_isolateId!, id);

      final sb = StringBuffer();
      sb.writeln('Request: ${result.method} ${result.uri}');
      sb.writeln('Status : ${result.response?.statusCode ?? 'pending'}');
      sb.writeln(
          'Time   : ${result.endTime != null ? result.endTime!.difference(result.startTime).inMilliseconds : '?'}ms');
      sb.writeln('');

      final reqData = result.request;
      if (reqData != null) {
        final headers = reqData.headers;
        if (headers != null && headers.isNotEmpty) {
          sb.writeln('Request headers:');
          headers.forEach((k, v) => sb.writeln('  $k: $v'));
          sb.writeln('');
        }
      }

      final respData = result.response;
      if (respData != null) {
        final headers = respData.headers;
        if (headers != null && headers.isNotEmpty) {
          sb.writeln('Response headers:');
          headers.forEach((k, v) => sb.writeln('  $k: $v'));
          sb.writeln('');
        }
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleWatchNetwork(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
      final threshold =
          (req.arguments?['slow_threshold_ms'] as num?)?.toInt() ?? 500;

      // Snapshot before
      final before = await _service!.getHttpProfile(_isolateId!);
      final beforeIds = before.requests.map((r) => r.id).toSet();

      await Future.delayed(Duration(seconds: dur));

      // Snapshot after
      final after = await _service!.getHttpProfile(_isolateId!);
      final newRequests =
          after.requests.where((r) => !beforeIds.contains(r.id)).toList();

      if (newRequests.isEmpty) {
        return _ok('No new HTTP requests in ${dur}s window.');
      }

      final sb = StringBuffer();
      sb.writeln('New HTTP requests (${dur}s window):');
      sb.writeln('━' * 60);

      for (final r in newRequests) {
        final ms = r.endTime != null
            ? r.endTime!.difference(r.startTime).inMilliseconds
            : -1;
        final msStr = ms >= 0 ? '${ms}ms' : 'pending';
        final flag = ms > threshold
            ? '  ← SLOW (>${threshold}ms)'
            : ms < 0
                ? '  ← PENDING'
                : '';
        final status = r.response?.statusCode?.toString() ?? '?';
        sb.writeln(
            '  [${r.id}] ${r.method.padRight(6)} $status  $msStr$flag');
        sb.writeln('         ${r.uri}');
      }

      final slow = newRequests.where((r) {
        if (r.endTime == null) return false;
        return r.endTime!.difference(r.startTime).inMilliseconds > threshold;
      }).length;

      if (slow > 0) {
        sb.writeln('');
        sb.writeln(
            '$slow slow request(s) over ${threshold}ms. Use get_http_request_body with the [ID] to inspect headers.');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  // ── Navigation / State handlers ───────────────────────────────────────────

  Future<CallToolResult> _handleNavigationStack(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final result = await _service!.callServiceExtension(
        'ext.flutter.navigator.getNavigatorTree',
        isolateId: _isolateId,
        args: {},
      );

      final data = result.json;
      if (data == null) return _ok('No navigator data.');

      final sb = StringBuffer();
      sb.writeln('Navigation Stack:');
      sb.writeln('━' * 50);

      void writeRoutes(dynamic node, int depth) {
        if (node == null) return;
        final indent = '  ' * depth;
        if (node is Map) {
          final name = node['name']?.toString() ??
              node['routeName']?.toString() ??
              node['description']?.toString() ??
              '(unnamed)';
          sb.writeln('$indent$name');
          final children = node['children'];
          if (children is List) {
            for (final c in children) writeRoutes(c, depth + 1);
          }
        } else if (node is List) {
          for (final c in node) writeRoutes(c, depth);
        }
      }

      writeRoutes(data['result'] ?? data, 0);

      final depth = _countDepth(data['result'] ?? data, 0);
      if (depth > 10) {
        sb.writeln('');
        sb.writeln(
            'WARNING: Navigation stack depth $depth — possible route leak. '
            'Ensure you pop routes and call dispose() on controllers.');
      }

      return _ok(sb.toString());
    } catch (e) {
      // Fallback: ext not available on all Flutter versions
      return _ok(
          'Navigation stack unavailable via service extension.\n'
          'Tip: Add RouteObserver to your MaterialApp to track routes.');
    }
  }

  int _countDepth(dynamic node, int current) {
    if (node == null) return current;
    if (node is Map) {
      final children = node['children'];
      if (children is List && children.isNotEmpty) {
        return children
            .map((c) => _countDepth(c, current + 1))
            .reduce((a, b) => a > b ? a : b);
      }
    }
    return current;
  }

  Future<CallToolResult> _handleListIsolates(CallToolRequest req) async {
    if (_service == null) return _notConnected();
    try {
      final vm = await _service!.getVM();
      final isolates = vm.isolates ?? [];

      final sb = StringBuffer();
      sb.writeln('Running isolates (${isolates.length}):');
      sb.writeln('━' * 55);

      for (final ref in isolates) {
        final detail = await _service!.getIsolate(ref.id!);
        final mem = await _service!.getMemoryUsage(ref.id!);
        final heapMB = (mem.heapUsage! / 1e6).toStringAsFixed(1);
        final extMB = (mem.externalUsage! / 1e6).toStringAsFixed(1);
        final name = ref.name ?? 'unnamed';
        final state = detail.runnable == true ? 'running' : 'paused';
        sb.writeln('  ${name.padRight(30)} [$state]  heap: $heapMB MB  ext: $extMB MB');

        if (name != 'main' && !name.contains('main')) {
          sb.writeln(
              '    ↑ Background isolate — created via compute() or Isolate.spawn');
        }
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  // ── Eval handler ──────────────────────────────────────────────────────────

  Future<CallToolResult> _handleEvalExpression(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final expression = req.arguments!['expression'] as String;
      final frameIndex =
          (req.arguments?['frame_index'] as num?)?.toInt() ?? 0;

      // Get top stack frame from paused isolate, or use library scope
      final isolate = await _service!.getIsolate(_isolateId!);

      InstanceRef? result;

      if (isolate.pauseEvent != null) {
        // Isolate is paused — eval in frame context
        final frames = (await _service!.getStack(_isolateId!)).frames ?? [];
        if (frameIndex >= frames.length) {
          return _ok(
              'Frame $frameIndex not available. Only ${frames.length} frames on stack.');
        }
        result = await _service!.evaluateInFrame(
          _isolateId!,
          frameIndex,
          expression,
        ) as InstanceRef?;
      } else {
        // Isolate running — eval in root library scope
        final rootLib = isolate.rootLib;
        if (rootLib == null) {
          return _ok(
              'Cannot evaluate: isolate has no root library. '
              'Pause the app (add a breakpoint) to eval in frame context.');
        }
        result = await _service!.evaluate(
          _isolateId!,
          rootLib.id!,
          expression,
        ) as InstanceRef?;
      }

      if (result == null) return _ok('null');

      final sb = StringBuffer();
      sb.writeln('Expression: $expression');
      sb.writeln('Result    : ${result.valueAsString ?? result.classRef?.name ?? result.kind}');
      if (result.valueAsStringIsTruncated == true) {
        sb.writeln('(truncated — value is larger than shown)');
      }
      sb.writeln('Type      : ${result.classRef?.name ?? result.kind}');

      return _ok(sb.toString());
    } catch (e) {
      return _err(
          'Eval failed: $e\n'
          'Note: For frame-context eval, pause the app first (add a breakpoint).');
    }
  }

  // ── App info handler ──────────────────────────────────────────────────────

  Future<CallToolResult> _handleAppInfo(CallToolRequest req) async {
    if (_service == null || _isolateId == null) return _notConnected();
    try {
      final vm = await _service!.getVM();
      final ver = await _service!.getVersion();
      final isolate = await _service!.getIsolate(_isolateId!);

      // Flutter version via service extension
      String buildMode = 'unknown';
      String targetPlatform = 'unknown';

      try {
        final fv = await _service!.callServiceExtension(
          'ext.flutter.platformOverride',
          isolateId: _isolateId,
          args: {},
        );
        targetPlatform = fv.json?['value']?.toString() ?? 'unknown';
      } catch (_) {}

      try {
        await _service!.callServiceExtension(
          'ext.flutter.debugAllowBanner',
          isolateId: _isolateId,
          args: {},
        );
        buildMode = 'debug';
      } catch (_) {
        buildMode = 'profile (debug extensions unavailable)';
      }

      final extensions = isolate.extensionRPCs ?? [];
      final flutterExts =
          extensions.where((e) => e.startsWith('ext.flutter')).length;
      final dartExts =
          extensions.where((e) => e.startsWith('ext.dart')).length;

      final sb = StringBuffer();
      sb.writeln('App Info');
      sb.writeln('━' * 50);
      sb.writeln('VM version     : ${vm.version}');
      sb.writeln(
          'Service protocol: ${ver.major}.${ver.minor}');
      sb.writeln('Build mode     : $buildMode');
      sb.writeln('Target platform: $targetPlatform');
      sb.writeln('Isolates       : ${vm.isolates?.length ?? 1}');
      sb.writeln(
          'Extensions     : $flutterExts Flutter + $dartExts Dart registered');
      sb.writeln('');
      sb.writeln('Root library   : ${isolate.rootLib?.uri ?? 'unknown'}');
      sb.writeln('');

      if (extensions.isNotEmpty) {
        sb.writeln('Available service extensions:');
        for (final e in extensions.take(30)) {
          sb.writeln('  $e');
        }
        if (extensions.length > 30) {
          sb.writeln('  ... and ${extensions.length - 30} more');
        }
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleDebugFrameEvents(CallToolRequest req) async {
    if (_service == null) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;

      await _service!.setVMTimelineFlags(['Embedder', 'Dart', 'GC', 'API']);
      await _service!.clearVMTimeline();
      await Future.delayed(Duration(seconds: dur));
      final timeline = await _service!.getVMTimeline();

      final total = timeline.traceEvents?.length ?? 0;
      if (total == 0) {
        return _ok('No timeline events captured in ${dur}s. App may be idle.');
      }

      final names = _jank.debugEventNames(timeline);
      final counts = _jank.debugFrameCounts(timeline);
      final sb = StringBuffer();
      sb.writeln('Timeline: $total events in ${dur}s');
      sb.writeln(
          'Frame markers: UI=[Dart]Frame × ${counts['ui_async_frames']}, '
          'Raster=[Embedder]GPURasterizer::Draw × ${counts['raster_frames']}');
      sb.writeln('━' * 55);
      sb.writeln('Unique event names (${names.length}):');
      for (final n in names.take(60)) {
        sb.writeln('  $n');
      }
      if (names.length > 60) sb.writeln('  ... and ${names.length - 60} more');

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }
}
