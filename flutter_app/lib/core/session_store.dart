import 'dart:convert';
import 'dart:html' as browser;
import 'dart:indexed_db' as idb;

/// The last reading job, saved locally. Metadata and chapter bodies are read
/// and written atomically so two open Leaf tabs cannot mix different books.
class SessionStore {
  Future<idb.Database>? _database;
  Future<void> _writes = Future<void>.value();

  Future<idb.Database> _open() {
    final existing = _database;
    if (existing != null) return existing;
    final factory = browser.window.indexedDB;
    if (factory == null)
      return Future.error(StateError('Local storage is unavailable.'));
    return _database =
        factory.open('leaf-reading-v3', version: 1, onUpgradeNeeded: (event) {
      final database = (event.target as idb.Request).result as idb.Database;
      database.createObjectStore('jobs');
    }).catchError((Object error) {
      _database = null;
      throw error;
    });
  }

  Future<Map<String, dynamic>?> read() async {
    await _writes.catchError((_) {});
    final database = await _open();
    final transaction = database.transaction('jobs', 'readonly');
    final completed = transaction.completed;
    final store = transaction.objectStore('jobs');
    final value = await store.getObject('current');
    if (value is! String) {
      await completed;
      return null;
    }
    final parsed = jsonDecode(value);
    if (parsed is! Map || parsed['version'] != 3) {
      await completed;
      return null;
    }
    final metadata = Map<String, dynamic>.from(parsed);
    if (metadata['chapters'] is List) {
      await completed;
      return metadata;
    }
    final count = metadata['chapterCount'];
    if (count is! int || count < 0 || count > 500) {
      await completed;
      return null;
    }
    // Keep the same readonly transaction until all chapter requests finish.
    final rows = await Future.wait(
        List.generate(count, (index) => store.getObject('chapter:$index')));
    await completed;
    if (rows.any((row) => row is! String)) return null;
    metadata['chapters'] =
        rows.map((row) => jsonDecode(row as String)).toList();
    return metadata;
  }

  Future<void> save(Map<String, dynamic> snapshot) {
    final metadata = Map<String, dynamic>.from(snapshot);
    final chapters = List<dynamic>.of(metadata.remove('chapters') as List);
    final jobId = metadata['jobId'] as String;
    metadata['chapterCount'] = chapters.length;
    final value = jsonEncode(metadata);
    final next = _writes.catchError((_) {}).then((_) async {
      final database = await _open();
      final transaction = database.transaction('jobs', 'readwrite');
      final completed = transaction.completed;
      final store = transaction.objectStore('jobs');
      final current = await store.getObject('current');
      final previous = current is String ? jsonDecode(current) : null;
      final sameJob = previous is Map && previous['jobId'] == jobId;
      final savedCount = sameJob && previous['chapterCount'] is int
          ? previous['chapterCount'] as int
          : 0;
      // A second tab resuming the same job cannot replace a newer prefix.
      if (sameJob && savedCount > chapters.length) {
        await completed;
        return;
      }
      final requests = <Future>[];
      if (!sameJob) requests.add(store.clear());
      // Append only new chapter bodies. Rewriting all text on every checkpoint
      // would make large books quadratic in memory copying and disk writes.
      for (var i = savedCount; i < chapters.length; i++) {
        requests.add(store.put(jsonEncode(chapters[i]), 'chapter:$i'));
      }
      requests.add(store.put(value, 'current'));
      await Future.wait(requests);
      await completed;
    });
    _writes = next;
    return next;
  }
}
