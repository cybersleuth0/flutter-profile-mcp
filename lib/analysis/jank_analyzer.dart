import 'package:vm_service/vm_service.dart';

class FrameData {
  final int frameNumber;
  final int uiStartMicros;
  final int uiDurationMicros;
  final int rasterDurationMicros;
  final int totalDurationMicros;

  const FrameData({
    required this.frameNumber,
    required this.uiStartMicros,
    required this.uiDurationMicros,
    required this.rasterDurationMicros,
    required this.totalDurationMicros,
  });

  bool isJanky({int targetFps = 60}) =>
      totalDurationMicros > (1000000 ~/ targetFps);
}

class _RawFrame {
  final int start;
  final int duration;
  _RawFrame(this.start, this.duration);
}

class JankAnalyzer {
  List<FrameData> parseFrames(Timeline timeline) {
    final events = timeline.traceEvents ?? [];

    final uiFrames = <_RawFrame>[];
    final rasterFrames = <_RawFrame>[];

    // Pass 1: collect all UI frame intervals from [Dart] Frame events
    // and all raster intervals from [Embedder] GPURasterizer::Draw
    final Map<String, int> openBegin = {}; // key = "name|tid"

    for (final event in events) {
      final raw = event.json;
      if (raw == null) continue;
      final name = raw['name'] as String? ?? '';
      final ph = raw['ph'] as String? ?? '';
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      final tid = raw['tid'].toString();
      final cat = raw['cat'] as String? ?? '';

      // UI: [Dart] Frame — top-level frame bracket confirmed on iOS Impeller
      if (name == 'Frame' && cat == 'Dart') {
        final key = 'ui|$tid';
        if (ph == 'B') {
          openBegin[key] = ts;
        } else if (ph == 'E') {
          final begin = openBegin.remove(key);
          if (begin != null && ts > begin) {
            uiFrames.add(_RawFrame(begin, ts - begin));
          }
        } else if (ph == 'X') {
          final dur = (raw['dur'] as num?)?.toInt() ?? 0;
          if (dur > 0) uiFrames.add(_RawFrame(ts, dur));
        }
      }

      // Raster: [Embedder] GPURasterizer::Draw — confirmed on iOS Impeller
      // Also try CompositorContext::ScopedFrame::Raster as fallback
      final isRaster = (name == 'GPURasterizer::Draw' ||
              name == 'CompositorContext::ScopedFrame::Raster') &&
          cat == 'Embedder';

      if (isRaster) {
        final key = 'raster|$tid';
        if (ph == 'B') {
          openBegin[key] = ts;
        } else if (ph == 'E') {
          final begin = openBegin.remove(key);
          if (begin != null && ts > begin) {
            rasterFrames.add(_RawFrame(begin, ts - begin));
          }
        } else if (ph == 'X') {
          final dur = (raw['dur'] as num?)?.toInt() ?? 0;
          if (dur > 0) rasterFrames.add(_RawFrame(ts, dur));
        }
      }
    }

    if (uiFrames.isEmpty) return [];

    // Sort both by start time
    uiFrames.sort((a, b) => a.start.compareTo(b.start));
    rasterFrames.sort((a, b) => a.start.compareTo(b.start));

    // Pass 2: pair each UI frame with the raster frame that starts
    // closest AFTER the UI frame starts (pipeline: raster follows UI)
    final frames = <FrameData>[];
    int rasterIdx = 0;

    for (int i = 0; i < uiFrames.length; i++) {
      final ui = uiFrames[i];

      // Find first raster frame that starts at or after this UI frame start
      while (rasterIdx < rasterFrames.length &&
          rasterFrames[rasterIdx].start < ui.start) {
        rasterIdx++;
      }

      int rasterDur = 0;
      if (rasterIdx < rasterFrames.length) {
        final raster = rasterFrames[rasterIdx];
        // Only pair if raster starts within 2 frame budgets of UI start (33ms)
        if (raster.start - ui.start < 33000) {
          rasterDur = raster.duration;
          rasterIdx++; // consume this raster frame
        }
      }

      final total = ui.duration > rasterDur ? ui.duration : rasterDur;
      frames.add(FrameData(
        frameNumber: i + 1,
        uiStartMicros: ui.start,
        uiDurationMicros: ui.duration,
        rasterDurationMicros: rasterDur,
        totalDurationMicros: total,
      ));
    }

    return frames;
  }

  /// Debug: return all unique [cat] name pairs — diagnose missing frames
  List<String> debugEventNames(Timeline timeline) {
    final names = <String>{};
    for (final e in timeline.traceEvents ?? []) {
      final name = e.json?['name'] as String?;
      final cat = e.json?['cat'] as String?;
      if (name != null) names.add('[$cat] $name');
    }
    return names.toList()..sort();
  }

  /// Debug: count raw frame events before pairing
  Map<String, int> debugFrameCounts(Timeline timeline) {
    int uiFrameCount = 0;
    int rasterCount = 0;
    int totalEvents = timeline.traceEvents?.length ?? 0;

    for (final e in timeline.traceEvents ?? []) {
      final raw = e.json;
      if (raw == null) continue;
      final name = raw['name'] as String? ?? '';
      final cat = raw['cat'] as String? ?? '';
      final ph = raw['ph'] as String? ?? '';
      if (name == 'Frame' && cat == 'Dart' && (ph == 'B' || ph == 'X')) {
        uiFrameCount++;
      }
      if ((name == 'GPURasterizer::Draw' ||
              name == 'CompositorContext::ScopedFrame::Raster') &&
          cat == 'Embedder' &&
          (ph == 'B' || ph == 'X')) {
        rasterCount++;
      }
    }
    return {
      'total_events': totalEvents,
      'ui_frames': uiFrameCount,
      'raster_frames': rasterCount,
    };
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
    final rasterJank = janky
        .where((f) =>
            f.rasterDurationMicros > budgetMicros &&
            f.uiDurationMicros <= budgetMicros)
        .length;

    final sorted = [...frames]
      ..sort((a, b) => b.totalDurationMicros.compareTo(a.totalDurationMicros));

    // Estimate actual FPS from timestamps
    String fpsNote = '';
    if (frames.length >= 2) {
      final windowMicros =
          frames.last.uiStartMicros - frames.first.uiStartMicros;
      if (windowMicros > 0) {
        final measuredFps =
            ((frames.length - 1) / (windowMicros / 1e6)).toStringAsFixed(1);
        fpsNote = ' (~$measuredFps fps measured)';
      }
    }

    final hasRasterData = frames.any((f) => f.rasterDurationMicros > 0);

    final sb = StringBuffer();
    sb.writeln(
        'Frame Analysis (${frames.length} frames$fpsNote, ${targetFps}fps budget = ${budgetMicros ~/ 1000}ms)');
    sb.writeln('━' * 60);
    sb.writeln(
        'Janky frames: ${janky.length}/${frames.length} ($jankyPct%) — ${_severity(janky.length, frames.length)}');

    if (!hasRasterData) {
      sb.writeln('Raster data: not captured (raster thread events absent)');
      sb.writeln('  → Run in profile mode for raster timing: flutter run --profile');
    }

    if (uiJank > 0) {
      sb.writeln('');
      sb.writeln('UI thread jank: $uiJank frames');
      sb.writeln(
          '  → Dart code slow. Check build(), layout, compute on main isolate.');
    }
    if (rasterJank > 0) {
      sb.writeln('');
      sb.writeln('Raster thread jank: $rasterJank frames');
      sb.writeln(
          '  → GPU work slow. Check: large images, clips, opacity layers, shadows.');
    }

    sb.writeln('');
    sb.writeln('Worst 5 frames:');
    for (final f in sorted.take(5)) {
      final rasterStr = hasRasterData
          ? ', Raster: ${(f.rasterDurationMicros / 1000).toStringAsFixed(2)}ms'
          : '';
      sb.writeln(
          '  Frame ${f.frameNumber}: ${(f.totalDurationMicros / 1000).toStringAsFixed(2)}ms'
          ' (UI: ${(f.uiDurationMicros / 1000).toStringAsFixed(2)}ms$rasterStr)');
    }

    return sb.toString();
  }

  String _severity(int janky, int total) {
    final pct = janky / total;
    if (pct < 0.05) return 'GOOD';
    if (pct < 0.15) return 'MINOR';
    if (pct < 0.30) return 'MODERATE';
    return 'SEVERE';
  }
}
