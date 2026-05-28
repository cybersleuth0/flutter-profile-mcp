import 'package:vm_service/vm_service.dart';

class CpuAnalyzer {
  String generateHotspotReport(CpuSamples samples, {int topN = 10}) {
    final total = samples.sampleCount ?? 1;
    final functions = samples.functions ?? [];

    final sorted = [...functions]
      ..sort(
          (a, b) => (b.exclusiveTicks ?? 0).compareTo(a.exclusiveTicks ?? 0));

    final user =
        sorted.where((f) => !_isVmInternal(f.function?.name ?? '')).take(topN).toList();

    final windowSec =
        ((samples.timeExtentMicros ?? 0) / 1e6).toStringAsFixed(1);
    final sb = StringBuffer();
    sb.writeln('CPU Hotspots (${windowSec}s window, $total samples)');
    sb.writeln('━' * 60);
    sb.writeln('${'Rank'.padRight(6)}${'Self%'.padRight(8)}${'Total%'.padRight(9)}Function');

    for (int i = 0; i < user.length; i++) {
      final f = user[i];
      final selfPct =
          ((f.exclusiveTicks ?? 0) / total * 100).toStringAsFixed(1).padLeft(5);
      final totalPct =
          ((f.inclusiveTicks ?? 0) / total * 100).toStringAsFixed(1).padLeft(6);
      final name = _formatName(f);
      sb.writeln('  ${(i + 1).toString().padLeft(2)}.  $selfPct%  $totalPct%  $name');
    }

    sb.writeln('');
    sb.writeln(_advice(user, total));
    return sb.toString();
  }

  String _formatName(ProfileFunction f) {
    final fn = f.function;
    if (fn == null) return 'unknown';
    final owner = fn.owner;
    if (owner?.name != null && owner!.name!.isNotEmpty) {
      return '${owner.name}.${fn.name}';
    }
    return fn.name ?? 'unknown';
  }

  bool _isVmInternal(String name) =>
      name == '[Truncated]' ||
      name == '[Native]' ||
      name == '[Stub]' ||
      name.startsWith('dart:');

  String _advice(List<ProfileFunction> hot, int total) {
    final lines = <String>[];
    for (final f in hot.take(3)) {
      final selfPct = (f.exclusiveTicks ?? 0) / total * 100;
      final name = _formatName(f);
      if (selfPct > 10 && name.toLowerCase().contains('build')) {
        lines.add(
            '• $name: high CPU in build(). Move expensive work outside build() or cache results.');
      } else if (selfPct > 10 &&
          (name.toLowerCase().contains('decode') ||
              name.toLowerCase().contains('image'))) {
        lines.add(
            '• $name: image/decode cost. Use compute() to offload to background isolate.');
      } else if (selfPct > 5) {
        lines.add(
            '• $name: ${selfPct.toStringAsFixed(1)}% self-time. Profile for algorithmic improvements.');
      }
    }
    return lines.isEmpty
        ? 'No obvious CPU hotspots.'
        : 'Suggestions:\n${lines.join('\n')}';
  }
}
