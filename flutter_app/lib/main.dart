// Leaf · clean, responsive Flutter Web UI for the original RanobeLIB downloader.
// Browser requests go to a private Python API; the browser cannot run Python.
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const LeafApp());

const _paper = Color(0xFFF8F7F2);
const _ink = Color(0xFF28342D);
const _muted = Color(0xFF79817A);
const _pine = Color(0xFF385847);
const _line = Color(0xFFE5E6DE);
const _card = Color(0xFFFEFEFB);
const _bookUrl =
    'https://ranobelib.me/ru/book/202399--okiraku-ryoushu-no-tanoshii-ryouchi-bouei-seisan-kei-majutsu-de-na-mo-naki-mura-wo-saikyou-no-jousai-toshi-ni';

class LeafApp extends StatelessWidget {
  const LeafApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Leaf · Offline reading',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _pine,
          surface: _paper,
          brightness: Brightness.light,
        ),
        textSelectionTheme: const TextSelectionThemeData(cursorColor: _pine),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 17),
          border: OutlineInputBorder(
            borderSide: const BorderSide(color: _line),
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _line),
            borderRadius: BorderRadius.circular(12),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _pine, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const ReaderHome(),
    );
  }
}

class Branch {
  final String id;
  final String label;
  final int count;
  Branch.fromJson(Map<String, dynamic> v)
      : id = '${v['id']}',
        label = '${v['label'] ?? ''}',
        count = (v['count'] as num?)?.toInt() ?? 0;
}

class Book {
  final String title;
  final String author;
  final String? cover;
  final int chapterCount;
  final List<Branch> branches;
  Book.fromJson(Map<String, dynamic> v)
      : title = '${v['title'] ?? 'Untitled'}',
        author = '${v['author'] ?? ''}',
        cover = v['cover_url'] as String?,
        chapterCount = (v['chapter_count'] as num?)?.toInt() ?? 0,
        branches = ((v['branches'] as List?) ?? [])
            .map((e) => Branch.fromJson(e as Map<String, dynamic>))
            .toList();
}

class ExportJob {
  final String id;
  final String status;
  final String stage;
  final int progress;
  final int total;
  final String? filename;
  final String? error;
  final String? downloadUrl;
  ExportJob.fromJson(Map<String, dynamic> v)
      : id = '${v['id']}',
        status = '${v['status']}',
        stage = '${v['stage'] ?? ''}',
        progress = (v['progress'] as num?)?.toInt() ?? 0,
        total = (v['total'] as num?)?.toInt() ?? 0,
        filename = v['filename'] as String?,
        error = v['error'] as String?,
        downloadUrl = v['download_url'] as String?;
}

class LeafApi {
  static const _configured = String.fromEnvironment('API_BASE_URL');
  static const _storageKey = 'leaf_backend_url_v1';
  final http.Client _client = http.Client();
  String? _savedUrl;

  LeafApi() {
    try {
      _savedUrl = html.window.localStorage[_storageKey];
    } catch (_) {
      // Storage may be blocked by privacy settings.
    }
  }

  bool get isGithubPages => Uri.base.host.toLowerCase().endsWith('.github.io');
  bool get hasConfiguredBackend =>
      (_savedUrl?.trim().isNotEmpty ?? false) || _configured.trim().isNotEmpty;
  bool get needsBackend => isGithubPages && !hasConfiguredBackend;

  String get baseUrl {
    if (_savedUrl?.trim().isNotEmpty ?? false) return _savedUrl!.trim();
    if (_configured.trim().isNotEmpty) {
      return _configured.trim().replaceFirst(RegExp(r'/$'), '');
    }
    return Uri.base.origin;
  }

  void setBackendUrl(String input) {
    final url = input.trim();
    final parsed = Uri.tryParse(url);
    final local = parsed != null &&
        (parsed.host == 'localhost' || parsed.host == '127.0.0.1');
    if (parsed == null ||
        !(parsed.scheme == 'https' || (local && parsed.scheme == 'http')) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.host.toLowerCase().endsWith('.github.io') ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        parsed.hasQuery || parsed.hasFragment) {
      throw const FormatException(
        'Enter the HTTPS URL of the Python API (e.g. https://your-api.onrender.com), without /api.',
      );
    }
    _savedUrl = url.replaceFirst(RegExp(r'/$'), '');
    try {
      html.window.localStorage[_storageKey] = _savedUrl!;
    } catch (_) {
      // Keep the URL for this session.
    }
  }

  Uri uri(String path) {
    if (needsBackend) {
      throw StateError(
        'Python backend not connected. GitHub Pages only hosts the website. Configure the HTTPS API in Server settings.',
      );
    }
    return Uri.parse('$baseUrl$path');
  }

  Map<String, dynamic> _decode(http.Response response) {
    dynamic value;
    try {
      value = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      if (response.statusCode == 405) {
        throw Exception(
          'HTTP 405: this address cannot serve the Leaf API. GitHub Pages cannot run Python. Connect your backend in Server settings.',
        );
      }
      throw Exception(
        'HTTP ' + response.statusCode.toString() +
        ': non-JSON response from $baseUrl. Check the Python API URL.',
      );
    }
    if (response.statusCode >= 400) {
      final detail = (value is Map ? value['detail'] : null);
      throw Exception(detail is String
          ? detail
          : 'API request failed (HTTP ' + response.statusCode.toString() + ').');
    }
    if (value is! Map) {
      throw Exception('Unexpected API response format.');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final response = await _client
        .post(uri(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 50));
    return _decode(response);
  }

  Future<void> verifyBackend() async {
    final response = await _client.get(uri('/api/health')).timeout(const Duration(seconds: 15));
    final result = _decode(response);
    if (result['status'] != 'ok') {
      throw Exception('This server is not a working Leaf API.');
    }
    if (result['downloader_installed'] != true) {
      throw Exception('The API is online, but RanobeLIB downloader is not installed.');
    }
  }

  Future<Book> inspect(String url) async =>
      Book.fromJson(await _post('/api/book/inspect', {'url': url}));

  Future<ExportJob> export(Map<String, dynamic> body) async =>
      ExportJob.fromJson(await _post('/api/jobs', body));

  Future<ExportJob> status(String id) async {
    final response = await _client.get(uri('/api/jobs/$id')).timeout(const Duration(seconds: 12));
    return ExportJob.fromJson(_decode(response));
  }

  Future<void> cancel(String id) async {
    await _post('/api/jobs/$id/cancel', {});
  }

  void dispose() => _client.close();
}

enum ChapterScope { all, latest, custom }

class ReaderHome extends StatefulWidget {
  const ReaderHome({super.key});
  @override
  State<ReaderHome> createState() => _ReaderHomeState();
}

class _ReaderHomeState extends State<ReaderHome> {
  final _api = LeafApi();
  final _url = TextEditingController(text: _bookUrl);
  final _start = TextEditingController(text: '1');
  final _end = TextEditingController();
  late final TextEditingController _backendUrl;
  bool _showBackendSettings = false;
  bool _connecting = false;
  String? _backendNotice;
  Timer? _ticker;
  Book? _book;
  ExportJob? _job;
  String _branchId = 'default';
  ChapterScope _scope = ChapterScope.all;
  bool _loading = false;
  bool _submitting = false;
  bool _polling = false;
  bool _cover = true;
  bool _images = true;
  bool _cache = true;
  String? _message;

  int get _count => _book?.branches
          .where((e) => e.id == _branchId)
          .map((e) => e.count)
          .firstOrNull ??
      (_book?.chapterCount ?? 0);

  bool get _active => _job?.status == 'running' || _job?.status == 'queued';

  @override
  void initState() {
    super.initState();
    _backendUrl = TextEditingController(
      text: _api.hasConfiguredBackend ? _api.baseUrl : '',
    );
    _showBackendSettings = _api.needsBackend;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _api.dispose();
    _url.dispose();
    _start.dispose();
    _end.dispose();
    _backendUrl.dispose();
    super.dispose();
  }

  Future<void> _connectBackend() async {
    if (_connecting || _active) return;
    setState(() {
      _connecting = true;
      _backendNotice = null;
      _message = null;
    });
    try {
      _api.setBackendUrl(_backendUrl.text);
      await _api.verifyBackend();
      if (!mounted) return;
      setState(() {
        _backendNotice = 'Connected to Python downloader.';
        _showBackendSettings = false;
        _book = null;
        _job = null;
      });
    } catch (e) {
      if (mounted) setState(() => _backendNotice = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _inspect() async {
    if (_loading || _active) return;
    setState(() {
      _loading = true;
      _message = null;
      _book = null;
      _job = null;
    });
    _ticker?.cancel();
    try {
      final book = await _api.inspect(_url.text.trim());
      if (!mounted) return;
      setState(() {
        _book = book;
        _branchId = 'default';
        _scope = ChapterScope.all;
        _start.text = '1';
        _end.text = '${book.chapterCount}';
      });
    } catch (e) {
      if (mounted) setState(() => _message = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object e) {
    final text = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
    if (text.contains('Failed host lookup') || text.contains('XMLHttpRequest') ||
        text.contains('ClientException') || text.contains('Failed to fetch')) {
      return 'Cannot reach the Python API. Check its HTTPS URL, hosting status, and allowed CORS origin.';
    }
    return text;
  }

  Future<void> _create() async {
    if (_book == null || _submitting || _active) return;
    final count = _count;
    var first = 1;
    int? last;
    if (_scope == ChapterScope.latest) first = (count - 49).clamp(1, count).toInt();
    if (_scope == ChapterScope.custom) {
      first = int.tryParse(_start.text.trim()) ?? 0;
      last = int.tryParse(_end.text.trim());
      if (first < 1 || first > count || last == null || last < first || last > count) {
        setState(() => _message = 'Choose a valid chapter range between 1 and $count.');
        return;
      }
    }
    setState(() {
      _submitting = true;
      _message = null;
      _job = null;
    });
    try {
      final job = await _api.export({
        'url': _url.text.trim(), 'branch': _branchId,
        'start': first, 'end': last,
        'cover': _cover, 'images': _images, 'cache': _cache,
      });
      if (!mounted) return;
      setState(() => _job = job);
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
      await _poll();
    } catch (e) {
      if (mounted) setState(() => _message = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _poll() async {
    if (_job == null || _polling) return;
    _polling = true;
    try {
      final update = await _api.status(_job!.id);
      if (!mounted) return;
      setState(() => _job = update);
      if (['complete', 'error', 'canceled'].contains(update.status)) _ticker?.cancel();
    } catch (e) {
      if (mounted) setState(() => _message = _friendlyError(e));
      _ticker?.cancel();
    } finally {
      _polling = false;
    }
  }

  void _download() {
    final path = _job?.downloadUrl;
    if (path == null) return;
    final anchor = html.AnchorElement(href: '${_api.baseUrl}$path')
      ..download = _job?.filename ?? 'novel.epub';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  }

  Future<void> _cancel() async {
    final id = _job?.id;
    if (id == null) return;
    try {
      await _api.cancel(id);
      await _poll();
    } catch (e) {
      if (mounted) setState(() => _message = _friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 780;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(compact ? 19 : 36, 0, compact ? 19 : 36, 48),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1090),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _header(compact),
                const SizedBox(height: 52),
                _hero(compact),
                if (_api.needsBackend || _showBackendSettings) ...[
                  const SizedBox(height: 24),
                  _backendSettingsCard(),
                ] else if (_backendNotice != null) ...[
                  const SizedBox(height: 19),
                  Text(_backendNotice!, style: const TextStyle(color: _pine, fontSize: 12)),
                ],
                const SizedBox(height: 37),
                if (compact) ...[
                  _sourceCard(),
                  if (_book != null) ...[const SizedBox(height: 18), _optionsCard()],
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 10, child: _sourceCard()),
                    const SizedBox(width: 22),
                    Expanded(flex: 8, child: _book != null ? _optionsCard() : _introCard()),
                  ]),
                if (_message != null) ...[const SizedBox(height: 18), _errorNotice(_message!)],
                if (_job != null) ...[const SizedBox(height: 22), _jobCard()],
                const SizedBox(height: 48),
                _footer(compact),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(bool compact) => Container(
    padding: const EdgeInsets.symmetric(vertical: 23),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
    child: Row(children: [
      Container(
        height: 38, width: 38,
        decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(11)),
        child: const Icon(Icons.menu_book_rounded, size: 19, color: Color(0xFFF3F3E8)),
      ),
      const SizedBox(width: 11),
      const Text('leaf.', style: TextStyle(fontSize: 23, color: _ink, fontWeight: FontWeight.w700, letterSpacing: -1.2)),
      const Spacer(),
      if (!compact) const Text('Made for the joy of reading', style: TextStyle(color: _muted, fontSize: 12)),
      if (!compact) const SizedBox(width: 22),
      TextButton.icon(
        onPressed: _active ? null : () => setState(() {
          _showBackendSettings = !_showBackendSettings;
          _backendNotice = null;
        }),
        icon: Icon(_api.needsBackend ? Icons.cloud_off_outlined : Icons.dns_outlined, size: 16),
        label: Text(compact ? 'API' : 'Server settings', style: const TextStyle(fontSize: 12)),
      ),
      if (!compact) const SizedBox(width: 10),
      if (!compact) const _Pill(label: 'WEB APP', icon: Icons.circle, dot: true),
    ]),
  );

  Widget _hero(bool compact) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('YOUR OFFLINE LIBRARY', style: TextStyle(color: _pine, fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 2.6)),
    const SizedBox(height: 12),
    Text('Good stories,\nbeautifully kept.',
      style: TextStyle(fontFamily: 'Georgia', color: _ink, fontSize: compact ? 39 : 56, height: 1.11, letterSpacing: -1.8)),
    const SizedBox(height: 13),
    ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 515),
      child: const Text('Save the RanobeLIB chapters you can access as a clean EPUB, ready for Apple Books or your favorite reader.',
        style: TextStyle(fontSize: 15, height: 1.7, color: _muted)),
    ),
  ]);

  Widget _backendSettingsCard() => _Surface(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.cloud_outlined, color: _pine, size: 23),
        const SizedBox(width: 11),
        const Expanded(child: Text('Connect the EPUB server',
          style: TextStyle(fontFamily: 'Georgia', fontSize: 20, color: _ink))),
      ]),
      const SizedBox(height: 11),
      const Text(
        'GitHub Pages only hosts the website. To find chapters and create EPUB files, '
        'Leaf also needs its Python backend hosted at an HTTPS address.',
        style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 19),
      const _Label('PYTHON API URL'),
      const SizedBox(height: 8),
      TextField(
        controller: _backendUrl,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enabled: !_connecting && !_active,
        style: const TextStyle(color: _ink, fontSize: 13),
        decoration: const InputDecoration(
          hintText: 'https://your-api.onrender.com',
          prefixIcon: Icon(Icons.link_rounded, size: 18, color: _muted),
        ),
        onSubmitted: (_) => _connectBackend(),
      ),
      const SizedBox(height: 13),
      SizedBox(
        width: double.infinity,
        child: _PrimaryButton(
          text: _connecting ? 'Checking server…' : 'Connect server',
          icon: _connecting ? null : Icons.check_rounded,
          busy: _connecting,
          onPressed: _connecting || _active ? null : _connectBackend,
        ),
      ),
      if (_backendNotice != null) ...[
        const SizedBox(height: 11),
        Text(_backendNotice!, style: const TextStyle(fontSize: 12, color: _ink, height: 1.5)),
      ],
      const SizedBox(height: 13),
      const Text('The server URL is stored in this browser. Do not enter a GitHub Pages URL here.',
        style: TextStyle(fontSize: 11, color: _muted)),
    ]),
  );

  Widget _sourceCard() => _Surface(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _cardHeader('01', 'Find your story', 'Paste a RanobeLIB book link to begin.'),
      const SizedBox(height: 24),
      const _Label('BOOK URL'),
      const SizedBox(height: 9),
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        maxLines: 2,
        minLines: 1,
        enabled: !_loading && !_active,
        style: const TextStyle(fontSize: 13, color: _ink),
        decoration: const InputDecoration(
          hintText: 'https://ranobelib.me/ru/book/...',
          prefixIcon: Icon(Icons.link_rounded, size: 19, color: _muted),
        ),
        onSubmitted: (_) => _inspect(),
      ),
      const SizedBox(height: 13),
      SizedBox(width: double.infinity, child: _PrimaryButton(
        text: _loading ? 'Finding your book…' : _book == null ? 'Find book' : 'Refresh book details',
        icon: _loading ? null : Icons.arrow_forward_rounded,
        busy: _loading,
        onPressed: _loading || _active ? null : _inspect,
      )),
      if (_book != null) ...[
        const SizedBox(height: 27),
        const Divider(color: _line, height: 1),
        const SizedBox(height: 23),
        _bookSummary(_book!),
      ],
    ]),
  );

  Widget _bookSummary(Book book) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _bookCover(book),
    const SizedBox(width: 18),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Pill(label: 'FOUND', icon: Icons.check_circle_outline_rounded),
      const SizedBox(height: 11),
      Text(book.title, maxLines: 5, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: 'Georgia', color: _ink, fontSize: 19, height: 1.32)),
      const SizedBox(height: 9),
      Text(book.author, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: _muted)),
      const SizedBox(height: 13),
      Text('${book.chapterCount} chapters available',
        style: const TextStyle(fontSize: 12, color: _pine, fontWeight: FontWeight.w700)),
    ])),
  ]);

  Widget _bookCover(Book book) => Container(
    width: 105, height: 150,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFFE7EAE0),
      borderRadius: BorderRadius.circular(7),
      boxShadow: const [BoxShadow(color: Color(0x17000000), blurRadius: 15, offset: Offset(0, 7))],
    ),
    child: book.cover == null
        ? const Icon(Icons.auto_stories_rounded, size: 42, color: _pine)
        : Image.network(book.cover!, fit: BoxFit.cover,
            errorBuilder: (context, error, stack) => const Icon(Icons.auto_stories_rounded, size: 42, color: _pine)),
  );

  Widget _optionsCard() => _Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _cardHeader('02', 'Make it yours', 'A few details, then it’s yours to read.'),
    const SizedBox(height: 24),
    const _Label('TRANSLATION'),
    const SizedBox(height: 9),
    DropdownButtonFormField<String>(
      value: _branchId,
      isExpanded: true,
      decoration: const InputDecoration(prefixIcon: Icon(Icons.translate_rounded, size: 19, color: _muted)),
      items: _book!.branches.map((b) => DropdownMenuItem(value: b.id,
        child: Text('${b.label} (${b.count})', overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _ink, fontSize: 13)))).toList(),
      onChanged: _active ? null : (value) => setState(() {
        _branchId = value ?? 'default';
        _start.text = '1';
        _end.text = '$_count';
      }),
    ),
    const SizedBox(height: 23),
    const _Label('CHAPTERS'),
    const SizedBox(height: 9),
    Wrap(spacing: 8, runSpacing: 9, children: [
      _scopeChip('All · $_count', ChapterScope.all),
      _scopeChip('Latest 50', ChapterScope.latest),
      _scopeChip('Choose range', ChapterScope.custom),
    ]),
    if (_scope == ChapterScope.custom) ...[
      const SizedBox(height: 13),
      Row(children: [
        Expanded(child: _rangeField('FROM', _start)),
        const SizedBox(width: 10),
        Expanded(child: _rangeField('TO', _end)),
      ]),
    ],
    const SizedBox(height: 22),
    const Divider(color: _line, height: 1),
    const SizedBox(height: 14),
    _setting('Include cover artwork', 'Use the original novel cover', _cover, (v) => setState(() => _cover = v)),
    _setting('Include illustrations', 'Keep images found in chapters', _images, (v) => setState(() => _images = v)),
    _setting('Reuse chapter cache', 'Speed up future downloads', _cache, (v) => setState(() => _cache = v)),
    const SizedBox(height: 17),
    SizedBox(width: double.infinity, child: _PrimaryButton(
      text: _submitting ? 'Starting export…' : _active ? 'Creating your EPUB…' : 'Create EPUB',
      icon: Icons.auto_stories_rounded,
      busy: _submitting,
      onPressed: (_submitting || _active) ? null : _create,
    )),
    const SizedBox(height: 12),
    const Center(child: Text('EPUB  ·  Apple Books  ·  Offline reading',
      style: TextStyle(color: _muted, fontSize: 11))),
  ]));

  Widget _introCard() => _Surface(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 11),
      const Icon(Icons.menu_book_outlined, color: _pine, size: 31),
      const SizedBox(height: 22),
      const Text('Your reading ritual, simplified.',
        style: TextStyle(fontFamily: 'Georgia', fontSize: 23, color: _ink, height: 1.3)),
      const SizedBox(height: 13),
      const Text('Choose a translation, select your chapters, and save one beautifully organized book.',
        style: TextStyle(color: _muted, height: 1.7, fontSize: 13)),
      const SizedBox(height: 32),
      const _Feature(icon: Icons.layers_outlined, label: 'Chapters, neatly organized'),
      const SizedBox(height: 17),
      const _Feature(icon: Icons.image_outlined, label: 'Covers & illustrations'),
      const SizedBox(height: 17),
      const _Feature(icon: Icons.bookmark_border_rounded, label: 'A real EPUB, not screenshots'),
      const SizedBox(height: 11),
    ]),
  );

  Widget _scopeChip(String text, ChapterScope scope) {
    final selected = _scope == scope;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _active ? null : () => setState(() => _scope = scope),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEAF0E8) : const Color(0xFFF7F8F3),
          border: Border.all(color: selected ? const Color(0xFFA7BBAA) : _line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected) ...[const Icon(Icons.check_rounded, size: 14, color: _pine), const SizedBox(width: 5)],
          Text(text, style: TextStyle(fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? _pine : _ink)),
        ]),
      ),
    );
  }

  Widget _rangeField(String title, TextEditingController controller) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(color: _muted, fontWeight: FontWeight.w600, fontSize: 10, letterSpacing: 1.2)),
      const SizedBox(height: 7),
      TextField(controller: controller, keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(hintText: '1 – $_count'),
        style: const TextStyle(fontSize: 13, color: _ink)),
    ],
  );

  Widget _setting(String title, String caption, bool value, ValueChanged<bool> onChanged) =>
    Row(children: [
      Expanded(child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: _ink, fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 3),
          Text(caption, style: const TextStyle(color: _muted, fontSize: 11)),
        ]),
      )),
      Switch.adaptive(value: value, onChanged: _active ? null : onChanged,
        activeColor: _pine, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ]);

  Widget _jobCard() {
    final job = _job!;
    final finished = job.status == 'complete';
    final failed = job.status == 'error';
    final canceled = job.status == 'canceled';
    final progress = job.total == 0 ? null : job.progress / job.total;
    return _Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(height: 36, width: 36,
          decoration: BoxDecoration(color: const Color(0xFFECF1E9), borderRadius: BorderRadius.circular(10)),
          child: Icon(finished ? Icons.check_rounded : failed ? Icons.error_outline :
            canceled ? Icons.block_outlined : Icons.hourglass_bottom_rounded, color: _pine, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(finished ? 'Your book is ready' : failed ? 'Export interrupted' :
            canceled ? 'Export canceled' : 'Preparing your book',
            style: const TextStyle(fontSize: 17, fontFamily: 'Georgia', color: _ink)),
          const SizedBox(height: 5),
          Text(job.stage, style: const TextStyle(fontSize: 12, color: _muted)),
        ])),
        if (_active) Text('${job.progress}/${job.total == 0 ? '…' : job.total}',
          style: const TextStyle(color: _pine, fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
      if (_active) ...[
        const SizedBox(height: 21),
        ClipRRect(borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: progress, minHeight: 7,
            backgroundColor: const Color(0xFFE8EDE7), color: _pine)),
        const SizedBox(height: 13),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: _cancel,
          icon: const Icon(Icons.close_rounded, size: 17),
          label: const Text('Cancel export'),
        )),
      ],
      if (failed) ...[
        const SizedBox(height: 16),
        Text(job.error ?? 'Could not create EPUB. Try again.',
          style: const TextStyle(color: Color(0xFF9D4E42), fontSize: 12)),
      ],
      if (finished) ...[
        const SizedBox(height: 20),
        SizedBox(width: double.infinity, child: _PrimaryButton(
          text: 'Download EPUB', icon: Icons.download_rounded, onPressed: _download)),
        const SizedBox(height: 9),
        const Text('On iPhone: save to Files, then Share → Books.',
          style: TextStyle(color: _muted, fontSize: 11)),
      ],
    ]));
  }

  Widget _errorNotice(String message) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: const Color(0xFFF9EDE7),
      border: Border.all(color: const Color(0xFFF1D6CA)), borderRadius: BorderRadius.circular(12)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.info_outline_rounded, color: Color(0xFF9D4E42), size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(message, style: const TextStyle(color: Color(0xFF80443B), fontSize: 12, height: 1.5))),
    ]),
  );

  Widget _cardHeader(String number, String title, String subtitle) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(width: 32, height: 32, alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFFE9EEE8), borderRadius: BorderRadius.circular(9)),
        child: Text(number, style: const TextStyle(color: _pine, fontWeight: FontWeight.w700, fontSize: 12))),
      const SizedBox(width: 11),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontFamily: 'Georgia', color: _ink, fontSize: 21)),
        const SizedBox(height: 5),
        Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12)),
      ])),
    ],
  );

  Widget _footer(bool compact) => Column(children: [
    const Divider(color: _line, height: 1),
    const SizedBox(height: 20),
    compact
        ? const Column(children: [
            Text('leaf.  ·  made for readers', style: TextStyle(color: _muted, fontSize: 11)),
            SizedBox(height: 7),
            Text('Powered by open-source RanobeLIB Downloader',
              textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 10)),
          ])
        : const Row(children: [
            Text('leaf.  ·  made for readers', style: TextStyle(color: _muted, fontSize: 11)),
            Spacer(),
            Text('Powered by open-source RanobeLIB Downloader', style: TextStyle(color: _muted, fontSize: 11)),
          ]),
  ]);
}

class _Surface extends StatelessWidget {
  final Widget child;
  const _Surface({required this.child});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 470 ? 21 : 28),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _line),
      boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 30, offset: Offset(0, 9))],
    ),
    child: child,
  );
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool dot;
  const _Pill({required this.label, required this.icon, this.dot = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(color: const Color(0xFFEBF0E9), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _pine, size: dot ? 6 : 13),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: _pine, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.7)),
    ]),
  );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
    style: const TextStyle(color: _muted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5));
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Feature({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, color: _pine, size: 19),
    const SizedBox(width: 11),
    Flexible(child: Text(label, style: const TextStyle(color: _ink, fontSize: 13))),
  ]);
}

class _PrimaryButton extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  const _PrimaryButton({required this.text, required this.onPressed, this.icon, this.busy = false});
  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: _ink, foregroundColor: Colors.white,
      disabledBackgroundColor: const Color(0xFFB6BDB6),
      minimumSize: const Size(100, 51),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
      if (busy) ...[
        const SizedBox(width: 15, height: 15,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 11),
      ],
      Text(text),
      if (icon != null) ...[const SizedBox(width: 10), Icon(icon, size: 17)],
    ]),
  );
}
