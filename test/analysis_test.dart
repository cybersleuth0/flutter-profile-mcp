import 'package:flutter_profile_mcp/analysis/cpu_analyzer.dart';
import 'package:flutter_profile_mcp/analysis/jank_analyzer.dart';
import 'package:flutter_profile_mcp/server.dart';
import 'package:test/test.dart';

List<FrameData> frames(int n, {int buildMicros = 4000}) => [
      for (var i = 0; i < n; i++)
        FrameData(
          frameNumber: i + 1,
          uiStartMicros: i * 16667, // 60fps cadence
          uiDurationMicros: buildMicros,
          rasterDurationMicros: 2000,
          totalDurationMicros: 16667,
        ),
    ];

void main() {
  final jank = JankAnalyzer();

  test('too few frames is insufficient, not healthy', () {
    expect(jank.verdict(frames(1)), startsWith('? INSUFFICIENT DATA'));
    expect(jank.verdict([]), startsWith('? INSUFFICIENT DATA'));
  });

  test('smooth frames are healthy', () {
    expect(jank.verdict(frames(60)), startsWith('✓ HEALTHY'));
  });

  test('every frame over budget is severe', () {
    expect(jank.verdict(frames(60, buildMicros: 30000)), startsWith('✗ SEVERE'));
  });

  test('120fps budget flags frames fine at 60fps', () {
    // 10ms build: under 16.6ms budget, over 8.3ms budget
    final f = frames(60, buildMicros: 10000);
    expect(jank.verdict(f, targetFps: 60), startsWith('✓ HEALTHY'));
    expect(jank.verdict(f, targetFps: 120), startsWith('✗ SEVERE'));
  });

  test('codeOrigin splits app, dependency and sdk code', () {
    const app = 'package:demo_app/';
    // package: URIs (class libraries, AOT)
    expect(codeOrigin('package:demo_app/main.dart', app), CodeOrigin.app);
    expect(codeOrigin('package:vector_math/vector_math_64.dart', app), CodeOrigin.dependency);
    expect(codeOrigin('package:flutter/src/widgets/framework.dart', app), CodeOrigin.sdk);
    expect(codeOrigin('dart:core', app), CodeOrigin.sdk);
    // file: paths (JIT CPU samples) — real URLs from a macOS debug run
    expect(codeOrigin('file:///Users/x/proj/demo_app/lib/main.dart', app), CodeOrigin.app);
    expect(codeOrigin('file:///Users/x/.pub-cache/hosted/pub.dev/collection-1.19.1/lib/src/priority_queue.dart', app),
        CodeOrigin.dependency);
    expect(codeOrigin('file:///Users/x/flutter/packages/flutter/lib/src/widgets/framework.dart', app), CodeOrigin.sdk);
    expect(codeOrigin('org-dartlang-sdk:///flutter/third_party/dart/sdk/lib/collection/list.dart', app), CodeOrigin.sdk);
    expect(codeOrigin('/data/app/lib/arm64/libflutter.so+0x1234', app), CodeOrigin.sdk);
  });

  test('credentials are redacted before reaching the AI', () {
    expect(redactHeader('Authorization', ['Bearer abc']), '[redacted]');
    expect(redactHeader('content-type', ['application/json']), ['application/json']);
    final body = redactBody('{"email":"a@b.com","password": "hunter2","idToken":"xyz","spinCount":3,"pin":"1234"}');
    expect(body, isNot(contains('hunter2')));
    expect(body, isNot(contains('xyz')));
    expect(body, isNot(contains('1234')));
    expect(body, contains('a@b.com'));
    expect(body, contains('"spinCount":3'));
    expect(redactBody('user=bob&password=hunter2&access_token=t'), 'user=bob&password=[redacted]&access_token=[redacted]');
  });

  test('jank = slower thread over budget, not build + raster', () {
    // 10ms build + 10ms raster: threads run in parallel, frame is on time
    final f = FrameData(frameNumber: 1, uiStartMicros: 0, uiDurationMicros: 10000,
        rasterDurationMicros: 10000, totalDurationMicros: 16667);
    expect(f.isJanky(), isFalse);
  });

  test('idle gaps between interactions do not lower fps', () {
    // two 30-frame bursts at 60fps, 3s apart
    final f = [
      ...frames(30),
      for (final x in frames(30))
        FrameData(frameNumber: x.frameNumber + 30, uiStartMicros: x.uiStartMicros + 3500000,
            uiDurationMicros: x.uiDurationMicros, rasterDurationMicros: x.rasterDurationMicros,
            totalDurationMicros: x.totalDurationMicros),
    ];
    expect(jank.fps(f)!, closeTo(60, 1));
    expect(jank.verdict(f), startsWith('✓ HEALTHY'));
  });
}
