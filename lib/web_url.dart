// Conditional export: picks the web implementation when dart:js_interop is
// available (i.e. when compiled for the browser), otherwise falls back to the
// no-op stub for mobile/desktop.
export 'web_url_stub.dart' if (dart.library.js_interop) 'web_url_web.dart';