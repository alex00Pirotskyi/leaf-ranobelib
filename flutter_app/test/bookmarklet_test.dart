import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaf_reader/core/bookmarklet.dart';

void main() {
  test('self-contained capture preserves newlines and Cyrillic', () {
    const source = '(function(){\n// A comment\nconst title="Книга";\n})();';
    final url = captureBookmarklet(source);
    expect(url, startsWith('javascript:'));
    expect(url.contains('\n'), isFalse);
    expect(Uri.decodeComponent(url.substring(11)), source);
  });
  test('personalized capture keeps JSON and source separate', () {
    final job = jsonEncode(
        {'title': 'Алиса "и" чудеса', 'start': 'https://example.org/1'});
    final script = Uri.decodeComponent(captureBookmarklet(
      '// source comment\nwindow.ready=true;',
      jobJson: job,
    ).substring(11));
    expect(script, contains('window.__leafOfflineJobV2=$job;'));
    expect(script, contains('// source comment\nwindow.ready=true;\n})();'));
  });
}
