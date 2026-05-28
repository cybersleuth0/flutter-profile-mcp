import 'dart:async';
import 'package:vm_service/vm_service.dart';

class RebuildCollector {
  final Map<String, int> _counts = {};
  StreamSubscription<Event>? _sub;
  bool _gotEvents = false;

  void start(VmService service) {
    service.streamListen(EventStreams.kExtension).catchError((_) => Success());
    _sub = service.onExtensionEvent.listen((event) {
      // Flutter emits this under multiple possible kinds depending on version
      if (event.extensionKind == 'Flutter.RebuiltWidgets' ||
          event.extensionKind == 'Flutter.RepaintWidgets' ||
          event.extensionKind == 'Flutter.RebuildDirtyWidgets') {
        final data = event.extensionData?.data ?? event.json;
        if (data == null) return;
        _gotEvents = true;

        // Try top-level 'widgets' array
        final widgets = data['widgets'] as List<dynamic>?;
        if (widgets != null) {
          for (final w in widgets) {
            if (w is! Map) continue;
            final name = w['widget']?.toString() ??
                w['name']?.toString() ??
                'Unknown';
            final count = (w['count'] as num?)?.toInt() ?? 1;
            _counts[name] = (_counts[name] ?? 0) + count;
          }
        }

        // Some versions emit map of name→count directly
        final counts = data['counts'] as Map<String, dynamic>?;
        if (counts != null) {
          _gotEvents = true;
          counts.forEach((k, v) {
            _counts[k] = (_counts[k] ?? 0) + ((v as num?)?.toInt() ?? 1);
          });
        }
      }
    });
  }

  bool get gotEvents => _gotEvents;

  Future<String> stopAndReport() async {
    await _sub?.cancel();
    _sub = null;

    if (_counts.isEmpty) {
      return 'No rebuild events captured. '
          'Interact with the app during the recording window.\n'
          'Note: rebuild tracking requires debug mode and flutter inspector active.';
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
      sb.writeln('  • Use BlocSelector / select() to narrow rebuild scope');
      sb.writeln('  • Move state lower in tree to avoid rebuilding parents');
    }

    return sb.toString();
  }
}
