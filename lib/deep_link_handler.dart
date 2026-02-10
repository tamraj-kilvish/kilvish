import 'package:flutter/material.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Deep link handler for kilvish:// URLs
/// Supports: kilvish://tag/{tagId}
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
        case 'tag':
          if (segments.isEmpty) {
            showError(context, 'Invalid tag link');
            return;
          }
          await _handleTagLink(context, segments[0]);
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

  static Future<void> _handleTagLink(BuildContext context, String tagId) async {
    try {
      // Get current user
      final userId = await getUserIdFromClaim();
      if (userId == null) {
        if (context.mounted) {
          showError(context, 'Please log in first');
        }
        return;
      }

      // Add user to tag
      await _addUserToTag(tagId, userId);

      // Load tag data
      final tag = await getTagData(tagId, includeMostRecentExpense: true);

      // Navigate to tag detail
      if (context.mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));
      }
    } catch (e) {
      print('Error handling tag link: $e');
      if (context.mounted) {
        showError(context, 'Failed to access tag');
      }
    }
  }

  static Future<void> _addUserToTag(String tagId, String userId) async {
    WriteBatch batch = FirebaseFirestore.instance.batch();

    batch.update(FirebaseFirestore.instance.collection('Tags').doc(tagId), {
      'sharedWith': FieldValue.arrayUnion([userId]),
    });

    batch.update(FirebaseFirestore.instance.collection('Users').doc(userId), {
      'accessibleTagIds': FieldValue.arrayUnion([tagId]),
    });

    await batch.commit();

    // Invalidate cache
    tagIdTagDataCache.remove(tagId);
  }

  /// Generate shareable tag link
  static String generateTagLink(String tagId) {
    return 'kilvish://tag/$tagId';
  }
}
