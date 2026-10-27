import 'dart:async';
import 'dart:convert';
import 'dart:html' as browser;

import 'epub_builder.dart';
import 'ranobe_client.dart';

/// Reads only files explicitly chosen by the user. No uploads or server storage.
class LocalImporter {
  static Future<List<BookChapter>> chooseChapters() async {
    final input = browser.FileUploadInputElement()
      ..accept = '.txt,.html,.htm,.json'
      ..multiple = true;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return [];
    final ordered = files.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final chapters = <BookChapter>[];
    for (final file in ordered) {
      final reader = browser.FileReader();
      reader.readAsText(file, 'UTF-8');
      await reader.onLoadEnd.first;
      if (reader.error != null) {
        throw FormatException('Cannot read ' + file.name);
      }
      final data = reader.result;
      if (data is! String) {
        throw FormatException('Cannot decode ' + file.name + ' as UTF-8');
      }
      final filename = file.name;
      final ext = filename.split('.').last.toLowerCase();
      final label = filename.replaceFirst(RegExp(r'\.[^.]+$'), '');
      if (ext == 'json') {
        chapters.addAll(_fromJson(data, label));
      } else if (ext == 'html' || ext == 'htm') {
        chapters.add(BookChapter(label, data));
      } else if (ext == 'txt') {
        chapters.add(BookChapter(label, textToHtml(data)));
      }
    }
    return chapters;
  }

  static List<BookChapter> _fromJson(String source, String fallback) {
    dynamic data;
    try {
      data = jsonDecode(source);
    } catch (_) {
      throw FormatException('Invalid JSON: ' + fallback);
    }
    if (data is Map && data.containsKey('data')) data = data['data'];
    if (data is Map && data['chapters'] is List) {
      final result = <BookChapter>[];
      for (final chapter in data['chapters'] as List) {
        if (chapter is! Map) continue;
        final title = (chapter['title'] ?? chapter['name'] ??
            'Chapter ' + (result.length + 1).toString()).toString();
        result.add(BookChapter(title, _chapterHtml(chapter)));
      }
      return result;
    }
    if (data is List) {
      final result = <BookChapter>[];
      for (final chapter in data) {
        if (chapter is Map) {
          final title = (chapter['title'] ?? chapter['name'] ??
              'Chapter ' + (result.length + 1).toString()).toString();
          result.add(BookChapter(title, _chapterHtml(chapter)));
        }
      }
      if (result.isNotEmpty) return result;
    }
    if (data is Map) {
      return [BookChapter(
          (data['title'] ?? data['name'] ?? fallback).toString(), _chapterHtml(data))];
    }
    throw FormatException('Expected a chapter, array, or {"chapters": [...]} in ' + fallback);
  }

  static String _chapterHtml(Map chapter) {
    final content = chapter['html'] ?? chapter['content'] ?? chapter['text'];
    if (content is String) {
      if (RegExp(r'<[a-zA-Z][^>]*>').hasMatch(content)) return content;
      return textToHtml(content);
    }
    if (content is Map && content['type'] == 'doc' && content['content'] is List) {
      return documentNodesToHtml(content['content'] as List);
    }
    return '<p>No chapter text found.</p>';
  }

  static String textToHtml(String text) {
    final cleaned = text.replaceAll('\r\n', '\n').trim();
    if (cleaned.isEmpty) return '<p> </p>';
    final paragraphs = cleaned.split(RegExp(r'\n\s*\n+'));
    return paragraphs.map((p) => '<p>' +
        escapeXml(p.trim()).replaceAll('\n', '<br/>') + '</p>').join('\n');
  }
}
