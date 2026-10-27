/// Preserve line comments and non-ASCII text. Removing newlines from a script
/// with // comments turns the rest of the collector into one broken comment.
String captureBookmarklet(String source, {String? jobJson}) {
  final script = jobJson == null
      ? source
      : '(function(){window.__leafOfflineJobV2=$jobJson;$source\n})();';
  return 'javascript:${Uri.encodeComponent(script)}';
}
