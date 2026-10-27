import 'dart:async';
import 'dart:convert';
import 'dart:html' as browser;
import 'dart:typed_data';

import 'epub_builder.dart';
import 'import_parser.dart';

export 'import_parser.dart' show ImportedBook;

/// Reads only files explicitly chosen by the user. No uploads or server storage.
class LocalImporter {
  static Future<List<BookChapter>> chooseChapters() async =>
      (await chooseBook()).chapters;

  /// Cancellation returns an empty book; partial capture metadata is preserved.
  static Future<ImportedBook> chooseBook() async {
    final files = await _chooseFiles();
    if (files.isEmpty) return ImportedBook(chapters: const []);
    if (files.length > ImportParser.maxChapters) {
      throw const FormatException(
          'Choose no more than 500 chapter files at once.');
    }
    var total = 0;
    for (final file in files) {
      if (file.size > ImportParser.maxFileBytes) {
        throw FormatException(
            '${file.name} is larger than the 16 MB file limit.');
      }
      total += file.size;
      if (total > ImportParser.maxTotalBytes) {
        throw const FormatException(
            'Choose at most 64 MB of files per import.');
      }
    }
    final sources = <ImportFile>[];
    for (final file in files) {
      final reader = browser.FileReader();
      final completed = reader.onLoadEnd.first;
      reader.readAsArrayBuffer(file);
      try {
        await completed.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        reader.abort();
        throw FormatException('Reading ${file.name} took too long. Try again.');
      }
      if (reader.error != null)
        throw FormatException('Cannot read ${file.name}.');
      final data = reader.result;
      final bytes = data is ByteBuffer
          ? data.asUint8List()
          : data is Uint8List
              ? data
              : null;
      if (bytes == null) throw FormatException('Cannot read ${file.name}.');
      try {
        sources.add(ImportFile(file.name, utf8.decode(bytes)));
      } on FormatException {
        throw FormatException(
            '${file.name} is not UTF-8 text. Save it as UTF-8 and retry.');
      }
    }
    return ImportParser.parseFiles(sources);
  }

  static Future<List<browser.File>> _chooseFiles() async {
    final input = browser.FileUploadInputElement()
      ..accept = '.txt,.html,.htm,.json'
      ..multiple = true
      ..style.position = 'fixed'
      ..style.left = '-10000px';
    browser.document.body?.append(input);
    final result = Completer<List<browser.File>>();
    final subscriptions = <StreamSubscription>[];
    Timer? focusTimer;
    var leftWindow = false;
    void finish() {
      if (!result.isCompleted)
        result.complete(List.of(input.files ?? const <browser.File>[]));
    }

    void returnedToPage() {
      if (!leftWindow || result.isCompleted) return;
      focusTimer?.cancel();
      // Allow change to arrive before treating restored focus as cancellation.
      focusTimer = Timer(const Duration(milliseconds: 700), finish);
    }

    subscriptions.add(input.onChange.listen((_) => finish()));
    subscriptions.add(input.on['cancel'].listen((_) => finish()));
    subscriptions.add(browser.window.onBlur.listen((_) => leftWindow = true));
    subscriptions.add(browser.window.onFocus.listen((_) => returnedToPage()));
    subscriptions.add(browser.document.onVisibilityChange.listen((_) {
      if (browser.document.hidden == true) {
        leftWindow = true;
      } else {
        returnedToPage();
      }
    }));
    // Bounded fallback for old browsers with neither cancel nor focus events.
    final limit = Timer(const Duration(minutes: 5), finish);
    try {
      input.click();
      return await result.future;
    } finally {
      limit.cancel();
      focusTimer?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      input.remove();
    }
  }

  static String textToHtml(String text) => ImportParser.textToHtml(text);
}
