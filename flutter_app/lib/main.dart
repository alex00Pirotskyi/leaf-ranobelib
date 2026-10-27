// Leaf: Flutter Web + Dart EPUB. Public API directly, other sites via user bookmarklet.
import 'dart:async';
import 'dart:convert';
import 'dart:html' as browser;
import 'dart:math';
import 'dart:js_util' as js_util;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'core/chapter_url_plan.dart';
import 'core/epub_builder.dart';
import 'core/local_importer.dart';
import 'core/open_reader.dart';
import 'core/book_catalogue.dart';
import 'core/book_manifest.dart';
import 'core/bookmarklet.dart';
import 'core/session_store.dart';

const paper = Color(0xFFF8F7F2), ink = Color(0xFF28382F);
const pine = Color(0xFF3C5F4A), muted = Color(0xFF78817A);
const line = Color(0xFFE3E7DF);
const demoStart =
    'https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_1';
const demoEnd =
    'https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_3';
const bookmarklet = 'javascript:(function(){'
    'if(window.__leafCaptureV2){window.__leafCaptureV2.resume();return;}'
    'var s=document.createElement("script");'
    's.src="https://alex00pirotskyi.github.io/leaf-ranobelib/leaf-capture.js";'
    '(document.head||document.documentElement).appendChild(s);'
    '})()';

void main() {
  ui_web.platformViewRegistry.registerViewFactory('leaf-bookmarklet', (int id) {
    final a = browser.AnchorElement(href: bookmarklet)
      ..text = 'Drag Leaf Capture to bookmarks bar ↗'
      ..title = 'Drag this link into the bookmarks bar, once.'
      ..style.cssText =
          'display:flex;align-items:center;justify-content:center;'
              'width:100%;height:42px;box-sizing:border-box;'
              'border:1px dashed #799181;border-radius:10px;'
              'background:#f4faf2;color:#3C5F4A;text-decoration:none;'
              'font:bold 12px Arial,sans-serif;cursor:grab';
    a.onClick.listen((event) => event.preventDefault());
    return a;
  });
  runApp(const LeafApp());
}

class LeafApp extends StatelessWidget {
  const LeafApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'leaf. — Read anywhere',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: paper,
          colorScheme: ColorScheme.fromSeed(seedColor: pine, surface: paper),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
            enabledBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: line),
              borderRadius: BorderRadius.circular(11),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: pine, width: 1.6),
              borderRadius: BorderRadius.circular(11),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(11)),
          ),
        ),
        home: const LeafHome(),
      );
}

enum Mode { library, links, files }

class LeafHome extends StatefulWidget {
  const LeafHome({super.key});
  @override
  State<LeafHome> createState() => _LeafHomeState();
}

class _LeafHomeState extends State<LeafHome> {
  final _first = TextEditingController(text: demoStart);
  final _last = TextEditingController(text: demoEnd);
  final _title = TextEditingController(text: 'Pride and Prejudice');
  final _author = TextEditingController(text: 'Jane Austen');
  final _reader = OpenReader();
  final _catalogue = BookCatalogue();
  final _discovery = BookDiscovery();
  final _store = SessionStore();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Mode _mode = Mode.library;
  List<CatalogueBook> _books = List.of(BookCatalogue.featured);
  List<CatalogueSourceFailure> _searchFailures = [];
  String _filter = 'all', _language = 'en';
  String _jobId = '';
  bool _searching = false, _searched = false;
  int _searchRun = 0, _run = 0;
  List<Uri> _directUrls = [], _receivedUrls = [];
  String? _storageWarning, _manifestNote;
  bool _restoring = true, _restored = false;
  bool _partial = false, _selectionComplete = false;
  bool _importedComplete = true;
  int? _importedExpected;
  Map<String, dynamic>? _savedJob;
  bool _busy = false, _cancelled = false, _awaitingHelper = false;
  bool _bookReady = false;
  String _status = 'Choose a book to prepare an EPUB on your device.';
  String? _error;
  ChapterUrlPlan? _plan;
  String? _token, _sourceOrigin;
  browser.WindowBase? _readerWindow;
  StreamSubscription<browser.MessageEvent>? _messages;
  Uint8List? _epub;
  List<BookChapter> _chapters = [], _imported = [];
  int _done = 0, _total = 0;
  bool _mobilePrepared = false;
  String? _cachedCaptureSource;
  bool get _isIPhoneSafari =>
      RegExp(r'iPhone|iPad|iPod')
          .hasMatch(browser.window.navigator.userAgent) ||
      (browser.window.navigator.userAgent.contains('Macintosh') &&
          (browser.window.navigator.maxTouchPoints ?? 0) > 1);
  bool get _isPhone =>
      _isIPhoneSafari || browser.window.navigator.userAgent.contains('Android');
  bool get _mobileNeedsCapture {
    final uri = Uri.tryParse(_first.text.trim());
    return _isPhone && (uri == null || !OpenReader.supports(uri));
  }

  @override
  void initState() {
    super.initState();
    _jobId = _createToken();
    _messages = browser.window.onMessage.listen(_message);
    unawaited(_loadCaptureSource());
    unawaited(_loadCheckpoint());
  }

  @override
  void dispose() {
    _messages?.cancel();
    _reader.close();
    _catalogue.close();
    _discovery.close();
    _search.dispose();
    _scroll.dispose();
    _first.dispose();
    _last.dispose();
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  Future<void> _searchBooks() async {
    final query = _search.text.trim();
    final uri = Uri.tryParse(query);
    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      if (OpenReader.supports(uri)) {
        await _prepareBook(uri);
      } else {
        setState(() {
          _mode = Mode.links;
          _first.text = query;
          _last.clear();
          _error = 'This website needs its own capture flow. Add the final '
              'chapter link below, or import chapter files. Completing a '
              'CAPTCHA alone cannot give Leaf access to another website.';
        });
      }
      return;
    }
    final request = ++_searchRun;
    if (query.isEmpty) {
      setState(() {
        _books = List.of(BookCatalogue.featured);
        _searchFailures = [];
        _searched = false;
        _searching = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchFailures = [];
      _error = null;
    });
    try {
      final result = await _catalogue.search(query, language: _filter);
      if (!mounted || request != _searchRun) return;
      setState(() {
        _books = result.books;
        _searchFailures = result.failures;
        _searched = true;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || request != _searchRun) return;
      setState(() {
        _searching = false;
        _error = _errorText(error);
      });
    }
  }

  void _chooseBook(CatalogueBook book) {
    if (_busy || _restoring) return;
    if (book.kind == CatalogueBookKind.directEpub && book.epubUrl != null) {
      // Native navigation needs no CORS and keeps the trusted click gesture.
      final a = browser.AnchorElement(href: book.epubUrl.toString())
        ..target = '_blank'
        ..rel = 'noopener noreferrer';
      browser.document.body?.append(a);
      a.click();
      a.remove();
      setState(() {
        _error = null;
        _status =
            'Opened ${book.sourceName}’s EPUB download for ${book.title}. '
            'Your browser handles saving the file.';
      });
      return;
    }
    unawaited(_prepareBook(book.pageUrl, selected: book));
  }

  Future<void> _prepareBook(Uri url, {CatalogueBook? selected}) async {
    if (_busy || _restoring) return;
    _detachCapture();
    final request = ++_run;
    _jobId = _createToken();
    ++_searchRun;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _searching = false;
      _epub = null;
      _bookReady = false;
      _restored = false;
      _partial = false;
      _selectionComplete = false;
      _savedJob = null;
      _chapters = [];
      _receivedUrls = [];
      _directUrls = [];
      _done = 0;
      _total = 0;
      _awaitingHelper = false;
      _title.text = selected?.title ?? 'Book';
      _author.text = selected?.author ?? '';
      _manifestNote = null;
      _status = 'Finding the book’s table of contents…';
    });
    _showProgress();
    try {
      final manifest = await _discovery.discover(url);
      if (!mounted || request != _run) return;
      setState(() {
        _title.text = selected?.title ?? manifest.title;
        _author.text = manifest.author.isNotEmpty
            ? manifest.author
            : selected?.author ?? '';
        _language = manifest.language;
        _directUrls = manifest.chapters;
        _first.text = _directUrls.first.toString();
        _last.text = _directUrls.last.toString();
        _total = _directUrls.length;
        _manifestNote = manifest.note;
        _status = 'Found $_total reading sections. Downloading…';
      });
      await _saveCheckpoint();
      if (request == _run) await _readDirect(request);
    } catch (error) {
      if (!mounted || request != _run) return;
      setState(() {
        _busy = false;
        _error = _errorText(error);
        _status = 'Choose a specific edition or use chapter links below.';
      });
    }
  }

  void _showProgress() {
    if (_scroll.hasClients) {
      unawaited(_scroll.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
    }
  }

  Map<String, dynamic> _checkpoint() => {
        'version': 3,
        'jobId': _jobId,
        'title': _title.text,
        'author': _author.text,
        'language': _language,
        'first': _first.text,
        'last': _last.text,
        'urls': _directUrls.map((u) => u.toString()).toList(),
        'receivedUrls': _receivedUrls.map((u) => u.toString()).toList(),
        'chapters':
            _chapters.map((c) => {'title': c.title, 'html': c.html}).toList(),
        'total': _total,
        'complete': _selectionComplete,
        'note': _manifestNote,
        'saved': DateTime.now().toUtc().toIso8601String(),
      };

  Future<void> _saveCheckpoint() async {
    try {
      await _store.save(_checkpoint());
    } catch (_) {
      if (mounted && _storageWarning == null)
        setState(() {
          _storageWarning = 'This browser could not save progress. Keep this '
              'tab open and download your EPUB before leaving.';
        });
    }
  }

  Future<void> _loadCheckpoint() async {
    try {
      final saved = await _store.read();
      if (!mounted) return;
      if (saved != null &&
          saved['chapters'] is List &&
          (saved['chapters'] as List).isNotEmpty) {
        setState(() => _savedJob = saved);
      }
    } catch (_) {
      // Reading is still available when private browsing disables storage.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _restoreSaved() {
    if (_savedJob == null || _busy) return;
    final saved = _savedJob!;
    try {
      final chapters = (saved['chapters'] as List)
          .map((c) => BookChapter(c['title'] as String, c['html'] as String))
          .toList();
      final urls =
          (saved['urls'] as List).map((s) => Uri.parse(s as String)).toList();
      if (urls.any((u) => !OpenReader.supports(u)) ||
          chapters.length > 500 ||
          (urls.isNotEmpty && chapters.length > urls.length)) {
        throw const FormatException('This saved job cannot be resumed.');
      }
      ++_run;
      setState(() {
        _jobId = (saved['jobId'] ?? _createToken()).toString();
        _title.text = saved['title'] as String;
        _author.text = (saved['author'] ?? '').toString();
        _language = (saved['language'] ?? 'en').toString();
        _first.text = (saved['first'] ?? '').toString();
        _last.text = (saved['last'] ?? '').toString();
        _directUrls = urls;
        _chapters = chapters;
        _receivedUrls = ((saved['receivedUrls'] ?? []) as List)
            .map((s) => Uri.parse(s as String))
            .toList();
        _done = chapters.length;
        _total = saved['total'] as int;
        _selectionComplete = saved['complete'] == true ||
            (urls.isNotEmpty && chapters.length == urls.length);
        _manifestNote = saved['note'] as String?;
        _restored = true;
        _epub = null;
        _bookReady = false;
        _partial = false;
        _error = null;
        _savedJob = null;
        _status =
            'Restored $_done of $_total reading sections from this device.';
        if (urls.isEmpty && !_selectionComplete) {
          _status =
              'Recovered $_done captured sections. You can save a partial '
              'EPUB. The source-tab connection cannot be restored after a reload.';
        }
      });
      if (urls.isNotEmpty) {
        _resumeDirect();
      } else if (saved['complete'] == true) {
        unawaited(_createEpub());
      }
    } catch (error) {
      setState(() {
        _savedJob = null;
        _error = _errorText(error);
      });
    }
  }

  void _resumeDirect() {
    if (_busy || _directUrls.isEmpty) return;
    final request = ++_run;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _restored = false;
      _bookReady = false;
      _partial = false;
      _status = 'Continuing from section ${_chapters.length + 1}…';
    });
    unawaited(_readDirect(request));
  }

  Future<void> _readDirect(int request) async {
    final urls = List<Uri>.of(_directUrls);
    try {
      for (var i = _chapters.length; i < urls.length; i++) {
        if (request != _run || !mounted) return;
        final chapter = await _reader.read(urls[i]);
        if (request != _run || !mounted) return;
        _chapters.add(chapter);
        _receivedUrls.add(urls[i]);
        setState(() {
          _done = _chapters.length;
          _status = 'Downloaded $_done / $_total reading sections';
        });
        await _saveCheckpoint();
        if (i + 1 < urls.length) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      if (request == _run) {
        _selectionComplete = true;
        await _createEpub(request: request);
      }
    } catch (error) {
      if (!mounted || request != _run) return;
      setState(() {
        _busy = false;
        _error = _errorText(error);
        _status =
            'Paused at $_done / $_total. Continue retries the next section.';
      });
      await _saveCheckpoint();
    }
  }

  String _createToken() {
    final rng = Random.secure();
    return List.generate(
        24, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  void _message(browser.MessageEvent event) {
    final plan = _plan;
    if (!_awaitingHelper || plan == null || _token == null) return;
    // Send the job only to the window Leaf opened, with exact target origin.
    // Cross-origin WindowBase wrappers are not reliably identity-equal in Dart.
    // All subsequent chapter payloads must also present the session token.
    if (event.origin != _sourceOrigin || _readerWindow == null) return;
    if (event.data is! String) return;
    late final Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(event.data as String) as Map);
    } catch (_) {
      return;
    }
    if (data['leaf'] != 2) return;
    if (data['type'] == 'hello') {
      if (data['token'] != _token) return;
      final pageUrl = (data['pageUrl'] ?? '').toString();
      final proposed = Uri.tryParse(pageUrl);
      final resumeUrl = !plan.inferred &&
              proposed != null &&
              proposed.origin == plan.start.origin
          ? proposed.toString()
          : plan.start.toString();
      final config = {
        'leaf': 2,
        'type': 'job',
        'token': _token,
        'start': resumeUrl,
        'end': plan.end.toString(),
        'urls': plan.urls.map((u) => u.toString()).toList(),
        'max': plan.inferred ? plan.urls.length : ChapterUrlPlan.maxChapters,
        'title': _title.text,
        'resumeFrom': _chapters.length,
      };
      try {
        _readerWindow?.postMessage(jsonEncode(config), plan.start.origin);
        if (mounted)
          setState(() {
            _busy = true;
            _bookReady = false;
            _epub = null;
            _status = 'Capture connected. Reading chapters…';
          });
      } catch (_) {
        if (mounted)
          setState(() => _error =
              'The website disconnected the tab (COOP). Use manual JSON export and import.');
      }
      return;
    }
    if (data['token'] != _token) return;
    switch (data['type']) {
      case 'status':
        if (mounted) setState(() => _status = (data['note'] ?? '').toString());
      case 'chapter':
        final i = data['index'];
        final url = Uri.tryParse((data['url'] ?? '').toString());
        final title = (data['title'] ?? '').toString();
        final html = (data['html'] ?? '').toString();
        if (i is! int ||
            i != _chapters.length ||
            url == null ||
            !plan.contains(url) ||
            title.length > 300 ||
            html.length < 15 ||
            html.length > 650000) return;
        if (plan.inferred && (i >= plan.urls.length || plan.urls[i] != url))
          return;
        if (_receivedUrls.contains(url.removeFragment())) return;
        _chapters.add(BookChapter(
            title.isEmpty ? 'Chapter ' + (i + 1).toString() : title, html));
        _receivedUrls.add(url.removeFragment());
        if (mounted)
          setState(() {
            _epub = null;
            _bookReady = false;
            _done = _chapters.length;
            _status = 'Received ' + _done.toString() + ' chapters…';
          });
        unawaited(_saveCheckpoint());
      case 'halt':
        if (mounted)
          setState(() {
            _busy = false;
            _status = 'Paused after ' + _done.toString() + ' chapters.';
            _error = (data['note'] ?? 'The reader stopped.').toString();
          });
      case 'done':
        if (_chapters.isEmpty) return;
        if ((plan.inferred && _chapters.length != plan.urls.length) ||
            _receivedUrls.isEmpty ||
            _receivedUrls.last != plan.end) {
          if (mounted)
            setState(() {
              _busy = false;
              _error = 'The selected ending chapter has not been received. '
                  'Continue capture, or save a clearly marked partial EPUB.';
            });
          return;
        }
        _awaitingHelper = false;
        _busy = false;
        _selectionComplete = true;
        _total = _done;
        unawaited(_createEpub());
    }
  }

  void _start() {
    if (_busy || _restoring) return;
    if (_last.text.trim().isEmpty) {
      final url = Uri.tryParse(_first.text.trim());
      if (url != null && OpenReader.supports(url)) {
        unawaited(_prepareBook(url));
      } else {
        setState(() => _error = 'Enter the final chapter URL for this source. '
            'For a whole Wikisource book, paste its edition URL above.');
      }
      return;
    }
    late final ChapterUrlPlan plan;
    try {
      plan = ChapterUrlPlan.parse(_first.text, _last.text);
    } catch (e) {
      setState(() => _error = _errorText(e));
      return;
    }
    final request = ++_run;
    _detachCapture();
    _jobId = _createToken();
    _directUrls = [];
    _receivedUrls = [];
    _selectionComplete = false;
    _partial = false;
    _savedJob = null;
    _restored = false;
    _manifestNote = plan.inferred
        ? 'Selected URL range. This is not a verified whole-book contents list.'
        : 'Following source Next links until your exact final chapter.';
    _language = plan.start.host.startsWith('ru.')
        ? 'ru'
        : RegExp(r'[А-Яа-яЁё]').hasMatch(_title.text)
            ? 'ru'
            : 'en';
    if (_mobileNeedsCapture && !(plan.isWikimedia && plan.inferred)) {
      if (!_isIPhoneSafari) {
        setState(() {
          _mode = Mode.files;
          _busy = false;
          _awaitingHelper = false;
          _status = 'Use Import files for this website on Android. '
              'The built-in book library downloads directly on this phone.';
          _error = 'This source cannot be captured automatically in this phone '
              'browser. Save available chapter files on the source, then import '
              'them here. Library books work directly.';
        });
        return;
      }
      setState(() {
        _plan = plan;
        _epub = null;
        _bookReady = false;
        _chapters = [];
        _done = 0;
        _total = 0;
        _busy = false;
        _awaitingHelper = false;
        _mobilePrepared = false;
        _error = null;
        if (_title.text == 'Pride and Prejudice') {
          _title.text = 'Collected RanobeLIB chapters';
          _author.clear();
        }
        _status = 'iPhone Safari cannot read another website from Leaf. '
            'Prepare your personalized Safari Capture bookmark below, then '
            'open the first chapter and activate it there. Import the saved '
            'JSON into Leaf to make an EPUB.';
      });
      if (_cachedCaptureSource != null) unawaited(_prepareSafariCapture());
      return;
    }
    setState(() {
      _plan = plan;
      _epub = null;
      _bookReady = false;
      _chapters = [];
      _done = 0;
      _total = plan.inferred ? plan.urls.length : ChapterUrlPlan.maxChapters;
      _error = null;
      _cancelled = false;
      _busy = true;
      _awaitingHelper = false;
      _status = plan.description;
    });
    if (plan.isWikimedia && plan.inferred) {
      _directUrls = List.of(plan.urls);
      unawaited(_readDirect(request));
      return;
    }
    // Open synchronously in the user's click gesture, before any await.
    _token = _createToken();
    _sourceOrigin = plan.start.origin;
    _readerWindow = browser.window.open(
        plan.start.replace(fragment: 'leaf_session=$_token').toString(),
        'leaf-chapter-source');
    if (_readerWindow == null) {
      setState(() {
        _busy = false;
        _error =
            'Browser blocked the chapter tab. Allow pop-ups and try again.';
      });
      return;
    }
    setState(() {
      _awaitingHelper = true;
      _status = 'Reader tab opened. Solve any login or CAPTCHA yourself, '
          'then click your Leaf Capture bookmark inside that tab.';
    });
  }

  Future<void> _createEpub({int? request, bool partial = false}) async {
    if (_chapters.isEmpty) {
      if (mounted) setState(() => _error = 'Nothing to convert yet.');
      return;
    }
    _pauseCapture();
    partial = partial || !_selectionComplete;
    final generation = request ?? ++_run;
    final title = _title.text.isEmpty ? 'Collected chapters' : _title.text;
    final author = _author.text;
    final chapters = List<BookChapter>.of(_chapters);
    try {
      if (mounted)
        setState(() {
          _busy = true;
          _bookReady = false;
          _epub = null;
          _partial = partial;
          _status = 'Preparing your EPUB…';
        });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (!mounted || generation != _run) return;
      final bytes = EpubBuilder.build(
          title:
              partial ? '$title (partial: ${chapters.length} sections)' : title,
          author: author,
          chapters: chapters,
          language: _language);
      _epub = bytes;
      if (mounted)
        setState(() {
          _busy = false;
          _bookReady = true;
          _awaitingHelper = false;
          _status = '${partial ? 'Partial EPUB' : 'EPUB'} ready: '
              '${chapters.length} reading ${chapters.length == 1 ? 'section' : 'sections'} '
              '(${(bytes.length / 1024).round()} KB). '
              '${_isPhone ? 'Tap Save EPUB to keep it or open it in your reader.' : 'Your download is ready.'}';
        });
      await _saveCheckpoint();
      if (partial && _plan != null && _token != null && generation == _run) {
        _awaitingHelper = true;
      }
      if (!_isPhone && generation == _run) _download();
    } catch (e) {
      if (mounted && generation == _run)
        setState(() {
          _busy = false;
          _error = _errorText(e);
        });
    }
  }

  String get _epubFilename => EpubBuilder.safeFilename(
      _partial ? '${_title.text} — partial $_done of $_total' : _title.text);

  browser.File? _shareableFile() {
    if (_epub == null) return null;
    return browser.File(
        [_epub!], _epubFilename, {'type': 'application/epub+zip'});
  }

  bool get _canShare {
    try {
      final file = _shareableFile();
      return file != null &&
          js_util.hasProperty(browser.window.navigator, 'canShare') &&
          js_util.callMethod<bool>(browser.window.navigator, 'canShare', [
            js_util.jsify({
              'files': [file]
            })
          ]);
    } catch (_) {
      return false;
    }
  }

  void _share() {
    final file = _shareableFile();
    if (file == null || !_canShare) {
      _download();
      return;
    }
    // The promise is created synchronously inside the actual user tap.
    final promise =
        js_util.callMethod<Object>(browser.window.navigator, 'share', [
      js_util.jsify({
        'files': [file],
        'title': _title.text
      })
    ]);
    unawaited(js_util.promiseToFuture<void>(promise).catchError((Object error) {
      if (mounted && !error.toString().contains('AbortError'))
        setState(() {
          _error = 'Sharing is unavailable here. Use Save EPUB instead.';
        });
    }));
  }

  void _download() {
    if (_epub == null) return;
    final blob = browser.Blob([_epub!], 'application/epub+zip');
    final url = browser.Url.createObjectUrlFromBlob(blob);
    final link = browser.AnchorElement(href: url)
      ..download = _epubFilename
      ..style.display = 'none';
    browser.document.body?.append(link);
    link.click();
    link.remove();
    Future<void>.delayed(
        const Duration(seconds: 10), () => browser.Url.revokeObjectUrl(url));
  }

  Future<void> _import() async {
    if (_busy) return;
    final request = _run;
    try {
      final result = await LocalImporter.chooseBook();
      if (!mounted || request != _run || _busy || result.chapters.isEmpty)
        return;
      ++_run;
      _detachCapture();
      if (mounted)
        setState(() {
          _epub = null;
          _bookReady = false;
          _chapters = [];
          _directUrls = [];
          _receivedUrls = [];
          _done = 0;
          _total = 0;
          _selectionComplete = false;
          _imported = List.of(result.chapters);
          _importedComplete = result.complete;
          _importedExpected = result.expectedChapters;
          if (result.title != null) _title.text = result.title!;
          if (result.author != null) _author.text = result.author!;
          _language = result.language ??
              (RegExp(r'[А-Яа-яЁё]').hasMatch(result.chapters.first.html)
                  ? 'ru'
                  : 'en');
          _status =
              'Imported ${result.chapters.length} sections${result.complete ? '.' : ' from a partial capture. The EPUB will be marked partial.'}';
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    }
  }

  void _convertImported() {
    if (_imported.isEmpty) {
      setState(() => _error = 'Please import chapter files first.');
      return;
    }
    _detachCapture();
    _jobId = _createToken();
    _chapters = List.of(_imported);
    _directUrls = [];
    _receivedUrls = [];
    _selectionComplete = false;
    _partial = false;
    _selectionComplete = _importedComplete;
    _done = _chapters.length;
    _total = _importedExpected ?? _done;
    _savedJob = null;
    unawaited(_createEpub(partial: !_importedComplete));
  }

  void _pauseCapture() {
    _awaitingHelper = false;
    if (_token != null && _sourceOrigin != null) {
      try {
        _readerWindow?.postMessage(
            jsonEncode({
              'leaf': 2,
              'type': 'stop',
              'token': _token,
            }),
            _sourceOrigin!);
      } catch (_) {}
    }
  }

  void _detachCapture() {
    _pauseCapture();
    _token = null;
    _sourceOrigin = null;
    _readerWindow = null;
    _plan = null;
  }

  void _stop() {
    ++_run;
    _cancelled = true;
    _busy = false;
    if (_token != null && _sourceOrigin != null) {
      try {
        _readerWindow?.postMessage(
            jsonEncode({'leaf': 2, 'type': 'stop', 'token': _token}),
            _sourceOrigin!);
      } catch (_) {}
    }
    setState(() => _status = 'Paused at $_done / $_total. '
        '${_directUrls.isNotEmpty ? 'Continue when you are ready.' : 'Run Leaf Capture in the source tab to continue.'}');
    unawaited(_saveCheckpoint());
  }

  String _errorText(Object e) => e is FormatException
      ? e.message
      : e.toString().replaceFirst('Exception: ', '');

  void _demo() {
    if (_busy) return;
    setState(() {
      _first.text = demoStart;
      _last.text = demoEnd;
      _title.text = 'Pride and Prejudice';
      _author.text = 'Jane Austen';
      _error = null;
      _status = 'Three chapters: public-domain Wikimedia direct API demo.';
    });
  }

  Future<void> _copyCapturePlan() async {
    try {
      final plan = ChapterUrlPlan.parse(_first.text, _last.text);
      if (plan.isWikimedia && plan.inferred) {
        throw const FormatException(
          'Open Wikisource and Wikibooks chapters directly with Collect & download EPUB.',
        );
      }
      final data = jsonEncode({
        'leaf': 2,
        'type': 'job',
        'token': _createToken(),
        'start': plan.start.toString(),
        'end': plan.end.toString(),
        'urls': plan.urls.map((u) => u.toString()).toList(),
        'max': plan.inferred ? plan.urls.length : ChapterUrlPlan.maxChapters,
        'title': _title.text,
        'resumeFrom': 0,
        'manualMode': true,
      });
      await Clipboard.setData(ClipboardData(text: data));
      if (mounted)
        setState(() {
          _error = null;
          _status = 'Capture plan copied. In the source tab click your '
              'Leaf Capture bookmark, paste the plan into its panel, and '
              'click Start using pasted plan. It will export a JSON file '
              'for Leaf → Import files → Create EPUB.';
        });
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    }
  }

  Future<void> _copySelfContainedCapture() async {
    try {
      final response = await http
          .get(Uri.base.resolve('leaf-capture.js'))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw FormatException('Cannot load the in-page helper (HTTP ' +
            response.statusCode.toString() +
            ').');
      }
      final source = utf8.decode(response.bodyBytes);
      if (!source.contains('leafCaptureV2') || source.length > 85000) {
        throw const FormatException('Unexpected bookmarklet source.');
      }
      // The full source runs in the reader tab itself: no additional script
      // request to GitHub Pages is needed after installation.
      final javascript = captureBookmarklet(source);
      await Clipboard.setData(ClipboardData(text: javascript));
      if (mounted)
        setState(() {
          _status = 'Full self-contained bookmarklet copied. Create a new '
              'bookmark and paste this in its URL field. Use this version '
              'when a website blocks loading external scripts.';
        });
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    }
  }

  Future<void> _loadCaptureSource() async {
    try {
      final response = await http
          .get(Uri.base.resolve('leaf-capture.js'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return;
      final source = utf8.decode(response.bodyBytes);
      if (!source.contains('leafCaptureV2') || source.length > 90000) return;
      if (mounted) setState(() => _cachedCaptureSource = source);
    } catch (_) {
      // The public-domain direct EPUB route still works without a bookmarklet.
    }
  }

  Future<void> _prepareSafariCapture() async {
    late final ChapterUrlPlan plan;
    try {
      plan = ChapterUrlPlan.parse(_first.text, _last.text);
      if (plan.isWikimedia && plan.inferred) {
        throw const FormatException(
            'For Wikisource, just press Collect & download EPUB.');
      }
      if (mounted)
        setState(() {
          _status = 'Preparing your Safari chapter collector…';
          _error = null;
        });
      final source = _cachedCaptureSource;
      if (source == null) {
        throw const FormatException('Safari helper is still loading. '
            'Reload Leaf and tap Copy personalized Safari helper again.');
      }
      final job = jsonEncode({
        'token': _createToken(),
        'start': plan.start.toString(),
        'end': plan.end.toString(),
        'urls': plan.urls.map((url) => url.toString()).toList(),
        'max': plan.inferred ? plan.urls.length : ChapterUrlPlan.maxChapters,
        'title': _title.text,
        'resumeFrom': 0,
      });
      // Self-contained bookmarklet; works without a popup/opener connection.
      // Source sites may nevertheless block bookmarklets or automation.
      final javascript = captureBookmarklet(source, jobJson: job);
      await Clipboard.setData(ClipboardData(text: javascript));
      if (mounted)
        setState(() {
          _plan = plan;
          _mobilePrepared = true;
          _status = 'Personalized collector copied. Create or edit a Safari '
              'bookmark named Leaf Capture; paste the code in its URL field. '
              'Open the first chapter and tap that bookmark. Exported chapters '
              'will be saved as JSON, ready for Leaf Import files.';
          _error = null;
        });
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  void _openMobileChapter() {
    try {
      final plan = ChapterUrlPlan.parse(_first.text, _last.text);
      browser.window.open(plan.start.toString(), '_blank');
      setState(() => _status =
          'Opened the first chapter in Safari. Solve any login or CAPTCHA '
              'yourself. From Bookmarks, tap Leaf Capture. After it saves JSON, '
              'return to Leaf → Import files → Create EPUB.');
    } catch (error) {
      setState(() => _error = _errorText(error));
    }
  }

  void _sampleCapture() {
    if (_busy) return;
    setState(() {
      _first.text =
          'https://alex00pirotskyi.github.io/leaf-ranobelib/fixtures/chapter-1.html';
      _last.text =
          'https://alex00pirotskyi.github.io/leaf-ranobelib/fixtures/chapter-3.html';
      _title.text = 'Leaf Sample Archive';
      _author.text = 'Leaf Open Demo';
      _error = null;
      _status = 'Browser-assisted test: three original chapters on Leaf. '
          'Press Collect, then activate Leaf Capture in the opened tab.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 740;
    return Scaffold(
        body: SafeArea(
            child: SingleChildScrollView(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(compact ? 16 : 35, 0, compact ? 16 : 35, 50),
      child: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(),
          SizedBox(height: compact ? 25 : 38),
          const Text('A LITTLE LIBRARY. A WORLD OF STORIES.',
              style: TextStyle(
                  color: pine,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.3)),
          const SizedBox(height: 10),
          Text('Find a book. Take it with you.',
              style: TextStyle(
                  fontFamily: 'Georgia',
                  color: ink,
                  fontSize: compact ? 35 : 49,
                  height: 1.13,
                  letterSpacing: -1.3)),
          const SizedBox(height: 12),
          const Text(
              'Russian and English books, ready for your reader. '
              'Choose a title and Leaf takes care of the chapters.',
              style: TextStyle(color: muted, fontSize: 14, height: 1.55)),
          const SizedBox(height: 22),
          Wrap(spacing: 9, runSpacing: 6, children: [
            ChoiceChip(
                label: const Text('Find a book'),
                selected: _mode == Mode.library,
                onSelected:
                    _busy ? null : (_) => setState(() => _mode = Mode.library)),
            ChoiceChip(
                label: const Text('Chapter links'),
                selected: _mode == Mode.links,
                onSelected:
                    _busy ? null : (_) => setState(() => _mode = Mode.links)),
            ChoiceChip(
                label: const Text('Import files'),
                selected: _mode == Mode.files,
                onSelected:
                    _busy ? null : (_) => setState(() => _mode = Mode.files)),
          ]),
          const SizedBox(height: 18),
          if (_savedJob != null && !_busy && _done == 0) ...[
            _surface(
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your book is still here',
                  style: const TextStyle(
                      color: ink, fontSize: 19, fontFamily: 'Georgia')),
              const SizedBox(height: 8),
              Text(
                  '${_savedJob!['title']} · ${(_savedJob!['chapters'] as List).length}'
                  ' saved sections',
                  style: const TextStyle(color: muted, fontSize: 13)),
              const SizedBox(height: 12),
              _button(
                  (_savedJob!['urls'] as List).isNotEmpty
                      ? 'Continue saved book'
                      : _savedJob!['complete'] == true
                          ? 'Rebuild saved EPUB'
                          : 'Recover saved chapters',
                  Icons.play_arrow_rounded,
                  _restoreSaved),
            ])),
            const SizedBox(height: 16),
          ],
          if (_busy || _done > 0 || _bookReady) ...[
            _progressPanel(),
            const SizedBox(height: 16),
          ],
          if (_error != null) ...[
            _statusBox(_error!, true),
            const SizedBox(height: 16),
          ],
          if (_storageWarning != null) ...[
            _statusBox(_storageWarning!, true),
            const SizedBox(height: 16),
          ],
          switch (_mode) {
            Mode.library => _libraryPanel(),
            Mode.links => _linksPanel(),
            Mode.files => _filePanel(),
          },
          if (_mode == Mode.links) ...[
            const SizedBox(height: 18),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Capture help for other websites',
                    style: TextStyle(color: pine, fontSize: 14)),
                initiallyExpanded: _mobilePrepared || _awaitingHelper,
                children: [_helperPanel()]),
          ],
          const SizedBox(height: 17),
          if (!_busy && !_bookReady) _statusBox(_status, false),
          const SizedBox(height: 30),
          const Divider(color: line),
          const SizedBox(height: 14),
          const Text('leaf. · Made on your device · Source licences apply',
              style: TextStyle(fontSize: 11, color: muted)),
        ]),
      )),
    )));
  }

  Widget _libraryPanel() {
    final visible =
        _books.where((b) => _filter == 'all' || b.language == _filter).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading('01', 'What would you like to read?'),
        const SizedBox(height: 17),
        Row(children: [
          Expanded(
              child: TextField(
                  key: const ValueKey('book-search'),
                  controller: _search,
                  enabled: !_busy,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_searchBooks()),
                  style: const TextStyle(color: ink, fontSize: 14),
                  decoration: const InputDecoration(
                      hintText: 'Book title, author or Wikisource URL',
                      labelText: 'Search books / Найти книгу',
                      prefixIcon: Icon(Icons.search_rounded, size: 21)))),
          const SizedBox(width: 8),
          IconButton.filled(
              tooltip: 'Search books',
              onPressed:
                  _busy || _searching ? null : () => unawaited(_searchBooks()),
              style: IconButton.styleFrom(
                  backgroundColor: ink, minimumSize: const Size(49, 52)),
              icon:
                  const Icon(Icons.arrow_forward_rounded, color: Colors.white)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final value in const ['all', 'ru', 'en'])
            ChoiceChip(
                label: Text(switch (value) {
                  'ru' => 'Русский',
                  'en' => 'English',
                  _ => 'All books'
                }),
                selected: _filter == value,
                onSelected: _busy
                    ? null
                    : (_) {
                        setState(() => _filter = value);
                        if (_search.text.trim().isNotEmpty)
                          unawaited(_searchBooks());
                      }),
        ]),
        const SizedBox(height: 10),
        const Text(
            'Built-in search: Викитека + Wikisource. '
            'More libraries are listed below.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.5)),
      ])),
      const SizedBox(height: 22),
      Row(children: [
        Expanded(
            child: Text(
                _searched ? 'Search results' : 'Start with a good story',
                style: const TextStyle(
                    color: ink, fontSize: 22, fontFamily: 'Georgia'))),
        if (_searching)
          const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: pine)),
      ]),
      const SizedBox(height: 7),
      Text(
          _searched
              ? 'Choose an edition. Tap a book to prepare its EPUB.'
              : 'A few complete editions to try. Tap a book to get its EPUB.',
          style: const TextStyle(color: muted, fontSize: 12, height: 1.5)),
      const SizedBox(height: 13),
      for (final failure in _searchFailures) ...[
        _statusBox('${failure.sourceName}: ${failure.message}', true),
        const SizedBox(height: 10),
      ],
      if (visible.isEmpty && !_searching)
        _statusBox(
            'No matching editions found. Try the original title, '
            'change the language, or paste a specific Wikisource edition URL.',
            false),
      for (final book in visible) ...[
        _bookCard(book),
        const SizedBox(height: 10)
      ],
      const SizedBox(height: 12),
      _surface(ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        title: const Text('Explore book libraries',
            style: TextStyle(color: ink, fontSize: 20, fontFamily: 'Georgia')),
        subtitle: const Text('Russian classics, English books and web novels',
            style: TextStyle(color: muted, fontSize: 12)),
        children: [
          for (final library in BookCatalogue.libraries)
            ListTile(
                contentPadding: EdgeInsets.zero,
                isThreeLine: false,
                title: Text('${library.name} · ${library.language}',
                    style: const TextStyle(color: ink, fontSize: 14)),
                subtitle: Text(library.description,
                    style: const TextStyle(
                        color: muted, fontSize: 12, height: 1.4)),
                trailing: const Icon(Icons.open_in_new_rounded,
                    color: pine, size: 18),
                onTap: () => browser.window
                    .open(library.url.toString(), '_blank', 'noopener')),
          const SizedBox(height: 8),
          const Text(
              'These links open the source website. Download availability '
              'depends on the title and provider; a listing is not an automatic import.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.5)),
        ],
      )),
    ]);
  }

  Widget _bookCard(CatalogueBook book) {
    final direct = book.kind == CatalogueBookKind.directEpub;
    return Semantics(
        button: true,
        enabled: !_busy && !_restoring,
        label: '${direct ? 'Download' : 'Prepare'} EPUB: ${book.title}',
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: line)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _busy || _restoring ? null : () => _chooseBook(book),
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Container(
                      width: 44,
                      height: 58,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: book.language == 'ru'
                              ? const Color(0xFFE9EDDF)
                              : const Color(0xFFF0E8DC),
                          borderRadius: BorderRadius.circular(6)),
                      child:
                          Icon(Icons.menu_book_rounded, color: pine, size: 24)),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(book.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: ink,
                                fontSize: 17,
                                fontFamily: 'Georgia',
                                height: 1.25)),
                        const SizedBox(height: 5),
                        if (book.author.isNotEmpty)
                          Text(book.author,
                              style:
                                  const TextStyle(color: muted, fontSize: 12)),
                        const SizedBox(height: 5),
                        Text(
                            '${book.language.toUpperCase()} · ${book.sourceName} · '
                            '${direct ? 'Source EPUB ↗' : 'Prepare EPUB'}',
                            style: const TextStyle(
                                color: pine, fontSize: 11, height: 1.5)),
                      ])),
                  const SizedBox(width: 8),
                  Icon(
                      direct
                          ? Icons.download_rounded
                          : Icons.arrow_forward_rounded,
                      color: pine,
                      size: 21),
                ])),
          ),
        ));
  }

  Widget _header() => Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: line))),
        child: Row(children: [
          Container(
              width: 37,
              height: 37,
              decoration: BoxDecoration(
                  color: ink, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.menu_book_rounded,
                  size: 20, color: Colors.white)),
          const SizedBox(width: 11),
          const Text('leaf.',
              style: TextStyle(
                  color: ink, fontSize: 24, fontWeight: FontWeight.w700)),
          const Spacer(),
          const Icon(Icons.lock_outline, size: 15, color: pine),
          const SizedBox(width: 6),
          const Text('Browser only',
              style: TextStyle(color: pine, fontSize: 12)),
        ]),
      );

  Widget _linksPanel() => _surface(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading('01', 'Choose your chapter range'),
          const SizedBox(height: 13),
          const Text(
              'Paste a Wikisource edition URL to find its chapters automatically. '
              'For a custom range, enter the first and last chapter from the same site.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.55)),
          const SizedBox(height: 18),
          _label('BOOK OR FIRST CHAPTER URL'),
          const SizedBox(height: 7),
          _field(_first, 'https://site.example/read/chapter/1'),
          const SizedBox(height: 14),
          _label('LAST CHAPTER URL · OPTIONAL FOR WIKISOURCE BOOKS'),
          const SizedBox(height: 7),
          _field(_last, 'Leave empty to find the book’s chapters'),
          const SizedBox(height: 7),
          TextButton.icon(
              onPressed: _busy ? null : _demo,
              icon: const Icon(Icons.science_outlined, size: 17),
              label: const Text('Try the open-book demo (3 chapters)')),
          TextButton.icon(
              onPressed: _busy ? null : _sampleCapture,
              icon: const Icon(Icons.travel_explore_outlined, size: 17),
              label: const Text('Try test collector pages (3 chapters)')),
          const SizedBox(height: 14),
          _label('BOOK TITLE'),
          const SizedBox(height: 7),
          _field(_title, 'Book title'),
          const SizedBox(height: 13),
          _label('AUTHOR'),
          const SizedBox(height: 7),
          _field(_author, 'Author (optional)'),
          const SizedBox(height: 20),
          SizedBox(
              width: double.infinity,
              child: _button(
                  _mobileNeedsCapture
                      ? (_isIPhoneSafari
                          ? 'Set up Safari capture'
                          : 'Import chapters on this phone')
                      : 'Collect & download EPUB',
                  _mobileNeedsCapture
                      ? Icons.phone_iphone_rounded
                      : Icons.download_rounded,
                  _busy ? null : _start)),
          if (_busy) ...[
            const SizedBox(height: 9),
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: _stop,
                    icon: const Icon(Icons.pause, size: 16),
                    label: const Text('Pause / cancel'))),
          ],
          const SizedBox(height: 9),
          const Text(
              'Direct EPUB creation works for supported open sources. '
              'Other websites may need the capture help below. '
              'Login and CAPTCHA, when required, stay on the source website.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.5)),
        ],
      ));

  Widget _filePanel() => _surface(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading('01', 'Your local chapters'),
          const SizedBox(height: 16),
          const Text(
              'Import TXT, HTML or JSON files. Files stay on your device.',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 14),
          SizedBox(
              width: double.infinity,
              child: _button('Choose files', Icons.upload_file_rounded,
                  _busy ? null : _import)),
          const SizedBox(height: 10),
          Text(_imported.length.toString() + ' chapters ready',
              style: const TextStyle(color: pine, fontSize: 12)),
          const SizedBox(height: 18),
          _label('BOOK TITLE'),
          const SizedBox(height: 7),
          _field(_title, 'Book title'),
          const SizedBox(height: 12),
          _label('AUTHOR'),
          const SizedBox(height: 7),
          _field(_author, 'Author'),
          const SizedBox(height: 19),
          SizedBox(
              width: double.infinity,
              child: _button('Create EPUB', Icons.download_rounded,
                  _busy ? null : _convertImported)),
        ],
      ));

  Widget _helperPanel() => _isPhone && !_isIPhoneSafari
      ? _statusBox(
          'On Android, use the built-in library or import available '
          'TXT, HTML or JSON chapter files. Desktop bookmark setup does not '
          'apply to this phone browser.',
          false)
      : _isIPhoneSafari
          ? _mobileHelperPanel()
          : _surface(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heading('02', 'Other websites — setup once'),
                const SizedBox(height: 12),
                const Text(
                    'If direct browser requests are blocked, Leaf opens the '
                    'normal reading website. The small helper runs in that source tab '
                    'and collects accessible chapter text at a gentle pace.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.6)),
                const SizedBox(height: 13),
                const SizedBox(
                    height: 44,
                    child: HtmlElementView(viewType: 'leaf-bookmarklet')),
                const SizedBox(height: 6),
                TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          const ClipboardData(text: bookmarklet));
                      if (mounted)
                        setState(() => _status =
                            'Copied. Create a bookmark called Leaf Capture and paste '
                                'the text into its URL field.');
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy bookmarklet URL instead')),
                TextButton.icon(
                    onPressed: () => unawaited(_copySelfContainedCapture()),
                    icon: const Icon(Icons.code_rounded, size: 16),
                    label: const Text(
                        'Copy self-contained helper (CSP fallback)')),
                TextButton.icon(
                    onPressed: () => unawaited(_copyCapturePlan()),
                    icon: const Icon(Icons.assignment_outlined, size: 16),
                    label: const Text(
                        'Copy capture plan (no tab connection needed)')),
                const SizedBox(height: 8),
                const Text(
                    'In the opened site tab: sign in or handle any CAPTCHA '
                    'yourself, then click the Leaf Capture bookmark. For strict CSP '
                    'or COOP sites, automatic collection may not be possible.',
                    style: TextStyle(color: muted, fontSize: 11, height: 1.6)),
                if (_awaitingHelper) ...[
                  const SizedBox(height: 10),
                  const Text('Waiting for Leaf Capture in source tab…',
                      style: TextStyle(
                          color: pine,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ],
            ));

  Widget _mobileHelperPanel() => _surface(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading('02', 'iPhone Safari — capture chapters'),
          const SizedBox(height: 12),
          const Text(
              'Safari does not let Leaf read another website or '
              'automatically operate its tabs. Instead, run a small bookmark '
              'from the reading page itself. This is experimental and may be '
              'blocked by the website.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.6)),
          const SizedBox(height: 15),
          const Text('1. Copy the personalized Safari helper',
              style: TextStyle(
                  color: ink, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          const Text(
              'In Safari, save a bookmark using Share → Add Bookmark. '
              'Open Bookmarks → Edit, rename it Leaf Capture, and paste the '
              'copied code into its address / URL field.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.55)),
          const SizedBox(height: 13),
          SizedBox(
              width: double.infinity,
              child: _button(
                  _cachedCaptureSource == null
                      ? 'Loading Safari helper…'
                      : 'Copy personalized Safari helper',
                  Icons.copy_rounded,
                  _cachedCaptureSource == null
                      ? null
                      : () => unawaited(_prepareSafariCapture()))),
          const SizedBox(height: 17),
          const Text('2. Open the first chapter and run Leaf Capture',
              style: TextStyle(
                  color: ink, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          const Text(
              'Handle any login or CAPTCHA yourself. Tap Leaf Capture '
              'from Safari Bookmarks while on the chapter page. Leave Safari '
              'open as the helper reads accessible pages.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.55)),
          const SizedBox(height: 12),
          SizedBox(
              width: double.infinity,
              child: _button('Open first chapter in Safari',
                  Icons.open_in_new_rounded, _openMobileChapter)),
          const SizedBox(height: 17),
          const Text('3. Import JSON to make EPUB',
              style: TextStyle(
                  color: ink, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          const Text(
              'When finished, save the collected JSON file. '
              'Return to Leaf → Import files → Choose files → Create EPUB. '
              'If it pauses, use Export JSON for the chapters collected so far.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.55)),
          const SizedBox(height: 14),
          const Text(
              'Important: RanobeLIB may block bookmarklets or '
              'automated page reads. This is not a guaranteed downloader '
              'and cannot bypass a CAPTCHA or access restrictions.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.6)),
        ],
      ));

  Widget _progressPanel() => _surface(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.auto_stories_outlined, color: pine, size: 22),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      _bookReady
                          ? (_partial
                              ? 'Your partial EPUB is ready'
                              : 'Your EPUB is ready')
                          : _busy
                              ? 'Preparing your book'
                              : (_storageWarning == null
                                  ? 'Your progress is saved'
                                  : 'Download paused'),
                      style: const TextStyle(
                          color: ink, fontSize: 19, fontFamily: 'Georgia')),
                  const SizedBox(height: 4),
                  Text(_title.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 12)),
                ])),
            const SizedBox(width: 8),
            Text(_total > 0 ? '$_done / $_total' : 'Finding…',
                style: const TextStyle(color: pine, fontSize: 12)),
          ]),
          const SizedBox(height: 15),
          LinearProgressIndicator(
              value: _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null,
              backgroundColor: line,
              color: pine,
              minHeight: 6),
          const SizedBox(height: 10),
          Text(_status,
              style: const TextStyle(color: pine, fontSize: 12, height: 1.5)),
          if (_busy && _isPhone) ...[
            const SizedBox(height: 7),
            const Text(
                'Keep this tab open while it downloads. If interrupted, '
                'return here to continue from your saved progress.',
                style: TextStyle(color: muted, fontSize: 11, height: 1.5)),
          ],
          if (_busy) ...[
            const SizedBox(height: 8),
            TextButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.pause_rounded),
                label: const Text('Pause download')),
          ],
          if (_bookReady) ...[
            const SizedBox(height: 14),
            SizedBox(
                width: double.infinity,
                child: _button(_isPhone ? 'Save EPUB' : 'Download EPUB again',
                    Icons.download_rounded, _download)),
            if (_canShare) ...[
              const SizedBox(height: 8),
              SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text('Share / open in a reader'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(50, 48)))),
            ],
          ],
          if (!_busy && _directUrls.isNotEmpty && _done < _total) ...[
            const SizedBox(height: 12),
            SizedBox(
                width: double.infinity,
                child: _button('Continue download', Icons.play_arrow_rounded,
                    _resumeDirect)),
          ],
          if (_chapters.isNotEmpty && !_busy && !_bookReady) ...[
            const SizedBox(height: 8),
            TextButton.icon(
                onPressed: () =>
                    unawaited(_createEpub(partial: _done < _total)),
                icon: const Icon(Icons.save_alt_rounded, size: 17),
                label: Text(_done < _total
                    ? 'Save a partial EPUB ($_done sections)'
                    : 'Create EPUB from saved sections')),
          ],
          if (_directUrls.isNotEmpty)
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Chapter details',
                    style: TextStyle(color: pine, fontSize: 12)),
                children: [
                  if (_manifestNote != null)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(_manifestNote!,
                            style:
                                const TextStyle(color: muted, fontSize: 12))),
                  for (var i = 0; i < _directUrls.length && i < 12; i++)
                    ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                            i < _done
                                ? Icons.check_circle_outline
                                : Icons.circle_outlined,
                            color: i < _done ? pine : muted,
                            size: 17),
                        title: Text(
                            _directUrls[i]
                                .pathSegments
                                .skip(1)
                                .join('/')
                                .replaceAll('_', ' '),
                            style: const TextStyle(color: ink, fontSize: 12)),
                        trailing: Text('${i + 1}',
                            style:
                                const TextStyle(color: muted, fontSize: 11))),
                  if (_directUrls.length > 12)
                    Text('… ${_directUrls.length - 12} more sections',
                        style: const TextStyle(color: muted, fontSize: 12)),
                ]),
        ],
      ));

  Widget _statusBox(String value, bool error) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: error ? const Color(0xFFFFF2EE) : const Color(0xFFEEF3EC),
            border: Border.all(color: error ? const Color(0xFFE5C5BC) : line),
            borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(error ? Icons.info_outline : Icons.check_circle_outline,
              color: error ? const Color(0xFF9B5B4C) : pine, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(value,
                  style: TextStyle(
                      color: error ? const Color(0xFF894A40) : pine,
                      fontSize: 12,
                      height: 1.5))),
        ]),
      );

  Widget _heading(String number, String label) => Row(children: [
        Container(
            width: 31,
            height: 31,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: const Color(0xFFE8F0E5),
                borderRadius: BorderRadius.circular(9)),
            child: Text(number,
                style: const TextStyle(
                    color: pine, fontSize: 11, fontWeight: FontWeight.w700))),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 20, fontFamily: 'Georgia', color: ink))),
      ]);
  Widget _label(String value) => Text(value,
      style: const TextStyle(
          color: muted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2));

  Widget _field(TextEditingController c, String hint) => TextField(
      controller: c,
      enabled: !_busy,
      keyboardType:
          c == _title || c == _author ? TextInputType.text : TextInputType.url,
      onChanged: (v) {
        if (c == _first || c == _last) {
          setState(() => _mobilePrepared = false);
        }
        if ((c == _title || c == _author) && _bookReady) {
          setState(() {
            _bookReady = false;
            _epub = null;
            _status =
                'Book details changed. Create the EPUB again to update it.';
          });
        }
      },
      minLines: 1,
      maxLines: c == _title || c == _author ? 1 : 3,
      style: const TextStyle(color: ink, fontSize: 12),
      decoration: InputDecoration(hintText: hint));

  Widget _surface(Widget child) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(23),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: line),
          boxShadow: const [
            BoxShadow(
                color: Color(0x09000000), offset: Offset(0, 7), blurRadius: 25)
          ]),
      child: child);

  Widget _button(String text, IconData icon, VoidCallback? fn) =>
      FilledButton.icon(
        onPressed: fn,
        icon: Icon(icon, size: 17),
        label: Text(text, style: const TextStyle(fontSize: 12)),
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF9FA99F),
          minimumSize: const Size(50, 49),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
}
