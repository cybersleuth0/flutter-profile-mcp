import 'dart:async';
import 'package:vm_service/vm_service.dart';

class RebuildCollector {
  final Map<String, int> _counts = {};
  StreamSubscription<Event>? _sub;

  void start(VmService service) {
    service.streamListen(EventStreams.kExtension).catchError((_) => Success());
    _sub = service.onExtensionEvent.listen((event) {
      if (event.extensionKind == 'Flutter.RebuiltWidgets') {
        final data = event.extensionData?.data;
        if (data == null) return;
        final widgets = data['widgets'] as List<dynamic>? ?? [];
        for (final w in widgets) {
          final name = w['widget'] as String? ?? 'Unknown';
          final count = (w['count'] as num?)?.toInt() ?? 1;
          _counts[name] = (_counts[name] ?? 0) + count;
        }
      }
    });
  }

  Future<String> stopAndReport() async {
    await _sub?.cancel();
    _sub = null;

    if (_counts.isEmpty) {
      return 'No rebuild events captured. '
          'Interact with the app during the recording window.';
    }

    final sorted = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final sb = StringBuffer();
    sb.writeln('Widget Rebuild Counts:');
    sb.writeln('━' * 50);

    for (final e in sorted.take(20)) {
      final flag = e.value > 50
          ? '  ← EXCESSIVE'
          : e.value > 20
              ? '  ← HIGH'
              : '';
      sb.writeln(
          '  ${e.key.padRight(35)} ${e.value.toString().padLeft(5)} rebuilds$flag');
    }

    final excessive = sorted.where((e) => e.value > 50).toList();
    if (excessive.isNotEmpty) {
      sb.writeln('');
      sb.writeln('Fixes for excessive rebuilds:');
      sb.writeln('  • Wrap stable subtrees with const constructors');
      sb.writeln('  • Add RepaintBoundary around independently-updating widgets');
      sb.writeln(
          '  • Use BlocSelector / select() to narrow rebuild scope');
      sb.writeln('  • Move state lower in tree to avoid rebuilding parents');
    }

    return sb.toString();
  }
}
