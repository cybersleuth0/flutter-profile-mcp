import 'dart:async';
import 'package:vm_service/vm_service.dart';

class RebuildCollector {
  // id → widget name cache (populated from 'locations'/'newLocations' payloads)
  final Map<int, String> _idToName = {};
  final Map<String, int> _counts = {};
  StreamSubscription<Event>? _sub;

  void start(VmService service) {
    // Ignore error 103 (stream already subscribed) — another tool may own it
    service.streamListen(EventStreams.kExtension).catchError((_) => Success());

    _sub = service.onExtensionEvent.listen((event) {
      if (event.extensionKind != 'Flutter.RebuiltWidgets' &&
          event.extensionKind != 'Flutter.RepaintWidgets') return;

      final data = event.extensionData?.data ?? event.json;
      if (data == null) return;

      // Parse new location names from this event's 'locations' or 'newLocations'
      _parseLocations(data['locations']);
      _parseLocationsLegacy(data['newLocations']);

      // events = flat [id, count, id, count, ...]
      final events = data['events'];
      if (events is List && events.length >= 2) {
        for (int i = 0; i + 1 < events.length; i += 2) {
          final id = (events[i] as num?)?.toInt();
          final count = (events[i + 1] as num?)?.toInt() ?? 1;
          if (id == null) continue;
          final name = _idToName[id] ?? 'Widget#$id';
          _counts[name] = (_counts[name] ?? 0) + count;
        }
        return;
      }

      // Fallback: older format {widgets: [{widget, count}]} or {counts: {name: n}}
      final widgets = data['widgets'] as List<dynamic>?;
      if (widgets != null) {
        for (final w in widgets) {
          if (w is! Map) continue;
          final name = w['widget']?.toString() ?? w['name']?.toString() ?? 'Unknown';
          final count = (w['count'] as num?)?.toInt() ?? 1;
          _counts[name] = (_counts[name] ?? 0) + count;
        }
      }
      final fallbackCounts = data['counts'] as Map<String, dynamic>?;
      if (fallbackCounts != null) {
        fallbackCounts.forEach((k, v) {
          _counts[k] = (_counts[k] ?? 0) + ((v as num?)?.toInt() ?? 1);
        });
      }
    });
  }

  // v2.4+ format: {file: {ids:[...], names:[...], lines:[...], columns:[...]}}
  void _parseLocations(dynamic locations) {
    if (locations is! Map) return;
    locations.forEach((file, fileData) {
      if (fileData is! Map) return;
      final ids = fileData['ids'] as List<dynamic>?;
      final names = fileData['names'] as List<dynamic>?;
      if (ids == null || names == null) return;
      for (int i = 0; i < ids.length && i < names.length; i++) {
        final id = (ids[i] as num?)?.toInt();
        final name = names[i] as String?;
        if (id != null && name != null && name.isNotEmpty) {
          _idToName[id] = name;
        }
      }
    });
  }

  // Legacy format: {file: [id, line, col, id, line, col, ...]} — no names
  void _parseLocationsLegacy(dynamic newLocations) {
    if (newLocations is! Map) return;
    newLocations.forEach((file, entries) {
      if (entries is! List) return;
      // Each entry is [id, line, col] — no name in legacy format, use filename
      final shortFile = (file as String).split('/').last.replaceAll('.dart', '');
      for (int i = 0; i + 2 < entries.length; i += 3) {
        final id = (entries[i] as num?)?.toInt();
        if (id != null && !_idToName.containsKey(id)) {
          _idToName[id] = shortFile;
        }
      }
    });
  }

  Future<String> stopAndReport() async {
    await _sub?.cancel();
    _sub = null;

    if (_counts.isEmpty) {
      return 'No rebuild events captured.\n'
          'Requires debug mode + Flutter Inspector active.\n'
          'Try: flutter run (not --profile/--release)';
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
