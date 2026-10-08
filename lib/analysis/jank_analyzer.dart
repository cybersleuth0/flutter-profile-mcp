import 'package:vm_service/vm_service.dart';

class FrameData {
  final int frameNumber;
  final int uiStartMicros;
  final int uiDurationMicros;      // build time (Dart work)
  final int rasterDurationMicros;  // raster time (GPU work)
  final int totalDurationMicros;   // elapsed wall time (includes vsync wait)

  const FrameData({
    required this.frameNumber,
    required this.uiStartMicros,
    required this.uiDurationMicros,
    required this.rasterDurationMicros,
    required this.totalDurationMicros,
  });

  // UI and raster threads are pipelined, so a frame's cost is its slower thread —
  // summing them double-counts. Excludes vsync idle (which inflates elapsed).
  int get workDurationMicros => uiDurationMicros > rasterDurationMicros
      ? uiDurationMicros
      : rasterDurationMicros;

  // Same rule as DevTools: janky if either thread blew the budget
  bool isJanky({int targetFps = 60}) =>
      workDurationMicros > (1000000 ~/ targetFps);
}

class JankAnalyzer {
  /// Primary method: collect FrameTiming events from flutter.frame extension stream.
  /// Flutter emits pre-computed build+raster+vsync breakdown per frame.
  /// Much more accurate than parsing raw timeline events.
  Future<List<FrameData>> collectFromFrameTimings(
    VmService service,
    String isolateId,
    Duration window,
  ) async {
    final frames = <FrameData>[];

    await service.streamListen(EventStreams.kExtension).catchError((_) => Success());

    // Kick engine to produce frames — needed on Android/emulator when app is idle
    await service.callServiceExtension(
      'ext.ui.window.scheduleFrame',
      isolateId: isolateId,
    ).catchError((_) => Response());

    final sub = service.onExtensionEvent.listen((event) {
      if (event.extensionKind != 'Flutter.Frame') return;
      final data = event.extensionData?.data ?? event.json;
      if (data == null) return;

      // Flutter.Frame payload:
      // { number, startTime, elapsed, build, raster, vsyncOverhead }
      // All times in microseconds
      final build = (data['build'] as num?)?.toInt() ?? 0;
      final raster = (data['raster'] as num?)?.toInt() ?? 0;
      final elapsed = (data['elapsed'] as num?)?.toInt() ??
          (build + raster); // elapsed = build + raster + vsyncOverhead
      final startTime = (data['startTime'] as num?)?.toInt() ?? 0;

      if (elapsed <= 0 && build <= 0) return;

      final total = elapsed > 0 ? elapsed : (build + raster);
      frames.add(FrameData(
        frameNumber: frames.length + 1,
        uiStartMicros: startTime,
        uiDurationMicros: build,
        rasterDurationMicros: raster,
        totalDurationMicros: total,
      ));
    });

    await Future.delayed(window);
    await sub.cancel();
    return frames;
  }

  String generateReport(List<FrameData> frames, {int targetFps = 60}) {
    if (frames.isEmpty) {
      return 'No frame data captured. Interact with the app during recording window.';
    }

    final budgetMicros = 1000000 ~/ targetFps;
    final janky = frames.where((f) => f.isJanky(targetFps: targetFps)).toList();
    final jankyPct = (janky.length / frames.length * 100).toStringAsFixed(1);

    final uiJank =
        janky.where((f) => f.uiDurationMicros > budgetMicros).length;
    final rasterJank =
        janky.where((f) => f.rasterDurationMicros > budgetMicros).length;

    final sorted = [...frames]
      ..sort((a, b) => b.workDurationMicros.compareTo(a.workDurationMicros));

    final f = fps(frames, targetFps: targetFps);
    final fpsNote = f == null ? '' : ' (~${f.toStringAsFixed(1)} fps)';

    final hasRaster = frames.any((f) => f.rasterDurationMicros > 0);

    final sb = StringBuffer();
    sb.writeln(
        'Frame Analysis — ${frames.length} frames$fpsNote');
    sb.writeln('Budget: ${budgetMicros ~/ 1000}ms at ${targetFps}fps');
    sb.writeln('━' * 60);
    sb.writeln(
        'Janky: ${janky.length}/${frames.length} ($jankyPct%) — ${_severity(janky.length, frames.length)}');

    if (!hasRaster) {
      sb.writeln(
          'Raster timing: unavailable in debug mode (run --profile for raster data)');
    }

    if (uiJank > 0) {
      sb.writeln('');
      sb.writeln('UI jank: $uiJank frames over budget');
      sb.writeln('  → Dart code slow. Check build(), layout, heavy compute.');
    }
    if (rasterJank > 0) {
      sb.writeln('');
      sb.writeln('Raster jank: $rasterJank frames');
      sb.writeln('  → GPU slow. Check: large images, clips, opacity, shadows.');
    }

    sb.writeln('');
    sb.writeln('Worst 5 frames:');
    for (final f in sorted.take(5)) {
      final r = hasRaster
          ? ', Raster: ${(f.rasterDurationMicros / 1000).toStringAsFixed(2)}ms'
          : '';
      sb.writeln(
          '  Frame ${f.frameNumber}: ${(f.workDurationMicros / 1000).toStringAsFixed(2)}ms slowest thread'
          ' (Build: ${(f.uiDurationMicros / 1000).toStringAsFixed(2)}ms$r)');
    }

    return sb.toString();
  }

  /// Frames per second over the capture, or null if it can't be computed.
  double? fps(List<FrameData> frames, {int targetFps = 60}) {
    // Flutter only renders when something changes, so pauses between interactions
    // aren't slow frames. Only frame-to-frame gaps under 100ms count as rendering.
    var gaps = 0, activeMicros = 0;
    for (var i = 1; i < frames.length; i++) {
      final gap = frames[i].uiStartMicros - frames[i - 1].uiStartMicros;
      if (gap > 0 && gap < 100000) {
        gaps++;
        activeMicros += gap;
      }
    }
    if (gaps == 0) return null;
    final rawFps = gaps / (activeMicros / 1e6);
    // Cap at targetFps+10 — higher values indicate stale timeline events
    return rawFps > targetFps + 10 ? targetFps.toDouble() : rawFps;
  }

  /// One-line verdict. Below [minFrames] the sample is too small to judge.
  String verdict(List<FrameData> frames, {int targetFps = 60}) {
    if (frames.length < minFrames) {
      return '? INSUFFICIENT DATA — only ${frames.length} frames captured '
          '(need $minFrames+). Interact with the app (scroll/animate) during capture.';
    }
    final jankPct =
        frames.where((f) => f.isJanky(targetFps: targetFps)).length /
            frames.length *
            100;
    final f = fps(frames, targetFps: targetFps) ?? targetFps.toDouble();
    final pct = jankPct.toStringAsFixed(1);
    final fpsStr = f.toStringAsFixed(1);
    if (jankPct < 5 && f >= targetFps * 0.9) return '✓ HEALTHY — $pct% jank, ${fpsStr}fps';
    if (jankPct > 20) return '✗ SEVERE JANK — $pct% frames over budget, ${fpsStr}fps';
    if (f < targetFps * 0.8) {
      return '⚠ LOW FPS — ${fpsStr}fps (target $targetFps). UI thread blocked between frames '
          '(scroll listeners, timers, stream emissions)';
    }
    return '~ MINOR — $pct% jank, ${fpsStr}fps';
  }

  static const minFrames = 30;

  String _severity(int janky, int total) {
    final pct = janky / total;
    if (pct < 0.05) return 'GOOD';
    if (pct < 0.15) return 'MINOR';
    if (pct < 0.30) return 'MODERATE';
    return 'SEVERE';
  }
}
