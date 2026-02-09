import 'package:flutter/material.dart';
import 'package:kilvish/firestore_recoveries.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/recovery_detail_screen.dart';
import 'package:kilvish/common_widgets.dart';

/// Deep link handler for kilvish:// URLs
/// Supports: kilvish://recovery/{recoveryId}
class DeepLinkHandler {
  static Future<void> handleDeepLink(BuildContext context, String link) async {
    final uri = Uri.parse(link);

    if (uri.scheme != 'kilvish') {
      print('Unknown scheme: ${uri.scheme}');
      return;
    }

    final path = uri.host;
    final segments = uri.pathSegments;

    try {
      switch (path) {
        case 'recovery':
          if (segments.isEmpty) {
            showError(context, 'Invalid recovery link');
            return;
          }
          await _handleRecoveryLink(context, segments[0]);
          break;

        default:
          print('Unknown deep link path: $path');
      }
    } catch (e) {
      print('Error handling deep link: $e');
      if (context.mounted) {
        showError(context, 'Failed to open link');
      }
    }
  }

  static Future<void> _handleRecoveryLink(BuildContext context, String recoveryId) async {
    try {
      // Get current user
      final userId = await getUserIdFromClaim();
      if (userId == null) {
        if (context.mounted) {
          showError(context, 'Please log in first');
        }
        return;
      }

      // Add user to recovery
      await addUserToRecovery(recoveryId, userId);

      // Load recovery data
      final recovery = await getRecoveryData(recoveryId, includeMostRecentExpense: true);

      // Navigate to recovery detail
      if (context.mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (context) => RecoveryDetailScreen(recovery: recovery)));
      }
    } catch (e) {
      print('Error handling recovery link: $e');
      if (context.mounted) {
        showError(context, 'Failed to access recovery');
      }
    }
  }

  /// Generate shareable recovery link
  static String generateRecoveryLink(String recoveryId) {
    return 'kilvish://recovery/$recoveryId';
  }
}
