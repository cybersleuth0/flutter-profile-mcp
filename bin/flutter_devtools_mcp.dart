import 'dart:io';
import 'package:dart_mcp/stdio.dart';
import 'package:flutter_devtools_mcp/server.dart';

void main() async {
  final server = FlutterDevToolsMCPServer(
    channel: stdioChannel(input: stdin, output: stdout),
  );
  stderr.writeln('[flutter_devtools_mcp] ready');
  await server.done;
  exit(0);
}
