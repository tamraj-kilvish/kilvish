import 'package:flutter/foundation.dart';
import 'package:share_handler/share_handler.dart';

class ShareService extends ChangeNotifier {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  SharedMedia? _pendingMedia;
  SharedMedia? get pendingMedia => _pendingMedia;

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    final handler = ShareHandlerPlatform.instance;

    // Cold launch: read share data captured by the extension before runApp().
    final initialMedia = await handler.getInitialSharedMedia();
    if (initialMedia != null) {
      _pendingMedia = initialMedia;
      notifyListeners();
    }

    // Warm launch / background: stream fires when app is already running.
    handler.sharedMediaStream.listen((SharedMedia media) {
      _pendingMedia = media;
      notifyListeners();
    });
  }

  void clearPendingMedia() {
    _pendingMedia = null;
  }
}
