import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models_tags.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles deep links for Kilvish app
/// Supports: kilvish://tag/{tagId}
class DeepLinkHandler {
  static const String _pendingTagKey = 'pending_deep_link_tag_id';

  /// Main entry point for handling deep links
  static Future<void> handleDeepLink(BuildContext context, Uri uri) async {
    if (uri.scheme != 'kilvish') return;

    if (uri.host == 'tag' && uri.pathSegments.isNotEmpty) {
      final tagId = uri.pathSegments[0];
      await _handleTagDeepLink(context, tagId);
    }
  }

  /// Handle tag deep link: kilvish://tag/{tagId}
  static Future<void> _handleTagDeepLink(BuildContext context, String tagId) async {
    print('Handling tag deep link: $tagId');

    // 1. Check if user is authenticated
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print('User not authenticated, saving pending tag and showing login');
      await _savePendingTag(tagId);
      // User will be redirected to signup/login screen by main flow
      // After login, checkAndHandlePendingDeepLink() will be called
      return;
    }

    // 2. Check if user already has access to this tag
    final userData = await getLoggedInUserData();
    if (userData == null) {
      if (context.mounted) {
        showError(context, 'Unable to load user data');
      }
      return;
    }

    if (!userData.accessibleTagIds.contains(tagId)) {
      print('User does not have access to tag $tagId, adding');
      await _addUserToTag(tagId, userData.id);
    }

    if (context.mounted) {
      Tag tag = await getTagData(tagId);
      Navigator.push(context, MaterialPageRoute(builder: (_) => TagDetailScreen(tag: tag)));
    }

    // // 3. User doesn't have access - call Cloud Function to join
    // print('User does not have access, calling joinTagViaDeepLink');
    // await _joinTagAndNavigate(context, tagId);
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

  /// Call Cloud Function to join tag and navigate
  static Future<void> _joinTagAndNavigate(BuildContext context, String tagId) async {
    try {
      // Show loading
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => Center(child: CircularProgressIndicator()),
        );
      }

      final functions = FirebaseFunctions.instanceFor(region: 'asia-south1');
      final callable = functions.httpsCallable('joinTagViaDeepLink');
      final result = await callable.call({'tagId': tagId});

      print('Successfully joined tag: ${result.data}');

      // Close loading dialog
      if (context.mounted) {
        Navigator.pop(context);
      }

      // Navigate to tag
      if (context.mounted) {
        Tag tag = await getTagData(tagId);
        Navigator.push(context, MaterialPageRoute(builder: (_) => TagDetailScreen(tag: tag)));
      }
    } catch (e) {
      print('Error joining tag: $e');

      // Close loading dialog
      if (context.mounted) {
        Navigator.pop(context);
      }

      if (context.mounted) {
        showError(context, 'Unable to join tag: ${e.toString()}');
      }
    }
  }

  /// Save pending tag ID for after login
  static Future<void> _savePendingTag(String tagId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingTagKey, tagId);
    print('Saved pending tag: $tagId');
  }

  /// Check and handle pending deep link after successful login
  static Future<void> checkAndHandlePendingDeepLink(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final pendingTagId = prefs.getString(_pendingTagKey);

    if (pendingTagId != null) {
      print('Found pending tag after login: $pendingTagId');

      // Clear the pending tag
      await prefs.remove(_pendingTagKey);

      await _handleTagDeepLink(context, pendingTagId);
    }
  }

  /// Generate shareable deep link for a tag
  static String generateTagLink(String tagId) {
    return 'kilvish://tag/$tagId';
  }
}
