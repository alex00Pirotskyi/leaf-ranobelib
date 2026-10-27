// Runs the production Dart builder so Node can compile the exact bookmarklet
// users copy, including comments, Cyrillic text, and a personalized job.
import 'dart:convert';
import 'dart:io';

import '../flutter_app/lib/core/bookmarklet.dart';

void main() {
  final source = File.fromUri(Platform.script.resolve(
    '../flutter_app/web/leaf-capture.js')).readAsStringSync();
  final job = jsonEncode({
    'token': 'bookmarklet-regression',
    'title': 'Книга "и" главы — Leaf',
    'start': 'https://reader.example/chapter/one',
    'end': 'https://reader.example/chapter/three',
    'urls': <String>[],
    'max': 120,
    'resumeFrom': 0,
  });
  stdout.write(jsonEncode({
    'generic': captureBookmarklet(source),
    'personalized': captureBookmarklet(source, jobJson: job),
  }));
}
