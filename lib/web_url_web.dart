// Web implementation — updates the browser address bar without adding a
// browser history entry (replaceState, not pushState).
//
// Prepends the <base href> from index.html so the path is correct when the
// app is deployed at a sub-path (e.g. kilvish.com/app/).
import 'package:web/web.dart' as web;

void setWebUrl(String path) {
  final base = web.document.head?.querySelector('base')?.getAttribute('href') ?? '/';
  // Trim trailing slash so we can safely concatenate with path (which starts with '/').
  final trimmedBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  web.window.history.replaceState(null, '', '$trimmedBase$path');
}