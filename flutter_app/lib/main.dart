// Leaf — Flutter Web-only EPUB maker. No server, API keys, or Python.
import 'dart:async';
import 'dart:html' as browser;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/epub_builder.dart';
import 'core/local_importer.dart';
import 'core/ranobe_client.dart';

const _paper = Color(0xFFF8F7F2);
const _ink = Color(0xFF2B352F);
const _green = Color(0xFF3D634F);
const _muted = Color(0xFF788279);
const _line = Color(0xFFE2E6DD);
const _originalUrl =
    'https://ranobelib.me/ru/book/202399--okiraku-ryoushu-no-tanoshii-ryouchi-bouei-seisan-kei-majutsu-de-na-mo-naki-mura-wo-saikyou-no-jousai-toshi-ni';

void main() => runApp(const LeafApp());

class LeafApp extends StatelessWidget {
  const LeafApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Leaf — Your books, offline',
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _paper,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, surface: _paper),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _line),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _green, width: 1.6),
          borderRadius: BorderRadius.circular(12),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    home: const LeafHome(),
  );
}

enum InputMode { link, files }
enum ChapterMode { all, latest, range }

class LeafHome extends StatefulWidget {
  const LeafHome({super.key});
  @override
  State<LeafHome> createState() => _LeafHomeState();
}

class _LeafHomeState extends State<LeafHome> {
  final RanobeClient _client = RanobeClient();
  final TextEditingController _url = TextEditingController(text: _originalUrl);
  final TextEditingController _title = TextEditingController(text: 'My offline book');
  final TextEditingController _author = TextEditingController(text: '');
  final TextEditingController _from = TextEditingController(text: '1');
  final TextEditingController _to = TextEditingController();

  InputMode _mode = InputMode.files;
  ChapterMode _chapterMode = ChapterMode.all;
  Novel? _novel;
  List<BookChapter> _imported = [];
  String _branch = 'auto';
  String? _notice;
  bool _busy = false;
  bool _cancelRequested = false;
  int _progress = 0;
  int _total = 0;
  String _stage = '';

  @override
  void dispose() {
    _client.close();
    _url.dispose();
    _title.dispose();
    _author.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  int get _chapterCount => _novel == null
      ? 0 : _client.chaptersFor(_novel!, _branch).length;

  Future<void> _inspect() async {
    if (_busy) return;
    setState(() { _busy = true; _notice = null; _stage = 'Looking up book…'; });
    try {
      final book = await _client.inspect(_url.text.trim());
      if (!mounted) return;
      setState(() {
        _novel = book;
        _branch = 'auto';
        _title.text = book.title;
        _author.text = book.author;
        _from.text = '1';
        _to.text = book.chapters.length.toString();
        _notice = 'Found ' + book.chapters.length.toString() + ' public chapters.';
      });
    } catch (error) {
      if (mounted) setState(() { _novel = null; _notice = _errorText(error); });
    } finally {
      if (mounted) setState(() { _busy = false; _stage = ''; });
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() { _notice = null; _busy = true; _stage = 'Reading local files…'; });
    try {
      final result = await LocalImporter.chooseChapters();
      if (!mounted) return;
      if (result.isEmpty) {
        setState(() { _notice = 'No chapters selected.'; });
        return;
      }
      setState(() {
        _imported = [..._imported, ...result];
        if (_title.text == 'My offline book') {
          _title.text = 'My collected chapters';
        }
        _notice = 'Added ' + result.length.toString() +
            ' chapters locally. No files were uploaded.';
      });
    } catch (error) {
      if (mounted) setState(() { _notice = _errorText(error); });
    } finally {
      if (mounted) setState(() { _busy = false; _stage = ''; });
    }
  }

  String _errorText(Object error) {
    if (error is RanobeException) return error.message;
    if (error is FormatException) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _createEpub() async {
    if (_busy) return;
    final source = _mode;
    final book = _novel;
    final available = source == InputMode.files
        ? _imported.length : (book == null ? 0 : _chapterCount);
    if (available == 0) {
      setState(() => _notice = source == InputMode.files
          ? 'Import some chapters first.' : 'Find a book first.');
      return;
    }
    var start = 1;
    var end = available;
    if (source == InputMode.link && _chapterMode == ChapterMode.latest) {
      start = (available - 49).clamp(1, available);
    } else if (source == InputMode.link && _chapterMode == ChapterMode.range) {
      start = int.tryParse(_from.text) ?? 0;
      end = int.tryParse(_to.text) ?? 0;
      if (start < 1 || end < start || end > available) {
        setState(() => _notice = 'Select chapter numbers between 1 and ' +
            available.toString() + '.');
        return;
      }
    }
    setState(() {
      _busy = true; _cancelRequested = false; _notice = null;
      _progress = 0; _total = end - start + 1;
      _stage = source == InputMode.files ? 'Formatting chapters…' : 'Loading chapters…';
    });

    try {
      final selected = <BookChapter>[];
      if (source == InputMode.files) {
        selected.addAll(_imported);
        if (mounted) setState(() => _progress = selected.length);
      } else {
        final chapters = _client.chaptersFor(book!, _branch)
            .sublist(start - 1, end);
        for (final chapter in chapters) {
          if (_cancelRequested) throw const RanobeException('Export canceled.');
          final html = await _client.fetchChapter(book, chapter, _branch);
          selected.add(BookChapter(chapter.title, html));
          if (mounted) setState(() => _progress = selected.length);
          if (selected.length < chapters.length) {
            // Gentle request pacing; no parallel hammering of the source API.
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      }

      if (_cancelRequested) throw const RanobeException('Export canceled.');
      if (mounted) setState(() => _stage = 'Packaging EPUB…');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final bytes = EpubBuilder.build(
        title: _title.text,
        author: _author.text,
        chapters: selected,
      );
      if (_cancelRequested) throw const RanobeException('Export canceled.');
      _save(EpubBuilder.safeFilename(_title.text), bytes);
      if (mounted) setState(() {
        _notice = 'EPUB created entirely on your device (' +
            selected.length.toString() + ' chapters). Check Downloads.';
        _stage = 'Complete';
      });
    } catch (error) {
      if (mounted) setState(() { _notice = _errorText(error); _stage = 'Stopped'; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save(String filename, Uint8List bytes) {
    final blob = browser.Blob([bytes], 'application/epub+zip');
    final objectUrl = browser.Url.createObjectUrlFromBlob(blob);
    final link = browser.AnchorElement(href: objectUrl)
      ..download = filename
      ..style.display = 'none';
    browser.document.body?.append(link);
    link.click();
    link.remove();
    Future<void>.delayed(const Duration(seconds: 3), () {
      browser.Url.revokeObjectUrl(objectUrl);
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final mainColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: 50),
        _heading(compact),
        const SizedBox(height: 31),
        _modePicker(),
        const SizedBox(height: 22),
        _sourcePanel(),
        const SizedBox(height: 22),
        if (_hasContent) _metadataPanel(),
        if (_hasContent) const SizedBox(height: 22),
        _explainPanel(),
        if (_notice != null) ...[
          const SizedBox(height: 18),
          _noticePanel(_notice!),
        ],
        if (_busy || _total > 0) ...[
          const SizedBox(height: 18),
          _progressPanel(),
        ],
        const SizedBox(height: 46),
        const Divider(color: _line),
        const SizedBox(height: 14),
        const Text('leaf.  ·  EPUBs made privately in your browser',
          style: TextStyle(color: _muted, fontSize: 12)),
      ],
    );
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(compact ? 18 : 40, 0, compact ? 18 : 40, 46),
          child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: mainColumn,
          )),
        ),
      ),
    );
  }

  bool get _hasContent => _mode == InputMode.files
      ? _imported.isNotEmpty : _novel != null;

  Widget _header() => Container(
    padding: const EdgeInsets.symmetric(vertical: 22),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
    child: Row(children: [
      Container(
        width: 38, height: 38,
        decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(11)),
        child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 20),
      ),
      const SizedBox(width: 12),
      const Text('leaf.', style: TextStyle(
          fontSize: 25, fontWeight: FontWeight.w700, color: _ink, letterSpacing: -1)),
      const Spacer(),
      const Icon(Icons.lock_outline_rounded, color: _green, size: 16),
      const SizedBox(width: 6),
      const Text('100% browser-only', style: TextStyle(color: _green, fontSize: 12)),
    ]),
  );

  Widget _heading(bool compact) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('THE PERSONAL BOOKMAKER', style: TextStyle(
        color: _green, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 2.4)),
    const SizedBox(height: 11),
    Text('Keep good stories.\nRead anywhere.',
      style: TextStyle(
        fontFamily: 'Georgia', color: _ink, height: 1.13,
        letterSpacing: -1.8, fontSize: compact ? 39 : 55,
      )),
    const SizedBox(height: 13),
    const Text('Turn accessible chapters or your own text files into a clean, organized EPUB.',
      style: TextStyle(color: _muted, fontSize: 14, height: 1.6)),
  ]);

  Widget _modePicker() => Wrap(spacing: 10, runSpacing: 10, children: [
    _modeButton('Import files', Icons.upload_file_rounded, InputMode.files),
    _modeButton('RanobeLIB link', Icons.link_rounded, InputMode.link),
  ]);

  Widget _modeButton(String name, IconData icon, InputMode mode) {
    final active = _mode == mode;
    return ChoiceChip(
      selected: active,
      label: Text(name),
      avatar: Icon(icon, size: 18, color: active ? _green : _muted),
      selectedColor: const Color(0xFFE7F0E7),
      side: BorderSide(color: active ? _green : _line),
      onSelected: _busy ? null : (_) => setState(() {
        _mode = mode;
        _notice = null;
        _progress = 0; _total = 0; _stage = '';
      }),
    );
  }

  Widget _sourcePanel() => _surface(Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _panelTitle('01', _mode == InputMode.files ? 'Your chapter files' : 'Find a story'),
      const SizedBox(height: 18),
      if (_mode == InputMode.files) ...[
        const Text('Import TXT, HTML or JSON. Choose one or several chapter files.',
          style: TextStyle(color: _muted, fontSize: 13, height: 1.5)),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: _button(
          'Choose files', Icons.upload_file_rounded, _busy ? null : _import,
        )),
        if (_imported.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(_imported.length.toString() + ' chapters ready',
            style: const TextStyle(color: _green, fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          ..._imported.take(6).map((c) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('• ' + c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 12)),
          )),
          if (_imported.length > 6) Text('… and ' +
              (_imported.length - 6).toString() + ' more',
              style: const TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _busy ? null : () => setState(() { _imported.clear(); _notice = null; }),
            icon: const Icon(Icons.delete_outline_rounded, size: 17),
            label: const Text('Clear files'),
          ),
        ],
      ] else ...[
        const Text('RANOBELIB BOOK URL', style: TextStyle(
            fontSize: 10, color: _muted, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
        const SizedBox(height: 9),
        TextField(
          controller: _url,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          minLines: 1, maxLines: 3,
          style: const TextStyle(fontSize: 12, color: _ink),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.link_rounded, color: _muted)),
          onSubmitted: (_) => _inspect(),
        ),
        const SizedBox(height: 13),
        SizedBox(width: double.infinity, child: _button(
          'Find book', Icons.arrow_forward_rounded, _busy ? null : _inspect,
        )),
        const SizedBox(height: 13),
        const Text(
          'Direct API access is experimental. RanobeLIB currently blocks '
          'third-party browser requests (CORS / HTTP 403). No proxy or backend is used.',
          style: TextStyle(color: _muted, fontSize: 11, height: 1.5),
        ),
        if (_novel != null) ...[
          const SizedBox(height: 16),
          Text(_novel!.title, style: const TextStyle(
            fontFamily: 'Georgia', color: _ink, fontSize: 19)),
          const SizedBox(height: 7),
          Text(_chapterCount.toString() + ' chapters available',
            style: const TextStyle(color: _green, fontSize: 12)),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _branch,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Translation'),
            items: _novel!.branches.entries.map((e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: _busy ? null : (v) => setState(() {
              _branch = v ?? 'auto';
              _to.text = _chapterCount.toString();
            }),
          ),
          const SizedBox(height: 15),
          Wrap(spacing: 7, runSpacing: 7, children: [
            _chapterChip(ChapterMode.all, 'All chapters'),
            _chapterChip(ChapterMode.latest, 'Last 50'),
            _chapterChip(ChapterMode.range, 'Choose range'),
          ]),
          if (_chapterMode == ChapterMode.range) ...[
            const SizedBox(height: 13),
            Row(children: [
              Expanded(child: TextField(
                controller: _from,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'From'),
              )),
              const SizedBox(width: 10),
              Expanded(child: TextField(
                controller: _to,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'To'),
              )),
            ]),
          ],
        ],
      ],
    ],
  ));

  Widget _chapterChip(ChapterMode mode, String label) => ChoiceChip(
    label: Text(label, style: const TextStyle(fontSize: 12)),
    selected: _chapterMode == mode,
    onSelected: _busy ? null : (_) => setState(() => _chapterMode = mode),
  );

  Widget _metadataPanel() => _surface(Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _panelTitle('02', 'Make your EPUB'),
      const SizedBox(height: 17),
      const Text('BOOK TITLE', style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.w700, color: _muted)),
      const SizedBox(height: 7),
      TextField(controller: _title, enabled: !_busy),
      const SizedBox(height: 14),
      const Text('AUTHOR', style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.w700, color: _muted)),
      const SizedBox(height: 7),
      TextField(controller: _author, enabled: !_busy,
          decoration: const InputDecoration(hintText: 'Optional')),
      const SizedBox(height: 21),
      SizedBox(width: double.infinity, child: _button(
        _busy ? 'Working…' : 'Create EPUB',
        Icons.menu_book_rounded, _busy ? null : _createEpub,
      )),
      if (_busy && _mode == InputMode.link) ...[
        const SizedBox(height: 9),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: () => setState(() => _cancelRequested = true),
          icon: const Icon(Icons.close_rounded, size: 16),
          label: const Text('Cancel'),
        )),
      ],
      const SizedBox(height: 9),
      const Text('The file is built on this device and saved to your browser Downloads.',
        style: TextStyle(color: _muted, fontSize: 11, height: 1.5)),
    ],
  ));

  Widget _progressPanel() => _surface(Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(_stage, style: const TextStyle(color: _ink, fontWeight: FontWeight.w600)),
      const SizedBox(height: 9),
      LinearProgressIndicator(
        value: _total <= 0 ? null : _progress / _total,
        minHeight: 5, borderRadius: BorderRadius.circular(9),
        backgroundColor: _line, color: _green,
      ),
      const SizedBox(height: 7),
      Text(_progress.toString() + ' / ' + _total.toString() + ' chapters',
        style: const TextStyle(color: _muted, fontSize: 11)),
    ],
  ));

  Widget _explainPanel() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F3EC),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.shield_outlined, color: _green, size: 20),
      SizedBox(width: 12),
      Expanded(child: Text(
        'No accounts, no backend, no tracking. Imported text stays in the browser. '
        'EPUB is generated locally using Dart. Only save chapters you have permission to use.',
        style: TextStyle(color: _green, fontSize: 12, height: 1.55),
      )),
    ]),
  );

  Widget _noticePanel(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.info_outline_rounded, color: _green, size: 19),
      const SizedBox(width: 11),
      Expanded(child: SelectableText(message,
        style: const TextStyle(color: _ink, fontSize: 12, height: 1.5))),
    ]),
  );

  Widget _panelTitle(String number, String text) => Row(children: [
    Container(
      height: 31, width: 31, alignment: Alignment.center,
      decoration: BoxDecoration(color: const Color(0xFFE5EDE4),
          borderRadius: BorderRadius.circular(9)),
      child: Text(number, style: const TextStyle(
          color: _green, fontWeight: FontWeight.w700, fontSize: 11)),
    ),
    const SizedBox(width: 12),
    Text(text, style: const TextStyle(
        fontFamily: 'Georgia', color: _ink, fontSize: 21)),
  ]);

  Widget _surface(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(23),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _line),
      boxShadow: const [BoxShadow(color: Color(0x09000000),
        blurRadius: 24, offset: Offset(0, 8))],
    ),
    child: child,
  );

  Widget _button(String text, IconData icon, VoidCallback? action) => FilledButton.icon(
    onPressed: action,
    style: FilledButton.styleFrom(
      minimumSize: const Size(10, 51),
      backgroundColor: _ink,
      foregroundColor: Colors.white,
      disabledBackgroundColor: const Color(0xFFADB7AE),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    ),
    icon: Icon(icon, size: 17),
    label: Text(text, style: const TextStyle(fontSize: 13)),
  );
}
