import 'package:vm_service/vm_service.dart';

class FrameData {
  final int frameNumber;
  final int uiDurationMicros;
  final int rasterDurationMicros;
  final int totalDurationMicros;

  const FrameData({
    required this.frameNumber,
    required this.uiDurationMicros,
    required this.rasterDurationMicros,
    required this.totalDurationMicros,
  });

  bool isJanky({int targetFps = 60}) =>
      totalDurationMicros > (1000000 ~/ targetFps);
}

class JankAnalyzer {
  List<FrameData> parseFrames(Timeline timeline) {
    final events = timeline.traceEvents ?? [];
    final Map<String, int> uiBegin = {};
    final Map<String, int> rasterBegin = {};
    final List<FrameData> frames = [];

    for (final event in events) {
      final raw = event.json;
      if (raw == null) continue;
      final name = raw['name'] as String? ?? '';
      final ph = raw['ph'] as String? ?? '';
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      final tid = raw['tid'].toString();

      // UI thread frame markers
      if (name == 'Frame' || name == 'vsync callback') {
        if (ph == 'B') {
          uiBegin[tid] = ts;
        } else if (ph == 'E') {
          final begin = uiBegin[tid];
          if (begin != null) {
            frames.add(FrameData(
              frameNumber: frames.length + 1,
              uiDurationMicros: ts - begin,
              rasterDurationMicros: 0,
              totalDurationMicros: ts - begin,
            ));
            uiBegin.remove(tid);
          }
        }
      }

      // Raster thread — try to update last frame's raster time
      if ((name == 'GPURasterizer::DoDraw' || name == 'Rasterize') && frames.isNotEmpty) {
        if (ph == 'B') {
          rasterBegin[tid] = ts;
        } else if (ph == 'E') {
          final begin = rasterBegin[tid];
          if (begin != null) {
            final dur = ts - begin;
            final last = frames.last;
            frames[frames.length - 1] = FrameData(
              frameNumber: last.frameNumber,
              uiDurationMicros: last.uiDurationMicros,
              rasterDurationMicros: dur,
              totalDurationMicros:
                  last.uiDurationMicros > dur ? last.uiDurationMicros : dur,
            );
            rasterBegin.remove(tid);
          }
        }
      }
    }

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
    final rasterJank = janky
        .where((f) =>
            f.rasterDurationMicros > budgetMicros &&
            f.uiDurationMicros <= budgetMicros)
        .length;

    final sorted = [...frames]
      ..sort((a, b) => b.totalDurationMicros.compareTo(a.totalDurationMicros));

    final sb = StringBuffer();
    sb.writeln(
        'Frame Analysis (${frames.length} frames, ${targetFps}fps = ${budgetMicros ~/ 1000}ms budget)');
    sb.writeln('━' * 60);
    sb.writeln(
        'Janky frames: ${janky.length}/${frames.length} ($jankyPct%) — ${_severity(janky.length, frames.length)}');

    if (uiJank > 0) {
      sb.writeln('');
      sb.writeln('UI thread jank: $uiJank frames');
      sb.writeln(
          '  → Dart code slow. Check build(), layout, or compute on main isolate.');
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
      sb.writeln(
          '  Frame ${f.frameNumber}: ${(f.totalDurationMicros / 1000).toStringAsFixed(2)}ms'
          ' (UI: ${(f.uiDurationMicros / 1000).toStringAsFixed(2)}ms,'
          ' Raster: ${(f.rasterDurationMicros / 1000).toStringAsFixed(2)}ms)');
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
