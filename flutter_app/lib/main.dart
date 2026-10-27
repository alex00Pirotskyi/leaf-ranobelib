// Leaf: Flutter Web + Dart EPUB. Public API directly, other sites via user bookmarklet.
import 'dart:async';
import 'dart:convert';
import 'dart:html' as browser;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'core/chapter_url_plan.dart';
import 'core/epub_builder.dart';
import 'core/local_importer.dart';
import 'core/open_reader.dart';

const paper = Color(0xFFF8F7F2), ink = Color(0xFF28382F);
const pine = Color(0xFF3C5F4A), muted = Color(0xFF78817A);
const line = Color(0xFFE3E7DF);
const demoStart = 'https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_1';
const demoEnd = 'https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_3';
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
      ..style.cssText = 'display:flex;align-items:center;justify-content:center;'
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
        filled: true, fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
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

enum Mode { links, files }

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
  Mode _mode = Mode.links;
  bool _busy = false, _cancelled = false, _awaitingHelper = false;
  bool _bookReady = false;
  String _status = 'Ready — try the public-domain three-chapter demo.';
  String? _error;
  ChapterUrlPlan? _plan;
  String? _token, _sourceOrigin;
  browser.WindowBase? _readerWindow;
  StreamSubscription<browser.MessageEvent>? _messages;
  Uint8List? _epub;
  List<BookChapter> _chapters = [], _imported = [];
  int _done = 0, _total = 0;
  bool _mobilePrepared = false;
  bool get _isIPhoneSafari => RegExp(r'iPhone|iPad|iPod').hasMatch(browser.window.navigator.userAgent);
  bool get _mobileNeedsCapture {
    final uri = Uri.tryParse(_first.text.trim());
    return _isIPhoneSafari && (uri == null || !OpenReader.supports(uri));
  }

  @override
  void initState() {
    super.initState();
    _messages = browser.window.onMessage.listen(_message);
  }

  @override
  void dispose() {
    _messages?.cancel();
    _reader.close();
    _first.dispose(); _last.dispose(); _title.dispose(); _author.dispose();
    super.dispose();
  }

  String _createToken() {
    final rng = Random.secure();
    return List.generate(24, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
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
    } catch (_) { return; }
    if (data['leaf'] != 2) return;
    if (data['type'] == 'hello') {
      if (data['token'] != _token) return;
      final pageUrl = (data['pageUrl'] ?? '').toString();
      final proposed = Uri.tryParse(pageUrl);
      final resumeUrl = !plan.inferred && proposed != null &&
              proposed.origin == plan.start.origin
          ? proposed.toString() : plan.start.toString();
      final config = {
        'leaf':2, 'type':'job', 'token':_token,
        'start':resumeUrl, 'end':plan.end.toString(),
        'urls':plan.urls.map((u)=>u.toString()).toList(),
        'max':plan.inferred ? plan.urls.length : ChapterUrlPlan.maxChapters,
        'title':_title.text, 'resumeFrom':_chapters.length,
      };
      try {
        _readerWindow?.postMessage(jsonEncode(config), plan.start.origin);
        if (mounted) setState(() => _status = 'Capture connected. Reading chapters…');
      } catch (_) {
        if (mounted) setState(() => _error =
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
        if (i is! int || i != _chapters.length || url == null ||
            !plan.contains(url) || title.length > 300 ||
            html.length < 15 || html.length > 650000) return;
        if (plan.inferred && (i >= plan.urls.length || plan.urls[i] != url)) return;
        _chapters.add(BookChapter(
          title.isEmpty ? 'Chapter ' + (i+1).toString() : title, html));
        if (mounted) setState(() {
          _done = _chapters.length;
          _status = 'Received ' + _done.toString() + ' chapters…';
        });
      case 'halt':
        if (mounted) setState(() {
          _busy = false;
          _status = 'Paused after ' + _done.toString() + ' chapters.';
          _error = (data['note'] ?? 'The reader stopped.').toString();
        });
      case 'done':
        if (_chapters.isEmpty) return;
        if (plan.inferred && _chapters.length != plan.urls.length) {
          if (mounted) setState(() => _error =
            'Some chapters are missing. Resume, or save a partial EPUB.');
          return;
        }
        _awaitingHelper = false;
        _busy = false;
        unawaited(_createEpub());
    }
  }

  void _start() {
    if (_busy) return;
    late final ChapterUrlPlan plan;
    try {
      plan = ChapterUrlPlan.parse(_first.text, _last.text);
    } catch (e) {
      setState(() => _error = _errorText(e)); return;
    }
    if (_mobileNeedsCapture && !(plan.isWikimedia && plan.inferred)) {
      setState(() {
        _plan = plan;
        _epub = null; _bookReady = false; _chapters = [];
        _done = 0; _total = 0; _busy = false;
        _awaitingHelper = false; _mobilePrepared = false;
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
      return;
    }
    setState(() {
      _plan = plan; _epub = null; _bookReady = false;
      _chapters = []; _done = 0;
      _total = plan.inferred ? plan.urls.length : ChapterUrlPlan.maxChapters;
      _error = null; _cancelled = false;
      _busy = true; _awaitingHelper = false;
      _status = plan.description;
    });
    if (plan.isWikimedia && plan.inferred) {
      unawaited(_readOpenApi(plan));
      return;
    }
    // Open synchronously in the user's click gesture, before any await.
    _token = _createToken();
    _sourceOrigin = plan.start.origin;
    _readerWindow = browser.window.open(
      plan.start.replace(fragment: 'leaf_session=$_token').toString(), 'leaf-chapter-source');
    if (_readerWindow == null) {
      setState(() {
        _busy = false;
        _error = 'Browser blocked the chapter tab. Allow pop-ups and try again.';
      });
      return;
    }
    setState(() {
      _awaitingHelper = true;
      _status = 'Reader tab opened. Solve any login or CAPTCHA yourself, '
        'then click your Leaf Capture bookmark inside that tab.';
    });
  }

  Future<void> _readOpenApi(ChapterUrlPlan plan) async {
    try {
      for (var i=0;i<plan.urls.length;i++) {
        if (_cancelled) throw const FormatException('Canceled.');
        final chapter = await _reader.read(plan.urls[i]);
        if (_cancelled) throw const FormatException('Canceled.');
        _chapters.add(chapter);
        if (mounted) setState(() {
          _done = _chapters.length;
          _status = 'Fetched ' + _done.toString() + ' / ' + _total.toString();
        });
        if (i+1<plan.urls.length) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      await _createEpub();
    } catch(e) {
      if (mounted) setState(() {
        _busy = false; _error = _errorText(e);
        _status = 'Stopped; any collected chapters can still be saved.';
      });
    }
  }

  Future<void> _createEpub() async {
    if (_chapters.isEmpty) {
      if (mounted) setState(() => _error = 'Nothing to convert yet.');
      return;
    }
    try {
      if (mounted) setState(() => _status = 'Packaging EPUB in Dart…');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final bytes = EpubBuilder.build(
        title: _title.text.isEmpty ? 'Collected chapters' : _title.text,
        author: _author.text, chapters: _chapters);
      _epub = bytes;
      if (mounted) setState(() {
        _busy = false; _bookReady = true; _awaitingHelper = false;
        _status = 'EPUB created: ' + _chapters.length.toString() + ' chapters (' +
            (bytes.length / 1024).round().toString() + ' KB).';
      });
      _download();
    } catch(e) {
      if (mounted) setState(() { _busy = false; _error = _errorText(e); });
    }
  }

  void _download() {
    if (_epub == null) return;
    final blob = browser.Blob([_epub!], 'application/epub+zip');
    final url = browser.Url.createObjectUrlFromBlob(blob);
    final link = browser.AnchorElement(href:url)
      ..download = EpubBuilder.safeFilename(_title.text)
      ..style.display = 'none';
    browser.document.body?.append(link);
    link.click();link.remove();
    Future<void>.delayed(const Duration(seconds: 10),
      ()=>browser.Url.revokeObjectUrl(url));
  }

  Future<void> _import() async {
    if (_busy) return;
    try {
      final result = await LocalImporter.chooseChapters();
      if (mounted) setState(() {
        _imported = [..._imported,...result];
        _status = 'Imported ' + result.length.toString() + ' chapter files.';
        _error = null;
      });
    } catch(e) {
      if (mounted) setState(() => _error = _errorText(e));
    }
  }

  void _convertImported() {
    if (_imported.isEmpty) {
      setState(() => _error = 'Please import chapter files first.');return;
    }
    _chapters = List.of(_imported);
    _done = _chapters.length;_total = _done;
    unawaited(_createEpub());
  }

  void _stop() {
    _cancelled = true;
    _busy = false;
    _awaitingHelper = false;
    if (_token != null && _sourceOrigin != null) {
      try {
        _readerWindow?.postMessage(jsonEncode({
          'leaf':2,'type':'stop','token':_token}), _sourceOrigin!);
      } catch (_) {}
    }
    setState(() => _status = 'Paused. Collected chapters are kept in this tab.');
  }

  String _errorText(Object e) =>
      e is FormatException ? e.message : e.toString().replaceFirst('Exception: ', '');

  void _demo() {
    if (_busy) return;
    setState(() {
      _first.text=demoStart;_last.text=demoEnd;
      _title.text='Pride and Prejudice';_author.text='Jane Austen';
      _error=null;
      _status='Three chapters: public-domain Wikimedia direct API demo.';
    });
  }

  Future<void> _copySelfContainedCapture() async {
    try {
      final response = await http.get(Uri.base.resolve('leaf-capture.js'))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw FormatException('Cannot load the in-page helper (HTTP ' +
            response.statusCode.toString() + ').');
      }
      final source = utf8.decode(response.bodyBytes);
      if (!source.contains('leafCaptureV2') || source.length > 85000) {
        throw const FormatException('Unexpected bookmarklet source.');
      }
      // The full source runs in the reader tab itself: no additional script
      // request to GitHub Pages is needed after installation.
      final javascript = 'javascript:' + source.replaceAll(RegExp(r'\r?\n'), ' ');
      await Clipboard.setData(ClipboardData(text: javascript));
      if (mounted) setState(() {
        _status = 'Full self-contained bookmarklet copied. Create a new '
            'bookmark and paste this in its URL field. Use this version '
            'when a website blocks loading external scripts.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    }
  }

  Future<void> _prepareSafariCapture() async {
    late final ChapterUrlPlan plan;
    try {
      plan = ChapterUrlPlan.parse(_first.text, _last.text);
      if (plan.isWikimedia && plan.inferred) {
        throw const FormatException('For Wikisource, just press Collect & download EPUB.');
      }
      if (mounted) setState(() {
        _status = 'Preparing your Safari chapter collector…';
        _error = null;
      });
      final response = await http.get(Uri.base.resolve('leaf-capture.js'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw FormatException('Cannot load chapter helper (HTTP ' +
            response.statusCode.toString() + ').');
      }
      final source = utf8.decode(response.bodyBytes);
      if (!source.contains('leafCaptureV2') || source.length > 90000) {
        throw const FormatException('Unexpected chapter collector source.');
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
      final javascript = 'javascript:(function(){window.__leafOfflineJobV2=' +
          job + ';' + source.replaceAll(RegExp(r'\r?\n'), ' ') + '})();';
      await Clipboard.setData(ClipboardData(text: javascript));
      if (mounted) setState(() {
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
      _first.text = 'https://alex00pirotskyi.github.io/leaf-ranobelib/fixtures/chapter-1.html';
      _last.text = 'https://alex00pirotskyi.github.io/leaf-ranobelib/fixtures/chapter-3.html';
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
    return Scaffold(body: SafeArea(child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(compact?18:35,0,compact?18:35,50),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(),
          const SizedBox(height: 43),
          const Text('YOUR PRIVATE BOOKMAKER',style:TextStyle(
            color:pine,fontSize:10,fontWeight:FontWeight.w700,letterSpacing:2)),
          const SizedBox(height: 10),
          Text('Keep good stories.\nRead anywhere.',
            style:TextStyle(fontFamily:'Georgia',color:ink,
              fontSize:compact?39:54,height:1.14,letterSpacing:-1.6)),
          const SizedBox(height: 13),
          const Text('Paste two chapter URLs. We find the pattern, collect '
            'accessible pages, and make a real EPUB right in your browser.',
            style:TextStyle(color:muted,fontSize:13,height:1.6)),
          const SizedBox(height: 24),
          Wrap(spacing:9,children:[
            ChoiceChip(label:const Text('Chapter links'),
              selected:_mode==Mode.links,
              onSelected:_busy?null:(_)=>setState(()=>_mode=Mode.links)),
            ChoiceChip(label:const Text('Import files'),
              selected:_mode==Mode.files,
              onSelected:_busy?null:(_)=>setState(()=>_mode=Mode.files)),
          ]),
          const SizedBox(height: 18),
          _mode==Mode.links?_linksPanel():_filePanel(),
          if (_error!=null) ...[
            const SizedBox(height:16),_statusBox(_error!,true),
          ],
          if (_busy||_done>0||_bookReady) ...[
            const SizedBox(height:16),_progressPanel(),
          ],
          if(_mode==Mode.links)...[
            const SizedBox(height:18),_helperPanel(),
          ],
          const SizedBox(height:17),
          _statusBox(_status,false),
          const SizedBox(height:39),
          const Divider(color:line),
          const SizedBox(height:14),
          const Text('leaf. · No Python · No backend · EPUB generated in Dart',
            style:TextStyle(fontSize:11,color:muted)),
        ]),
      )),
    )));
  }

  Widget _header()=>Container(
    padding:const EdgeInsets.symmetric(vertical:20),
    decoration:const BoxDecoration(border:Border(bottom:BorderSide(color:line))),
    child:Row(children:[
      Container(width:37,height:37,
        decoration:BoxDecoration(color:ink,borderRadius:BorderRadius.circular(10)),
        child:const Icon(Icons.menu_book_rounded,size:20,color:Colors.white)),
      const SizedBox(width:11),
      const Text('leaf.',style:TextStyle(
        color:ink,fontSize:24,fontWeight:FontWeight.w700)),
      const Spacer(),
      const Icon(Icons.lock_outline,size:15,color:pine),
      const SizedBox(width:6),
      const Text('Browser only',style:TextStyle(color:pine,fontSize:12)),
    ]),
  );

  Widget _linksPanel()=>_surface(Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      _heading('01','Choose your chapter range'),
      const SizedBox(height:13),
      const Text('Paste the first and last chapter URL from the same site. '
        'Numbered URLs are handled automatically; opaque paths use Next links.',
        style:TextStyle(color:muted,fontSize:12,height:1.55)),
      const SizedBox(height:18),
      _label('FIRST CHAPTER URL'),const SizedBox(height:7),
      _field(_first,'https://site.example/read/chapter/1'),
      const SizedBox(height:14),
      _label('LAST CHAPTER URL'),const SizedBox(height:7),
      _field(_last,'https://site.example/read/chapter/20'),
      const SizedBox(height:7),
      TextButton.icon(onPressed:_busy?null:_demo,
        icon:const Icon(Icons.science_outlined,size:17),
        label:const Text('Try the open-book demo (3 chapters)')),
      TextButton.icon(onPressed:_busy?null:_sampleCapture,
        icon:const Icon(Icons.travel_explore_outlined,size:17),
        label:const Text('Try test collector pages (3 chapters)')),
      const SizedBox(height:14),
      _label('BOOK TITLE'),const SizedBox(height:7),
      _field(_title,'Book title'),
      const SizedBox(height:13),
      _label('AUTHOR'),const SizedBox(height:7),
      _field(_author,'Author (optional)'),
      const SizedBox(height:20),
      SizedBox(width:double.infinity,child:_button(
        'Collect & download EPUB',Icons.download_rounded,_busy?null:_start)),
      if(_busy)...[
        const SizedBox(height:9),
        Align(alignment:Alignment.centerRight,child:TextButton.icon(
          onPressed:_stop,icon:const Icon(Icons.pause,size:16),
          label:const Text('Pause / cancel'))),
      ],
      const SizedBox(height:9),
      const Text('Wikisource/Wikibooks: fully automated from Leaf. '
        'Other websites: open the tab and activate Leaf Capture once. '
        'CAPTCHAs and access restrictions are never bypassed.',
        style:TextStyle(color:muted,fontSize:11,height:1.5)),
    ],
  ));

  Widget _filePanel()=>_surface(Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      _heading('01','Your local chapters'),const SizedBox(height:16),
      const Text('Import TXT, HTML or JSON files. Files stay on your device.',
        style:TextStyle(color:muted,fontSize:12)),
      const SizedBox(height:14),
      SizedBox(width:double.infinity,child:_button(
        'Choose files',Icons.upload_file_rounded,_busy?null:_import)),
      const SizedBox(height:10),
      Text(_imported.length.toString()+' chapters ready',
        style:const TextStyle(color:pine,fontSize:12)),
      const SizedBox(height:18),
      _label('BOOK TITLE'),const SizedBox(height:7),_field(_title,'Book title'),
      const SizedBox(height:12),
      _label('AUTHOR'),const SizedBox(height:7),_field(_author,'Author'),
      const SizedBox(height:19),
      SizedBox(width:double.infinity,child:_button(
        'Create EPUB',Icons.download_rounded,_busy?null:_convertImported)),
    ],
  ));

  Widget _helperPanel()=>_surface(Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      _heading('02','Other websites — setup once'),
      const SizedBox(height:12),
      const Text('If direct browser requests are blocked, Leaf opens the '
        'normal reading website. The small helper runs in that source tab '
        'and collects accessible chapter text at a gentle pace.',
        style:TextStyle(color:muted,fontSize:12,height:1.6)),
      const SizedBox(height:13),
      const SizedBox(height:44,child:HtmlElementView(viewType:'leaf-bookmarklet')),
      const SizedBox(height:6),
      TextButton.icon(
        onPressed:() async {
          await Clipboard.setData(const ClipboardData(text:bookmarklet));
          if(mounted) setState(() => _status =
            'Copied. Create a bookmark called Leaf Capture and paste '
            'the text into its URL field.');
        },
        icon:const Icon(Icons.copy,size:16),
        label:const Text('Copy bookmarklet URL instead')),
      TextButton.icon(
        onPressed:()=>unawaited(_copySelfContainedCapture()),
        icon:const Icon(Icons.code_rounded,size:16),
        label:const Text('Copy self-contained helper (CSP fallback)')),
      const SizedBox(height:8),
      const Text('In the opened site tab: sign in or handle any CAPTCHA '
        'yourself, then click the Leaf Capture bookmark. For strict CSP '
        'or COOP sites, automatic collection may not be possible.',
        style:TextStyle(color:muted,fontSize:11,height:1.6)),
      if(_awaitingHelper)...[
        const SizedBox(height:10),
        const Text('Waiting for Leaf Capture in source tab…',
          style:TextStyle(color:pine,fontSize:12,fontWeight:FontWeight.w700)),
      ],
    ],
  ));

  Widget _progressPanel()=>_surface(Column(
    crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[
        const Icon(Icons.auto_stories_outlined,color:pine,size:20),
        const SizedBox(width:10),
        Text(_bookReady?'Your EPUB is ready':'Collecting chapters',
          style:const TextStyle(color:ink,fontSize:17,fontFamily:'Georgia')),
        const Spacer(),
        Text(_done.toString()+' / '+_total.toString(),
          style:const TextStyle(color:pine,fontSize:12)),
      ]),
      const SizedBox(height:14),
      LinearProgressIndicator(
        value:_total>0?(_done/_total).clamp(0.0,1.0):null,
        backgroundColor:line,color:pine,minHeight:6),
      if(_bookReady)...[
        const SizedBox(height:13),
        SizedBox(width:double.infinity,child:_button(
          'Download EPUB again',Icons.download_rounded,_download)),
      ]else if(_chapters.isNotEmpty&&!_busy)...[
        const SizedBox(height:13),
        SizedBox(width:double.infinity,child:_button(
          'Save collected chapters (partial EPUB)',Icons.download_rounded,
          ()=>unawaited(_createEpub()))),
      ],
    ],
  ));

  Widget _statusBox(String value,bool error)=>Container(
    width:double.infinity,
    padding:const EdgeInsets.all(14),
    decoration:BoxDecoration(
      color:error?const Color(0xFFFFF2EE):const Color(0xFFEEF3EC),
      border:Border.all(color:error?const Color(0xFFE5C5BC):line),
      borderRadius:BorderRadius.circular(10)),
    child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Icon(error?Icons.info_outline:Icons.check_circle_outline,
        color:error?const Color(0xFF9B5B4C):pine,size:18),
      const SizedBox(width:10),
      Expanded(child:Text(value,style:TextStyle(
        color:error?const Color(0xFF894A40):pine,
        fontSize:12,height:1.5))),
    ]),
  );

  Widget _heading(String number,String label)=>Row(children:[
    Container(width:31,height:31,alignment:Alignment.center,
      decoration:BoxDecoration(color:const Color(0xFFE8F0E5),
        borderRadius:BorderRadius.circular(9)),
      child:Text(number,style:const TextStyle(
        color:pine,fontSize:11,fontWeight:FontWeight.w700))),
    const SizedBox(width:10),
    Expanded(child:Text(label,style:const TextStyle(
      fontSize:20,fontFamily:'Georgia',color:ink))),
  ]);
  Widget _label(String value)=>Text(value,style:const TextStyle(
    color:muted,fontSize:10,fontWeight:FontWeight.w700,letterSpacing:1.2));

  Widget _field(TextEditingController c,String hint)=>TextField(
    controller:c,enabled:!_busy,
    keyboardType:TextInputType.url,
    minLines:1,maxLines:c==_title||c==_author?1:3,
    style:const TextStyle(color:ink,fontSize:12),
    decoration:InputDecoration(hintText:hint));

  Widget _surface(Widget child)=>Container(
    width:double.infinity,padding:const EdgeInsets.all(23),
    decoration:BoxDecoration(color:Colors.white,
      borderRadius:BorderRadius.circular(17),
      border:Border.all(color:line),
      boxShadow:const [BoxShadow(color:Color(0x09000000),
        offset:Offset(0,7),blurRadius:25)]),
    child:child);

  Widget _button(String text,IconData icon,VoidCallback? fn)=>
    FilledButton.icon(
      onPressed:fn,
      icon:Icon(icon,size:17),
      label:Text(text,style:const TextStyle(fontSize:12)),
      style:FilledButton.styleFrom(
        backgroundColor:ink,foregroundColor:Colors.white,
        disabledBackgroundColor:const Color(0xFF9FA99F),
        minimumSize:const Size(50,49),
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10)),
      ),
    );
}
