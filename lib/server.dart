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
            version: '1.1.0',
          ),
          instructions:
              'This server connects to a running Flutter app via the Dart VM service and exposes performance, memory, and debugging tools. '
              'ALWAYS call connect_to_app first before any other tool — it requires the ws:// URI printed by flutter run. '
              'ALWAYS call take_screenshot before performance tools so you can see the current screen and tell the user exactly what to interact with. '
              'When the user says their app is slow, laggy, stutters, or drops frames — call analyze_jank_causes. '
              'When the user says memory is high, the app crashes with OOM, or RAM keeps growing — call find_memory_leaks. '
              'When unsure where to start or user has no specific complaint — call run_health_check. It combines screenshot, FPS, and memory in one call. '
              'Performance tools (capture_frame_timing, get_cpu_hotspots, get_widget_rebuild_counts, analyze_jank_causes) require the user to interact with the app during the capture window. '
              'Always tell the user what to do BEFORE calling these tools: "Please scroll the list / tap the button / open the chart now." '
              'On Android, pass auto_scroll: true to drive scrolling without a human.',
        );

  VmService? _service;
  String? _isolateId;
  String? _wsUri; // last good URI — reused for auto-reconnect
  String? _reconnectError;
  bool _isDebug = true;
  String _os = '';
  String? _appPackage; // e.g. package:my_app/ — separates your code from dependencies
  // Services registered on the VM by the Flutter tool, e.g. reloadSources → s0.reloadSources
  final _registeredServices = <String, String>{};
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
            'Use this when your app scrolls or animates with stutter. '
            'Tells you how smooth your frames are and which ones were too slow. '
            'WORKFLOW: 1) Call take_screenshot first to see the current screen. '
            '2) Tell the user exactly what to do ("scroll this list", "tap the chart button"). '
            '3) Call this tool while user interacts. '
            'Returns FPS, jank %, build/raster times per frame.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Recording window in seconds (default: 3)'),
            'target_fps':
                NumberSchema(description: 'Target frame rate: 60 or 120 (default: 60)'),
            'auto_scroll': _autoScrollSchema,
          },
        ),
      ),
      _handleFrameTiming,
    );

    registerTool(
      Tool(
        name: 'get_cpu_hotspots',
        description:
            'Use this if a specific gesture or screen feels slow to respond. '
            'Shows which of your Dart functions is eating the most CPU. '
            'WORKFLOW: 1) Call take_screenshot to see the current screen. '
            '2) Ask user to use the feature they say is slow ("open the chart", "trigger the search"). '
            '3) Call this tool during that interaction. '
            'Returns ranked Dart functions with CPU% — filters out native/VM code automatically.',
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
            'Use this if your list or animation stutters even though nothing seems wrong. '
            'Excessive widget rebuilds are the #1 hidden cause of jank — this finds them. '
            'WORKFLOW: 1) Call take_screenshot to see the current screen. '
            '2) Tell user to interact with the slow screen ("scroll the list", "switch tabs"). '
            '3) Call this tool during that interaction. '
            'Returns widget names with file:line, rebuild counts, shared-parent analysis. '
            'Requires debug mode.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Observation window in seconds (default: 5)'),
            'auto_scroll': _autoScrollSchema,
          },
        ),
      ),
      _handleRebuildCounts,
    );

    registerTool(
      Tool(
        name: 'get_memory_usage',
        description:
            'Current memory: Dart heap, external/native memory, and the classes using the most — '
            'split into your code, dependencies, and framework/VM. No interaction needed.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleMemory,
    );

    registerTool(
      Tool(
        name: 'analyze_jank_causes',
        description:
            'START HERE when the app is slow, laggy, stutters, or drops frames. '
            'Full jank diagnosis: frame timing + CPU profile captured over the SAME window. '
            'WORKFLOW: 1) Call take_screenshot to see the current screen. '
            '2) Ask user: "Which part of the app feels slow? Please [scroll/tap/use] that feature now." '
            '3) Call this tool during the interaction. '
            'Returns: verdict (HEALTHY/MINOR/SEVERE/INSUFFICIENT DATA, marked PARTIAL if a step failed), '
            'FPS, jank%, top CPU functions, fix suggestions.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'Recording window in seconds (default: 5)'),
            'target_fps':
                NumberSchema(description: 'Target frame rate: 60 or 120 (default: 60)'),
            'auto_scroll': _autoScrollSchema,
          },
        ),
      ),
      _handleJankDiagnosis,
    );

    registerTool(
      Tool(
        name: 'get_http_profile',
        description:
            'List HTTP requests made by the app: [id], method, status, time, URL. '
            'Pass watch_seconds to record only NEW requests during that window. '
            'Logging is auto-enabled on connect, so only requests after connect are captured. '
            'Captures anything built on dart:io HttpClient: package:http (default client), Dio, IOClient. '
            'Misses native clients (cupertino_http, cronet_http) and web.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': NumberSchema(
                description: 'Max number of requests to return (default: 20)'),
            'watch_seconds': NumberSchema(
                description: 'Record only new requests for this many seconds (default: off)'),
            'slow_threshold_ms': NumberSchema(
                description: 'Flag requests slower than this (default: 1000)'),
          },
        ),
      ),
      _handleHttpProfile,
    );


    registerTool(
      Tool(
        name: 'hot_reload',
        description:
            'Trigger a hot reload on the running Flutter app. '
            'Use after editing source files to apply changes without restarting. '
            'Only works for apps started with flutter run in debug mode — the reload goes through flutter run.',
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
            'Toggle on-device overlays. debug_paint draws widget bounds/padding. '
            'repaint_rainbow colors layers that repaint (find overdraw). '
            'performance_overlay shows raster (top) and UI (bottom) frame bars; red = over budget. '
            'Pass only the flags you want to change.',
        inputSchema: ObjectSchema(
          properties: {
            'debug_paint': BooleanSchema(
                description: 'Show widget bounds and padding lines'),
            'repaint_rainbow': BooleanSchema(
                description:
                    'Color repainting layers — cycling hue = repainting'),
            'performance_overlay':
                BooleanSchema(description: 'Show frame timing bars on screen'),
          },
        ),
      ),
      _handleVisualDebug,
    );

    registerTool(
      Tool(
        name: 'get_memory_timeline',
        description:
            'Record heap usage and GC activity over N seconds: heap delta, GC rate, pause times, '
            'and whether GC pressure is normal, elevated, or critical.',
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
        name: 'find_memory_leaks',
        description:
            'START HERE when memory keeps growing or the app crashes with out-of-memory. '
            'Force GC → baseline snapshot → wait → force GC → second snapshot → '
            'report classes still growing despite GC. Use the app normally during the window.',
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
            'Instance count and size for classes whose name contains the given text. '
            'Run it before and after repeating a navigation — a count that keeps climbing is retained.',
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




    // ── Logging ──────────────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'watch_logs',
        description:
            'Capture app output for N seconds: print/debugPrint, dart:developer log(), and '
            'Flutter framework errors (full error text with the widget and file:line that caused it). '
            'Pass errors_only: true to find crashes and exceptions.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds':
                NumberSchema(description: 'How long to capture (default: 5)'),
            'filter': StringSchema(
                description: 'Optional substring filter — only return entries containing this string'),
            'errors_only': BooleanSchema(
                description: 'Only errors: Flutter errors, SEVERE logs, and lines matching Error/Exception/FATAL'),
          },
        ),
      ),
      _handleWatchLogs,
    );


    // ── Network ───────────────────────────────────────────────────────────────

    registerTool(
      Tool(
        name: 'get_http_request_body',
        description:
            'Fetch headers and request/response bodies for a specific HTTP request by its ID. '
            'Auth headers, cookies and password/token/secret fields are redacted. '
            'Get the [id] from get_http_profile.',
        inputSchema: ObjectSchema(
          properties: {
            'request_id': StringSchema(description: 'Request ID from get_http_profile'),
          },
          required: ['request_id'],
        ),
      ),
      _handleHttpRequestBody,
    );


    // ── Navigation / State ────────────────────────────────────────────────────


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
        name: 'take_screenshot',
        description:
            'Capture a screenshot of the current Flutter app screen. '
            'Returns a PNG image. Use this to visually inspect the UI, '
            'identify what screen the user is on, or show before/after comparisons.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleScreenshot,
    );
    // ── Beginner-friendly aliases ─────────────────────────────────────────
    registerTool(
      Tool(
        name: 'run_health_check',
        description:
            'Start here if you have no idea what is wrong. '
            'Takes a screenshot, checks frame rate, and checks memory — all in one call. '
            'Returns a plain-English health report and tells you exactly what to do next. '
            'Interact with your app while this runs.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleHealthCheck,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static final _autoScrollSchema = BooleanSchema(
      description: 'Android only: swipe up/down via adb during the capture so runs '
          'are repeatable without a human. Uses ANDROID_SERIAL if several devices are attached.');

  Future<CallToolResult> _notConnected() async {
    if (_wsUri == null) {
      return _err('Not connected. Call connect_to_app first with the URI printed by flutter run.');
    }
    final sb = StringBuffer('Disconnected from the app (was $_wsUri).\n'
        'Auto-reconnect failed: $_reconnectError\n'
        'Fix: check flutter run is still running. If it restarted, the URI changed — '
        'call connect_to_app with the new one.');
    if (_os == 'android') sb.write('\n${await _adbForwardNote()}');
    return CallToolResult(content: [TextContent(text: sb.toString())], isError: true);
  }

  Future<String> _adbForwardNote() async {
    try {
      final out = '${(await Process.run('adb', ['forward', '--list'])).stdout}'.trim();
      return out.isEmpty
          ? 'Android: no adb port forwards exist (adb forward --list is empty) — '
              'device disconnected or flutter run stopped.'
          : 'Android: adb forwards still present:\n$out';
    } catch (_) {
      return 'Android: could not run adb to check port forwarding.';
    }
  }

  /// Connects and picks the Flutter UI isolate. Throws on failure.
  Future<void> _connect(String wsUri) async {
    final service = await vmServiceConnectUri(wsUri);
    final vm = await service.getVM();
    // Prefer the isolate with Flutter extensions (UI isolate) over whatever is listed first.
    Isolate? picked;
    for (final ref in vm.isolates ?? <IsolateRef>[]) {
      final iso = await service.getIsolate(ref.id!);
      if ((iso.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter'))) {
        picked = iso;
        break;
      }
      picked ??= iso;
    }
    if (picked == null) throw 'No isolates running in the VM at $wsUri';

    _registeredServices.clear();
    service.onServiceEvent.listen((e) {
      if (e.kind == EventKind.kServiceRegistered) {
        _registeredServices[e.service!] = e.method!;
      } else if (e.kind == EventKind.kServiceUnregistered) {
        _registeredServices.remove(e.service);
      }
    });
    // Hot restart kills the isolate — drop it so the next call re-picks.
    service.onIsolateEvent.listen((e) {
      if (e.kind == EventKind.kIsolateExit && e.isolate?.id == _isolateId) _isolateId = null;
    });
    await service.streamListen(EventStreams.kService).catchError((_) => Success());
    await service.streamListen(EventStreams.kIsolate).catchError((_) => Success());
    service.onDone.then((_) {
      if (identical(_service, service)) _service = null;
    });

    _service = service;
    _isolateId = picked.id;
    _wsUri = wsUri;
    _os = vm.operatingSystem ?? '';
    _isDebug = (picked.extensionRPCs ?? []).any((e) => e.contains('inspector'));
    final root = picked.rootLib?.uri ?? '';
    _appPackage = root.startsWith('package:') ? '${root.substring(0, root.indexOf('/') + 1)}' : null;

    // Auto-enable HTTP timeline logging so get_http_profile captures requests immediately
    await service.callServiceExtension(
      'ext.dart.io.httpEnableTimelineLogging',
      isolateId: _isolateId,
      args: {'enabled': true},
    ).catchError((_) => Response());
  }

  /// True when connected; transparently reconnects to the last URI if the socket dropped.
  Future<bool> _ensureConnected() async {
    if (_service != null && _isolateId != null) return true;
    if (_wsUri == null) return false;
    try {
      await _service?.dispose();
      _service = null;
      await _connect(_wsUri!);
      _reconnectError = null;
      stderr.writeln('[mcp] reconnected to $_wsUri');
      return true;
    } catch (e) {
      _service = null;
      _reconnectError = '$e';
      return false;
    }
  }

  String _debugCaveat() => _isDebug
      ? '\n⚠ DEBUG MODE: timings are inflated (JIT, asserts) — treat jank as a hint, not a measurement. '
          '${_os == 'android' ? 'On an Android emulator, raster times of 30–50ms usually mean a software GPU (SwiftShader), not real jank. ' : ''}'
          'Confirm with flutter run --profile on a physical device.\n'
      : '';

  /// Android only: alternate up/down swipes via adb for [dur] seconds.
  Future<String> _maybeAutoScroll(CallToolRequest req, int dur) async {
    if (req.arguments?['auto_scroll'] != true) return '';
    if (_os != 'android') {
      return '\nℹ auto_scroll skipped: Android only (adb shell input swipe). Interact manually on $_os.';
    }
    try {
      final size = await Process.run('adb', ['shell', 'wm', 'size']);
      // "Override size" (if any) is listed after "Physical size" and wins
      final m = RegExp(r'(\d+)x(\d+)').allMatches('${size.stdout}').lastOrNull;
      if (m == null) return '\nℹ auto_scroll skipped: could not read screen size: ${size.stderr}';
      final w = int.parse(m[1]!), h = int.parse(m[2]!);
      final x = '${w ~/ 2}', low = '${h * 3 ~/ 4}', high = '${h ~/ 4}';
      final end = DateTime.now().add(Duration(seconds: dur));
      var n = 0;
      while (DateTime.now().isBefore(end)) {
        final up = (n++).isEven;
        await Process.run('adb',
            ['shell', 'input', 'swipe', x, up ? low : high, x, up ? high : low, '300']);
      }
      return '\nℹ auto_scroll: $n adb swipes during capture.';
    } catch (e) {
      return '\nℹ auto_scroll failed: $e';
    }
  }

  Future<CpuSamples> _sampleCpu(int dur) async {
    final service = _service!, isolateId = _isolateId!;
    // Ensure profiler running — required on Android
    await service.setFlag('profiler', 'true').catchError((_) => Success());
    final t0 = (await service.getVMTimelineMicros()).timestamp!;
    await Future.delayed(Duration(seconds: dur));
    final t1 = (await service.getVMTimelineMicros()).timestamp!;
    // Clamp: if VM clock returned same value (Android emulator edge case), use dur
    final extent = t1 > t0 ? t1 - t0 : dur * 1000000;
    return service.getCpuSamples(isolateId, t0, extent);
  }

  CallToolResult _ok(String text) =>
      CallToolResult(content: [TextContent(text: text)]);

  String _nextSteps(List<String> steps) {
    if (steps.isEmpty) return '';
    final sb = StringBuffer('\n\n→ What to do next:\n');
    for (final s in steps) sb.writeln('  • $s');
    return sb.toString();
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1000000) return '${(bytes / 1e6).toStringAsFixed(2)} MB';
    if (bytes >= 1000) return '${(bytes / 1000).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  String _classLibraryUri(ClassHeapStats c) {
    try {
      final lib = (c.classRef as dynamic)?.library;
      if (lib == null) return '';
      final uri = lib.uri as String? ?? lib.toString();
      return uri;
    } catch (_) {
      return '';
    }
  }

  CallToolResult _err(Object e) {
    final msg = '$e';
    String? hint;
    if (msg.contains('Service connection disposed') || msg.contains('Connection closed')) {
      hint = 'Disconnected from the app mid-call. The next tool call reconnects automatically; '
          'if that fails, call connect_to_app with the new URI from flutter run.';
    } else if (msg.contains('Connection refused') ||
        msg.contains('SocketException') ||
        msg.contains('WebSocketException')) {
      hint = 'Could not reach the app. Check flutter run is still running and the URI is current.';
    } else if (msg.contains('(-32601)') || msg.contains('AOT mode')) {
      // JSON-RPC method not found = extension not registered; AOT = no expression compiler
      hint = _isDebug
          ? 'This service extension is not registered in the app.'
          : 'Not available in profile/release mode — this tool needs debug mode '
              '(flutter run without --profile). Performance and memory tools work in profile mode.';
    }
    return CallToolResult(
      content: [TextContent(text: hint == null ? 'Error: $msg' : '$hint\nOriginal error: $msg')],
      isError: true,
    );
  }

  String _toWsUri(String uri) {
    var u = uri.trim();
    // DevTools links carry the VM service URI in ?uri=… (often inside the #fragment)
    final embedded = RegExp(r'[?&]uri=([^&#]+)').firstMatch(u);
    if (embedded != null) u = Uri.decodeComponent(embedded[1]!);
    if (!u.startsWith('ws')) {
      u = u
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');
    }
    if (!u.endsWith('/ws')) {
      u = u.replaceFirst(RegExp(r'/?$'), '/ws');
    }
    return u;
  }

  // ── Handlers ──────────────────────────────────────────────────────────────

  Future<CallToolResult> _handleConnect(CallToolRequest req) async {
    final uri = req.arguments!['uri'] as String;
    final wsUri = _toWsUri(uri);
    try {
      stderr.writeln('[mcp] connecting to $wsUri');
      await _service?.dispose();
      _service = null;
      await _connect(wsUri);
    } catch (e) {
      return _err('Could not connect.\n'
          'Input URI : $uri\n'
          'Tried     : $wsUri${uri.trim() == wsUri ? '' : ' (converted to ws:// + /ws)'}\n'
          'Cause     : $e\n'
          'Note: the "port =" in a SocketException is your local client port, not the app\'s. '
          'The app port is the one in "Tried" above.\n'
          'Use the exact URI flutter run prints after "A Dart VM Service on ... is available at:" — '
          'it changes on every flutter run.');
    }
    try {
      final iso = await _service!.getIsolate(_isolateId!);

      String memNote = '';
      try {
        final mem = await _service!.getMemoryUsage(_isolateId!);
        // Heap capacity grows on demand, so "% of capacity" is not a limit — report MB only.
        memNote = '\nDart heap: ${(mem.heapUsage! / 1e6).toStringAsFixed(0)} MB used';
      } catch (_) {}

      final sb = StringBuffer();
      sb.writeln('Connected ✓  (${_isDebug ? 'debug' : 'profile'} mode | ${iso.name} | $_os)$memNote');
      sb.writeln('URI: $wsUri (auto-reconnects to this URI if the connection drops)');
      sb.writeln('');
      sb.writeln('Best starting point:');
      sb.writeln('  1. run_health_check       → screenshot + FPS + memory in one call');
      sb.writeln('  2. analyze_jank_causes    → full jank diagnosis (interact during capture)');
      sb.writeln('  3. find_memory_leaks      → GC-confirmed leak detection');
      if (_isDebug) {
        sb.writeln('');
        sb.writeln('ℹ Debug mode: timings are inflated. For real perf numbers use flutter run --profile on a device.');
      } else {
        sb.writeln('');
        sb.writeln('ℹ Profile mode: accurate perf numbers. Widget rebuilds, hot reload and screenshots need debug mode.');
      }
      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleFrameTiming(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;
      final fps = (req.arguments?['target_fps'] as num?)?.toInt() ?? 60;

      // Flutter.Frame extension events (pre-computed FrameTiming — same source as DevTools),
      // emitted in both debug and profile mode.
      final scroll = _maybeAutoScroll(req, dur);
      final frames = await _jank.collectFromFrameTimings(
          _service!, _isolateId!, Duration(seconds: dur));
      final scrollNote = await scroll;

      if (frames.isEmpty) {
        return _ok('No frames rendered in ${dur}s — the app was idle. '
            'Scroll or animate during the window, or pass auto_scroll: true on Android.$scrollNote');
      }
      final jankPct =
          frames.where((f) => f.isJanky(targetFps: fps)).length / frames.length * 100;
      final hints = <String>[];
      if (frames.length >= JankAnalyzer.minFrames && jankPct > 10) {
        hints.add('Run get_widget_rebuild_counts (duration_seconds: 8) — excessive rebuilds are the #1 cause');
        hints.add('Run get_cpu_hotspots (duration_seconds: 5) — find the slow Dart function');
      }
      return _ok('${_jank.verdict(frames, targetFps: fps)}\n'
          '${_jank.generateReport(frames, targetFps: fps)}'
          '${_debugCaveat()}$scrollNote${_nextSteps(hints)}');
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleCpuHotspots(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 2;
      final topN = (req.arguments?['top_n'] as num?)?.toInt() ?? 10;

      final samples = await _sampleCpu(dur);
      return _ok(_cpu.generateHotspotReport(samples, topN: topN, appPackage: _appPackage));
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleRebuildCounts(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
      final collector = RebuildCollector();

      // Pre-populate id→name cache from full location map (handles reconnects
      // where Flutter won't resend locations for already-registered ids)
      try {
        final locResult = await _service!.callServiceExtension(
          'ext.flutter.inspector.widgetLocationIdMap',
          isolateId: _isolateId,
        );
        collector.preloadLocationMap(locResult.json?['result']);
      } catch (_) {}

      // Start listening BEFORE enabling — first event also includes locations
      collector.start(_service!);
      await _service!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: _isolateId,
        args: {'enabled': true},
      );
      final scroll = _maybeAutoScroll(req, dur);
      await Future.delayed(Duration(seconds: dur));
      await _service!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: _isolateId,
        args: {'enabled': false},
      );

      return _ok(await collector.stopAndReport(Duration(seconds: dur)) + await scroll);
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleMemory(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final mem = await _service!.getMemoryUsage(_isolateId!);
      final profile = await _service!.getAllocationProfile(_isolateId!, gc: false);

      final heapMB = (mem.heapUsage! / 1e6).toStringAsFixed(1);
      final capMB = (mem.heapCapacity! / 1e6).toStringAsFixed(1);
      final extMB = mem.externalUsage! / 1e6;

      final sb = StringBuffer();
      sb.writeln('Dart heap : $heapMB MB used (capacity now $capMB MB — grows on demand, not a limit)');
      sb.writeln('            → your Dart objects: widgets, models, state, lists');
      sb.writeln('External  : ${extMB.toStringAsFixed(1)} MB${extMB > 100 ? '  ⚠ HIGH — check for large/uncached images or native buffers' : ''}');
      sb.writeln('            → native memory held by Dart objects: decoded images, byte buffers, FFI');
      sb.writeln('Not shown : engine, GPU/raster and OS memory — process RSS is normally 2-3x the Dart heap.');

      final byOrigin = <CodeOrigin, List<ClassHeapStats>>{};
      for (final c in (profile.members ?? <ClassHeapStats>[])
        ..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0))) {
        if ((c.bytesCurrent ?? 0) == 0) continue;
        byOrigin.putIfAbsent(codeOrigin(_classLibraryUri(c), _appPackage), () => []).add(c);
      }
      for (final (origin, title, n) in [
        (CodeOrigin.app, 'Your classes${_appPackage == null ? '' : ' ($_appPackage)'}', 10),
        (CodeOrigin.dependency, 'Dependency classes (pub packages)', 5),
        (CodeOrigin.sdk, 'Framework/VM classes', 8),
      ]) {
        final list = byOrigin[origin] ?? [];
        if (list.isEmpty) continue;
        sb.writeln('');
        sb.writeln('$title:');
        for (final c in list.take(n)) {
          sb.writeln('  ${(c.classRef?.name ?? '?').padRight(30)} '
              '${c.instancesCurrent ?? 0} instances — ${_fmtBytes(c.bytesCurrent!)}');
        }
      }

      final isolates = (await _service!.getVM()).isolates?.length ?? 1;
      if (isolates > 1) {
        sb.writeln('');
        sb.writeln('Note: $isolates isolates running — this is the main isolate only (see list_isolates).');
      }
      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleJankDiagnosis(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
    final fps = (req.arguments?['target_fps'] as num?)?.toInt() ?? 60;

    // Frames and CPU over the SAME window so samples line up with frames.
    String? frameErr, cpuErr;
    final (frames, samples, scrollNote) = await (
      _jank
          .collectFromFrameTimings(_service!, _isolateId!, Duration(seconds: dur))
          .then<List<FrameData>?>((f) => f, onError: (Object e) {
        frameErr = '$e';
        return null;
      }),
      _sampleCpu(dur).then<CpuSamples?>((s) => s, onError: (Object e) {
        cpuErr = '$e';
        return null;
      }),
      _maybeAutoScroll(req, dur),
    ).wait;

    final sb = StringBuffer('┌─ JANK DIAGNOSIS (${dur}s, frames + CPU captured together)\n');
    if (frameErr != null) sb.writeln('│ ⚠ INCOMPLETE — frame capture failed: $frameErr');
    if (cpuErr != null) sb.writeln('│ ⚠ PARTIAL — CPU profile failed: $cpuErr');
    if (frames != null) sb.writeln('│ ${_jank.verdict(frames, targetFps: fps)}');
    final top = samples == null ? null : _cpu.topHotspot(samples, appPackage: _appPackage);
    if (top != null && top.selfPct > 5) {
      sb.writeln('│   TOP CPU: ${top.name} (${top.selfPct.toStringAsFixed(1)}% self)');
    }
    sb.writeln('└${'─' * 60}');
    sb.write(_debugCaveat());
    sb.writeln(scrollNote);
    sb.writeln('━━ FRAME ANALYSIS ━━');
    sb.writeln(frames == null
        ? 'Failed: $frameErr'
        : _jank.generateReport(frames, targetFps: fps));
    sb.writeln('━━ CPU PROFILE ━━');
    sb.write(samples == null
        ? 'Failed: $cpuErr'
        : _cpu.generateHotspotReport(samples, topN: 5, appPackage: _appPackage));
    return _ok(sb.toString());
  }

  Future<CallToolResult> _handleHttpProfile(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 20;
      final watch = (req.arguments?['watch_seconds'] as num?)?.toInt();
      final threshold = (req.arguments?['slow_threshold_ms'] as num?)?.toInt() ?? 1000;

      var requests = (await _service!.getHttpProfile(_isolateId!)).requests;
      if (watch != null) {
        final seen = requests.map((r) => r.id).toSet();
        await Future.delayed(Duration(seconds: watch));
        requests = (await _service!.getHttpProfile(_isolateId!))
            .requests
            .where((r) => !seen.contains(r.id))
            .toList();
      }
      final window = watch == null ? '' : ' in ${watch}s window';
      if (requests.isEmpty) return _ok('No HTTP requests recorded$window.');

      final sb = StringBuffer('HTTP requests$window (newest last):\n');
      var slow = 0;
      for (final r in requests.reversed.take(limit).toList().reversed) {
        final ms = r.endTime?.difference(r.startTime).inMilliseconds;
        if (ms != null && ms > threshold) slow++;
        final flag = ms == null
            ? '  ← PENDING'
            : ms > threshold
                ? '  ← SLOW (>${threshold}ms)'
                : '';
        sb.writeln('  [${r.id}] ${r.method.padRight(6)} ${r.response?.statusCode ?? '?'}  '
            '${ms == null ? 'pending' : '${ms}ms'}$flag');
        sb.writeln('         ${r.uri}');
      }
      if (slow > 0) {
        sb.writeln('\n$slow slow request(s). Use get_http_request_body with the [id] to inspect.');
      }
      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleHotReload(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    // The raw VM can't compile ("Error while starting Kernel isolate task") — flutter run's
    // frontend server does, via the reloadSources service it registers on the VM service.
    final method = _registeredServices['reloadSources'];
    if (method == null) {
      return _err('Hot reload unavailable: the Flutter tool has not registered a "reloadSources" '
          'service on this VM. It only works when the app was started with flutter run in debug '
          'mode and you connected to the URI flutter run printed. Otherwise press r in the flutter run terminal.');
    }
    try {
      await _service!.callMethod(method,
          isolateId: _isolateId, args: {'force': false, 'pause': false});
      return _ok('Hot reload successful (via flutter run).');
    } catch (e) {
      return _err('Hot reload failed: $e');
    }
  }

  Future<CallToolResult> _handleWidgetTree(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
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
      sb.writeln('Widget Tree (max depth $maxDepth branching levels; → joins single-child wrappers):');
      sb.writeln('━' * 60);
      _writeNode(sb, root, 0, maxDepth);
      if (sb.length > 20000) sb.writeln('… truncated — pass a smaller max_depth');
      return _ok(sb.toString());
    } catch (e) {
      return _err(
          e);
    }
  }

  // Single-child wrapper chains (providers, Padding, Center…) go on one line and
  // don't use up depth — otherwise real apps never get past their providers.
  void _writeNode(
      StringBuffer sb, Map<String, dynamic> node, int depth, int maxDepth) {
    if (depth > maxDepth || sb.length > 20000) return;
    final chain = <String>[];
    var n = node;
    while (true) {
      chain.add(n['description'] as String? ?? n['type'] as String? ?? '?');
      final kids = (n['children'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
      if (kids.length == 1) {
        n = kids.first;
        continue;
      }
      final line = chain.length > 8
          ? [...chain.take(3), '…${chain.length - 6} more…', ...chain.skip(chain.length - 3)]
          : chain;
      sb.writeln('${'  ' * depth}${line.join(' → ')}');
      for (final k in kids) {
        _writeNode(sb, k, depth + 1, maxDepth);
      }
      return;
    }
  }


  Future<CallToolResult> _handleVisualDebug(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
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

      if (args.containsKey('performance_overlay')) {
        final on = args['performance_overlay'] as bool;
        await _service!.callServiceExtension(
          'ext.flutter.showPerformanceOverlay',
          isolateId: _isolateId,
          args: {'enabled': on},
        );
        results.add('performance_overlay: ${on ? 'ON — top bar = raster thread, bottom = UI thread, red = over budget' : 'OFF'}');
      }

      if (results.isEmpty) {
        return _ok('No flags set. Pass debug_paint, repaint_rainbow and/or performance_overlay (true/false).');
      }
      return _ok(results.join('\n'));
    } catch (e) {
      return _err(e);
    }
  }

  // ── Memory handlers ───────────────────────────────────────────────────────

  Future<CallToolResult> _handleMemoryTimeline(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;

      await _service!.streamListen(EventStreams.kGC).catchError((_) => Success());
      final gcEvents = <Event>[];
      final sub = _service!.onGCEvent.listen(gcEvents.add);
      final before = await _service!.getMemoryUsage(_isolateId!);
      await Future.delayed(Duration(seconds: dur));
      final after = await _service!.getMemoryUsage(_isolateId!);
      await sub.cancel();

      final heapBefore = before.heapUsage! / 1e6;
      final heapAfter = after.heapUsage! / 1e6;
      final delta = heapAfter - heapBefore;
      final rate = gcEvents.length / dur;
      final pauses = [
        for (final e in gcEvents)
          if (e.json?['durationMs'] case final num ms) ms.toDouble()
      ];

      final sb = StringBuffer();
      sb.writeln('Memory Timeline (${dur}s window)');
      sb.writeln('━' * 50);
      sb.writeln('Heap start : ${heapBefore.toStringAsFixed(1)} MB');
      sb.writeln('Heap end   : ${heapAfter.toStringAsFixed(1)} MB');
      sb.writeln('Delta      : ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} MB');
      sb.writeln('GC events  : ${gcEvents.length} (${rate.toStringAsFixed(1)}/sec)');
      if (pauses.isNotEmpty) {
        final avg = pauses.reduce((a, b) => a + b) / pauses.length;
        final max = pauses.reduce((a, b) => a > b ? a : b);
        sb.writeln('GC pause   : avg ${avg.toStringAsFixed(1)} ms, max ${max.toStringAsFixed(1)} ms');
      }
      sb.writeln('');

      // ponytail: rate-only thresholds; Dart's young-gen scavenges are frequent and cheap,
      // so ~1/sec while navigating is normal. Add pause-time checks if this misfires.
      if (rate > 5) {
        sb.writeln('CRITICAL GC pressure: >5 GC/sec — heavy allocation in a hot path.');
        sb.writeln('→ Avoid creating objects in build() or animation callbacks; find the function with get_cpu_hotspots.');
      } else if (rate > 2) {
        sb.writeln('ELEVATED GC pressure (>2/sec) — check for object creation in hot paths.');
      }
      if (delta > 10) {
        sb.writeln('Heap grew ${delta.toStringAsFixed(1)} MB in ${dur}s. → Run find_memory_leaks to confirm a leak.');
      } else if (rate <= 2) {
        sb.writeln('Memory looks stable.');
      }
      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleFindLeaks(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      final observe =
          (req.arguments?['observe_seconds'] as num?)?.toInt() ?? 5;

      // Phase 1: force GC then baseline
      await _service!.getAllocationProfile(_isolateId!, gc: true);
      await Future.delayed(const Duration(milliseconds: 500));
      final baseline =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      // Keyed by class id: names collide across libraries (e.g. two `Color` classes)
      final baselineCounts = {
        for (final c in baseline.members ?? <ClassHeapStats>[])
          if (c.classRef?.id != null) c.classRef!.id!: c.instancesCurrent ?? 0
      };

      // Phase 2: observe
      await Future.delayed(Duration(seconds: observe));

      // Phase 3: force GC again then measure
      await _service!.getAllocationProfile(_isolateId!, gc: true);
      await Future.delayed(const Duration(milliseconds: 500));
      final after =
          await _service!.getAllocationProfile(_isolateId!, gc: false);

      final leaks = <(String name, CodeOrigin origin, int delta)>[];
      for (final c in after.members ?? <ClassHeapStats>[]) {
        final before = baselineCounts[c.classRef?.id];
        // ponytail: classes absent from the baseline are skipped — the VM omits some
        // internal classes (Function, Namespace) from one profile and reports their whole
        // count as growth. First-time allocation isn't a leak anyway.
        final lib = _classLibraryUri(c);
        // No library = VM-internal (Code, ICData, Instructions…) — JIT compiles more
        // as you use a debug app; that growth is not a leak.
        if (before == null || lib.isEmpty) continue;
        final delta = (c.instancesCurrent ?? 0) - before;
        // Still growing after two GC cycles; tiny deltas are normal churn
        if (delta >= 5) leaks.add((c.classRef?.name ?? '?', codeOrigin(lib, _appPackage), delta));
      }
      // Your classes first — they are the actionable ones
      leaks.sort((a, b) => a.$2 != b.$2 ? a.$2.index.compareTo(b.$2.index) : b.$3.compareTo(a.$3));

      final sb = StringBuffer();
      sb.writeln('Leak Detection (GC → baseline → ${observe}s → GC → measure)');
      sb.writeln('━' * 60);

      if (leaks.isEmpty) {
        sb.writeln('No leaks detected. Instance counts stable after two GC cycles.');
        return _ok(sb.toString());
      }

      if (leaks.every((l) => l.$2 == CodeOrigin.sdk)) {
        sb.writeln('No growth in your classes or dependencies — likely no leak.');
        sb.writeln('Only framework/SDK objects grew (caches, buffers, strings — normal while the app is in use):');
      } else {
        sb.writeln('Classes growing despite GC (leak candidates, your code first):');
      }
      // Framework/SDK growth (lists, strings, caches) is usually a symptom — cap it
      final shown = [
        ...leaks.where((l) => l.$2 != CodeOrigin.sdk).take(15),
        ...leaks.where((l) => l.$2 == CodeOrigin.sdk).take(5),
      ];
      for (final (name, origin, delta) in shown) {
        final severity = delta > 50
            ? 'HIGH'
            : delta > 10
                ? 'MED '
                : 'LOW ';
        sb.writeln('  [$severity] ${name.padRight(40)} +$delta retained  (${origin.name})');
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
    if (!await _ensureConnected()) return _notConnected();
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
        sb.writeln('  ${name.padRight(45)} $inst instances — ${_fmtBytes(c.bytesCurrent ?? 0)}');
      }

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  static final _errorPattern = RegExp(
      r'Error|Exception|FATAL|assert|Unhandled|══╡|crash',
      caseSensitive: false);

  Future<CallToolResult> _handleWatchLogs(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    final service = _service!, isolateId = _isolateId!;
    final dur = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
    final filter = req.arguments?['filter'] as String?;
    final errorsOnly = req.arguments?['errors_only'] == true;
    bool? structuredWasOn;
    final subs = <StreamSubscription>[];
    try {
      for (final stream in [
        EventStreams.kStdout,
        EventStreams.kStderr,
        EventStreams.kLogging,
        EventStreams.kExtension,
      ]) {
        await service.streamListen(stream).catchError((_) => Success());
      }
      // Structured errors: Flutter.Error events carry the full error text and the
      // widget + file:line that caused it. Restored afterwards — while on, Flutter
      // sends errors to us instead of printing them in the flutter run terminal.
      try {
        final r = await service.callServiceExtension(
            'ext.flutter.inspector.structuredErrors', isolateId: isolateId);
        structuredWasOn = '${r.json?['enabled']}' == 'true';
        if (!structuredWasOn) {
          await service.callServiceExtension('ext.flutter.inspector.structuredErrors',
              isolateId: isolateId, args: {'enabled': true});
        }
      } catch (_) {} // profile mode: no inspector — stdout still catches errors

      final lines = <String>[];
      void add(String text, {bool isError = false}) {
        text = text.trim();
        if (text.isEmpty) return;
        if (errorsOnly && !isError && !_errorPattern.hasMatch(text)) return;
        if (filter != null && !text.contains(filter)) return;
        lines.add(text);
      }

      void onOutput(Event e) {
        if (e.bytes != null) add(utf8.decode(base64.decode(e.bytes!), allowMalformed: true));
      }

      subs
        ..add(service.onStdoutEvent.listen(onOutput))
        ..add(service.onStderrEvent.listen(onOutput))
        ..add(service.onLoggingEvent.listen((e) {
          final r = e.logRecord;
          if (r == null) return;
          final level = r.level ?? 0;
          final name = r.loggerName?.valueAsString ?? '';
          add('[log${name.isEmpty ? '' : ':$name'}] ${r.message?.valueAsString ?? ''}'
              '${r.error?.valueAsString == null ? '' : ' — ${r.error!.valueAsString}'}',
              isError: level >= 1000); // SEVERE
        }))
        ..add(service.onExtensionEvent.listen((e) {
          if (e.extensionKind != 'Flutter.Error') return;
          final d = e.extensionData?.data ?? {};
          add('══ FlutterError ══\n${d['renderedErrorText'] ?? d['description'] ?? d}',
              isError: true);
        }));

      await Future.delayed(Duration(seconds: dur));

      final what = '${errorsOnly ? 'errors' : 'output'} in ${dur}s'
          '${filter != null ? ' (filter: "$filter")' : ''}';
      return _ok(lines.isEmpty
          ? 'No $what.'
          : '${lines.length} entries — $what:\n${'━' * 50}\n${lines.join('\n')}');
    } catch (e) {
      return _err(e);
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      if (structuredWasOn == false) {
        await service.callServiceExtension('ext.flutter.inspector.structuredErrors',
            isolateId: isolateId, args: {'enabled': false}).catchError((_) => Response());
      }
    }
  }

  Future<CallToolResult> _handleHttpRequestBody(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
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
          headers.forEach((k, v) => sb.writeln('  $k: ${redactHeader(k, v)}'));
          sb.writeln('');
        }
      }

      final respData = result.response;
      if (respData != null) {
        final headers = respData.headers;
        if (headers != null && headers.isNotEmpty) {
          sb.writeln('Response headers:');
          headers.forEach((k, v) => sb.writeln('  $k: ${redactHeader(k, v)}'));
          sb.writeln('');
        }
      }

      void body(String label, List<int>? bytes) {
        if (bytes == null || bytes.isEmpty) return;
        final text = redactBody(utf8.decode(bytes, allowMalformed: true));
        sb.writeln('$label (${_fmtBytes(bytes.length)}):');
        sb.writeln(text.length > 4000 ? '${text.substring(0, 4000)}\n… truncated' : text);
        sb.writeln('');
      }

      body('Request body', result.requestBody);
      body('Response body', result.responseBody);

      return _ok(sb.toString());
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleListIsolates(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
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
    if (!await _ensureConnected()) return _notConnected();
    try {
      final expression = req.arguments!['expression'] as String;
      final frameIndex =
          (req.arguments?['frame_index'] as num?)?.toInt() ?? 0;

      // Get top stack frame from paused isolate, or use library scope
      final isolate = await _service!.getIsolate(_isolateId!);

      InstanceRef? result;

      // pauseEvent is never null — a running isolate reports kind Resume
      final pauseKind = isolate.pauseEvent?.kind;
      if (pauseKind == EventKind.kPauseBreakpoint ||
          pauseKind == EventKind.kPauseException ||
          pauseKind == EventKind.kPauseInterrupted) {
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

      // Objects have no valueAsString — ask the object itself
      var shown = result.valueAsString;
      if (shown == null && result.id != null) {
        try {
          final str = await _service!.evaluate(_isolateId!, result.id!, 'toString()');
          if (str is InstanceRef) shown = str.valueAsString;
        } catch (_) {}
      }

      final sb = StringBuffer();
      sb.writeln('Expression: $expression');
      sb.writeln('Result    : ${shown ?? result.classRef?.name ?? result.kind}');
      if (result.valueAsStringIsTruncated == true) {
        sb.writeln('(truncated — value is larger than shown)');
      }
      sb.writeln('Type      : ${result.classRef?.name ?? result.kind}');

      return _ok(sb.toString());
    } catch (e) {
      return _err('Eval failed: $e');
    }
  }

  // ── App info handler ──────────────────────────────────────────────────────

  Future<CallToolResult> _handleAppInfo(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
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
        targetPlatform = fv.json?['value']?.toString() ?? _os;
      } catch (_) {
        targetPlatform = _os; // platformOverride is debug-only
      }

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

  Future<CallToolResult> _handleScreenshot(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      // Get root widget object ID via getRootWidgetSummaryTree
      const groupName = 'screenshot_group';
      final rootResult = await _service!.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTree',
        isolateId: _isolateId,
        args: {'objectGroup': groupName},
      );
      final rootId = (rootResult.json?['result'] as Map<String, dynamic>?)?['valueId'] as String?;
      if (rootId == null) {
        return _ok('Screenshot failed: could not get root widget ID. Requires debug mode.');
      }

      // Fit into 500x1000 logical px at 1x — readable, and small enough for an AI
      // context (full-res phone PNGs were ~1.7M base64 chars)
      final result = await _service!.callServiceExtension(
        'ext.flutter.inspector.screenshot',
        isolateId: _isolateId,
        args: {
          'id': rootId,
          'width': '500',
          'height': '1000',
          'maxPixelRatio': '1',
        },
      );

      // Dispose object group to avoid memory leak
      await _service!.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: _isolateId,
        args: {'objectGroup': groupName},
      ).catchError((_) => Response());

      final base64Data = (result.json?['result'] as String?);
      if (base64Data == null || base64Data.isEmpty) {
        return _ok('Screenshot returned empty data. Make sure app is visible on screen.');
      }

      return CallToolResult(content: [
        ImageContent(data: base64Data, mimeType: 'image/png'),
        TextContent(text: 'Screenshot captured. AI can now see the current app screen.'),
      ]);
    } catch (e) {
      return _err(e);
    }
  }

  Future<CallToolResult> _handleHealthCheck(CallToolRequest req) async {
    if (!await _ensureConnected()) return _notConnected();
    try {
      // Screenshots need the debug-only inspector
      final shot = _isDebug ? await _handleScreenshot(req) : _ok('(no screenshot in profile mode)');
      final frames = await _jank.collectFromFrameTimings(
          _service!, _isolateId!, const Duration(seconds: 3));
      final mem = await _service!.getMemoryUsage(_isolateId!);

      final heapMb = mem.heapUsage! / 1e6;
      // ponytail: fixed 500 MB threshold (heap capacity grows, so % is meaningless).
      // Upgrade: compare against device RAM via the flutterMemoryInfo service.
      final memHigh = heapMb > 500;
      final enough = frames.length >= JankAnalyzer.minFrames;
      final jankPct = frames.isEmpty
          ? 0.0
          : frames.where((f) => f.isJanky()).length / frames.length * 100;

      final sb = StringBuffer();
      sb.writeln('┌─ HEALTH REPORT');
      sb.writeln('│ Frames : ${_jank.verdict(frames)}');
      sb.writeln('│ Memory : ${heapMb.toStringAsFixed(0)} MB Dart heap  ${memHigh ? '⚠ High' : '✓ OK'}');
      sb.writeln('└${'─' * 52}');
      sb.write(_debugCaveat());
      sb.writeln('');

      if (!enough) {
        sb.writeln('Not enough frames to judge smoothness. Run analyze_jank_causes '
            'and scroll/animate the app during the 5s capture.');
      } else if (jankPct > 20) {
        sb.writeln('SEVERE JANK detected. Run: analyze_jank_causes');
        sb.writeln('Scroll/interact with the slow part of the app while it captures.');
      } else if (jankPct > 5) {
        sb.writeln('Minor jank detected. Run: get_widget_rebuild_counts (duration_seconds: 8)');
        sb.writeln('Interact with the app during capture to find excessive rebuilds.');
      } else if (memHigh) {
        sb.writeln('Large Dart heap. Run: find_memory_leaks');
        sb.writeln('Use the app normally while it runs — takes ~10 seconds.');
      } else {
        sb.writeln('App looks healthy! If something specific feels slow, run: analyze_jank_causes');
      }

      return CallToolResult(content: [...shot.content, TextContent(text: sb.toString())]);
    } catch (e) {
      return _err(e);
    }
  }

}

// Tool output goes to the AI provider — never forward credentials.
final _secretHeader = RegExp(
    r'^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|api-key)$',
    caseSensitive: false);
const _secretKey = r'[^"&=\s]*(?:password|passwd|secret|token|api[_-]?key)[^"&=\s]*|otp|pin';
final _secretJson = RegExp('("(?:$_secretKey)"\\s*:\\s*)"[^"]*"', caseSensitive: false);
final _secretForm = RegExp('(^|&)((?:$_secretKey)=)[^&]*', caseSensitive: false);

Object? redactHeader(String name, Object? value) =>
    _secretHeader.hasMatch(name) ? '[redacted]' : value;

String redactBody(String body) => body
    .replaceAllMapped(_secretJson, (m) => '${m[1]}"[redacted]"')
    .replaceAllMapped(_secretForm, (m) => '${m[1]}${m[2]}[redacted]');
