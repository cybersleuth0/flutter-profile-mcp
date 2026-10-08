import 'package:vm_service/vm_service.dart';

enum CodeOrigin { app, dependency, sdk }

/// Classifies a source URL. Handles `package:` URIs (class libraries, AOT
/// samples) and `file:` paths (JIT CPU samples). [appPackage] is e.g.
/// `package:my_app/`; when null, any non-SDK package counts as app code.
CodeOrigin codeOrigin(String url, String? appPackage) {
  if (url.isEmpty ||
      url.startsWith('dart:') ||
      url.contains('org-dartlang-sdk') ||
      url.startsWith('package:flutter/') ||
      url.startsWith('package:flutter_test/') ||
      url.startsWith('package:sky_engine/') ||
      url.contains('/packages/flutter/') ||
      url.contains('/bin/cache/')) {
    return CodeOrigin.sdk;
  }
  if (url.startsWith('package:')) {
    if (appPackage == null || url.startsWith(appPackage)) return CodeOrigin.app;
    return CodeOrigin.dependency;
  }
  if (url.startsWith('file:')) {
    // ponytail: pub-cache = dependency; path/git deps outside it count as app code
    return url.contains('/.pub-cache/') ? CodeOrigin.dependency : CodeOrigin.app;
  }
  return CodeOrigin.sdk; // native frames: .so / .dylib paths
}

class CpuAnalyzer {
  /// Top app function and its self %, or null if none.
  ({String name, double selfPct})? topHotspot(CpuSamples samples,
      {String? appPackage}) {
    final top = _functions(samples, appPackage, CodeOrigin.app, 1);
    if (top.isEmpty) return null;
    return (
      name: _formatName(top.first),
      selfPct: (top.first.exclusiveTicks ?? 0) / _total(samples) * 100,
    );
  }

  int _total(CpuSamples s) => (s.sampleCount ?? 0) < 1 ? 1 : s.sampleCount!;

  String generateHotspotReport(CpuSamples samples,
      {int topN = 10, String? appPackage}) {
    final total = _total(samples);
    final app = _functions(samples, appPackage, CodeOrigin.app, topN);
    final deps = _functions(samples, appPackage, CodeOrigin.dependency, 3);
    final sdk = _functions(samples, appPackage, CodeOrigin.sdk, 3);

    final sb = StringBuffer();
    sb.writeln('CPU Hotspots — ${samples.sampleCount ?? 0} samples');
    sb.writeln('━' * 60);
    if ((samples.sampleCount ?? 0) < 50) {
      sb.writeln('⚠ Only ${samples.sampleCount ?? 0} samples — the app was mostly idle. '
          'Use the slow feature during the capture.');
    }
    sb.writeln('Your code${appPackage == null ? '' : ' ($appPackage)'}:');
    sb.writeln('${'Rank'.padRight(6)}${'Self%'.padRight(8)}${'Total%'.padRight(9)}Function');
    _rows(sb, app, total);
    if (app.isEmpty) sb.writeln('  (no samples in your code)');
    if (deps.isNotEmpty) {
      sb.writeln('');
      sb.writeln('Dependencies (pub packages):');
      _rows(sb, deps, total);
    }
    // Shows where time went when your code is quiet (e.g. gesture dispatch while scrolling)
    if (sdk.isNotEmpty) {
      sb.writeln('');
      sb.writeln('Flutter framework / Dart SDK:');
      _rows(sb, sdk, total);
    }

    sb.writeln('');
    sb.writeln(_advice(app, total));
    return sb.toString();
  }

  void _rows(StringBuffer sb, List<ProfileFunction> fns, int total) {
    for (int i = 0; i < fns.length; i++) {
      final f = fns[i];
      final selfPct =
          ((f.exclusiveTicks ?? 0) / total * 100).toStringAsFixed(1).padLeft(5);
      final totalPct =
          ((f.inclusiveTicks ?? 0) / total * 100).toStringAsFixed(1).padLeft(6);
      sb.writeln('  ${(i + 1).toString().padLeft(2)}.  $selfPct%  $totalPct%  ${_formatName(f)}');
    }
  }

  List<ProfileFunction> _functions(
      CpuSamples samples, String? appPackage, CodeOrigin origin, int topN) {
    final sorted = [...samples.functions ?? <ProfileFunction>[]]
      ..sort(
          (a, b) => (b.exclusiveTicks ?? 0).compareTo(a.exclusiveTicks ?? 0));
    return sorted.where((f) {
      final url = f.resolvedUrl ?? '';
      // Bracket notation = VM internal/native regardless of URL
      if (_formatName(f).startsWith('[')) return false;
      if ((f.inclusiveTicks ?? 0) == 0) return false; // never sampled
      if (!url.endsWith('.dart')) return false; // .so, .dylib, empty = not Dart
      return codeOrigin(url, appPackage) == origin;
    }).take(topN).toList();
  }

  String _formatName(ProfileFunction f) {
    final fn = f.function;
    if (fn == null) return 'unknown';

    // vm_service returns function as dynamic — may be typed obj or raw Map
    if (fn is Map) {
      final name = fn['name'] as String? ?? 'unknown';
      final owner = fn['owner'];
      final ownerName = owner is Map ? owner['name'] as String? : null;
      if (ownerName != null && ownerName.isNotEmpty) return '$ownerName.$name';
      return name;
    }

    // Typed FuncRef / ObjRef path
    try {
      final ownerName = (fn as dynamic).owner?.name as String?;
      final fnName = (fn as dynamic).name as String? ?? 'unknown';
      if (ownerName != null && ownerName.isNotEmpty) return '$ownerName.$fnName';
      return fnName;
    } catch (_) {
      return fn.toString();
    }
  }



  String _advice(List<ProfileFunction> hot, int total) {
    final lines = <String>[];
    for (final f in hot.take(5)) {
      final selfPct = (f.exclusiveTicks ?? 0) / total * 100;
      final totalPct = (f.inclusiveTicks ?? 0) / total * 100;
      final name = _formatName(f);
      final nameLower = name.toLowerCase();

      if (selfPct > 10 && nameLower.contains('build')) {
        lines.add('• $name: ${selfPct.toStringAsFixed(1)}% self in build(). Move expensive work outside or cache results.');
      } else if (selfPct > 10 && (nameLower.contains('decode') || nameLower.contains('image'))) {
        lines.add('• $name: ${selfPct.toStringAsFixed(1)}% — image/decode cost. Use compute() to offload to isolate.');
      } else if (selfPct > 5) {
        lines.add('• $name: ${selfPct.toStringAsFixed(1)}% self-time — algorithmic bottleneck.');
      } else if (totalPct > 10 && selfPct < 2) {
        // High inclusive but low exclusive = expensive call chain passing through this fn
        lines.add('• $name: ${totalPct.toStringAsFixed(1)}% total (${selfPct.toStringAsFixed(1)}% self) — expensive call chain. Check callees.');
      }
    }
    return lines.isEmpty
        ? 'No obvious CPU hotspots. App CPU usage looks healthy.'
        : 'Suggestions:\n${lines.join('\n')}';
  }
}
