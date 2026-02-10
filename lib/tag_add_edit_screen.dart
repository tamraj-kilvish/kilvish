import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models_tags.dart';
import 'package:kilvish/style.dart';

class TagAddEditScreen extends StatefulWidget {
  Tag? tag;

  TagAddEditScreen({super.key, this.tag});

  @override
  State<TagAddEditScreen> createState() => _TagAddEditScreenState();
}

class _TagAddEditScreenState extends State<TagAddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _tagNameController = TextEditingController();

  bool _isLoading = false;
  bool _allowRecovery = false;

  @override
  void initState() {
    super.initState();
    if (widget.tag != null) {
      _tagNameController.text = widget.tag!.name;
      _allowRecovery = widget.tag!.allowRecovery;
    }
  }

  @override
  void dispose() {
    _tagNameController.dispose();
    super.dispose();
  }

  void _shareTag() {
    if (widget.tag == null) return;

    Clipboard.setData(ClipboardData(text: widget.tag!.link));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Tag link copied to clipboard!'),
        backgroundColor: successcolor,
        duration: Duration(seconds: 2),
        action: SnackBarAction(label: 'OK', textColor: kWhitecolor, onPressed: () {}),
      ),
    );
  }

  Future<void> _showMigrateDialog() async {
    // Get all tags with allowRecovery = true (excluding current recovery tag)
    final allTags = await getUserAccessibleTags();
    final allowRecoveryTags = allTags.where((tag) => tag.allowRecovery && !tag.isRecovery && tag.id != widget.tag!.id).toList();

    if (allowRecoveryTags.isEmpty) {
      if (mounted) {
        showError(context, 'No tags with recovery tracking enabled. Please create or enable recovery on a tag first.');
      }
      return;
    }

    Tag? selectedTag;

    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(
                'Migrate Recovery to Tag',
                style: TextStyle(color: kTextColor, fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: errorcolor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: errorcolor.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning, color: errorcolor, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This action is irreversible. All expenses and settlements will be moved to the selected tag.',
                            style: TextStyle(color: errorcolor, fontSize: smallFontSize),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                    'Select target tag:',
                    style: TextStyle(color: kTextColor, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 12),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: kBorderColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButton<Tag>(
                      value: selectedTag,
                      hint: Text('Choose a tag', style: TextStyle(color: kTextMedium)),
                      isExpanded: true,
                      underline: SizedBox(),
                      items: allowRecoveryTags.map((tag) {
                        return DropdownMenuItem<Tag>(
                          value: tag,
                          child: Row(
                            children: [
                              Icon(Icons.local_offer, size: 16, color: primaryColor),
                              SizedBox(width: 8),
                              Text(tag.name, style: TextStyle(color: kTextColor)),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (Tag? value) {
                        setDialogState(() {
                          selectedTag = value;
                        });
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text('Cancel', style: TextStyle(color: kTextMedium)),
                ),
                ElevatedButton(
                  onPressed: selectedTag == null ? null : () => Navigator.pop(dialogContext, true),
                  style: ElevatedButton.styleFrom(backgroundColor: errorcolor, foregroundColor: kWhitecolor),
                  child: Text('Migrate'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true && selectedTag != null) {
      await _migrateRecoveryToTag(selectedTag!);
    }
  }

  Future<void> _migrateRecoveryToTag(Tag targetTag) async {
    setState(() => _isLoading = true);

    try {
      // Call Cloud Function to migrate
      final callable = FirebaseFunctions.instance.httpsCallable('migrateRecoveryToTag');
      await callable.call({'recoveryId': widget.tag!.id, 'targetTagId': targetTag.id});

      if (mounted) {
        showSuccess(context, 'Successfully migrated to ${targetTag.name}');
        // Pop twice - close this screen and return to home/tag list
        Navigator.pop(context);
        Navigator.pop(context);
      }
    } catch (e) {
      print('Error migrating recovery: $e');
      if (mounted) {
        showError(context, 'Failed to migrate recovery: ${e.toString()}');
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveTag() async {
    if (!_formKey.currentState!.validate()) return;

    final userId = await getUserIdFromClaim();
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    setState(() => _isLoading = true);

    try {
      final Map<String, Object> tagData = {'name': _tagNameController.text.trim(), 'allowRecovery': _allowRecovery};

      Tag? tag = await createOrUpdateTag(tagData, widget.tag?.id);

      if (mounted) {
        showSuccess(context, widget.tag != null ? 'Tag updated successfully' : 'Tag created successfully');
        Navigator.pop(context, tag);
      }
    } catch (e, stackTrace) {
      print('Error saving tag: $e $stackTrace');
      if (mounted) showError(context, 'Failed to save changes');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.tag != null;
    final isRecovery = widget.tag?.isRecovery ?? false;

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: isRecovery ? errorcolor : primaryColor,
        title: appBarTitleText(isEditing ? (isRecovery ? 'Edit Recovery Expense' : 'Edit Tag') : 'Add Tag'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tag/Recovery Name
                    renderPrimaryColorLabel(text: isRecovery ? 'Recovery Name' : 'Tag Name'),
                    SizedBox(height: 8),
                    TextFormField(
                      controller: _tagNameController,
                      decoration: customUnderlineInputdecoration(
                        hintText: isRecovery ? 'e.g., Trip to Goa' : 'e.g., Household, Office, Travel',
                        bordersideColor: isRecovery ? errorcolor : primaryColor,
                      ),
                      validator: (value) {
                        if (value?.isEmpty ?? true) {
                          return 'Please enter ${isRecovery ? 'recovery' : 'tag'} name';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 24),

                    // Recovery checkbox (only for non-recovery tags)
                    if (!isRecovery) ...[
                      CheckboxListTile(
                        title: Text(
                          'Track recovery amounts',
                          style: TextStyle(color: kTextColor, fontSize: defaultFontSize),
                        ),
                        subtitle: Text(
                          'Enable if someone needs to pay you back',
                          style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                        ),
                        value: _allowRecovery,
                        onChanged: (value) {
                          setState(() {
                            _allowRecovery = value ?? false;
                          });
                        },
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      SizedBox(height: 24),
                    ],

                    // Recovery info banner (for recovery tags)
                    if (isRecovery) ...[
                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: errorcolor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: errorcolor.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.account_balance_wallet, color: errorcolor, size: 24),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Recovery Expense',
                                    style: TextStyle(color: errorcolor, fontSize: defaultFontSize, fontWeight: FontWeight.bold),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'This tracks amounts that need to be recovered',
                                    style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 24),
                    ],

                    // Share section (only for existing tags)
                    if (isEditing) ...[
                      Divider(height: 1),
                      SizedBox(height: 24),
                      renderPrimaryColorLabel(text: 'Share This ${isRecovery ? 'Recovery' : 'Tag'}'),
                      SizedBox(height: 8),
                      renderHelperText(text: 'Share this link with others to collaborate'),
                      SizedBox(height: 12),

                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: tileBackgroundColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: kBorderColor),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Shareable Link',
                                    style: TextStyle(color: kTextColor, fontSize: defaultFontSize, fontWeight: FontWeight.w600),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    widget.tag!.link,
                                    style: TextStyle(color: kTextMedium, fontSize: xsmallFontSize),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(width: 12),
                            ElevatedButton.icon(
                              onPressed: _shareTag,
                              icon: Icon(Icons.share, size: 18),
                              label: Text('Share'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isRecovery ? errorcolor : primaryColor,
                                foregroundColor: kWhitecolor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Migration section (only for recovery tags)
                    if (isEditing && isRecovery) ...[
                      SizedBox(height: 24),
                      Divider(height: 1),
                      SizedBox(height: 24),
                      renderPrimaryColorLabel(text: 'Migration'),
                      SizedBox(height: 8),
                      renderHelperText(text: 'Move this recovery expense to a regular tag with recovery tracking'),
                      SizedBox(height: 12),

                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: tileBackgroundColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: kBorderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Migrate to Tag',
                              style: TextStyle(color: kTextColor, fontSize: defaultFontSize, fontWeight: FontWeight.w600),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Convert this recovery expense into a regular tag. All expenses and settlements will be preserved.',
                              style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                            ),
                            SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _showMigrateDialog,
                                icon: Icon(Icons.transform, size: 18),
                                label: Text('Migrate to Tag'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: kWhitecolor,
                                  foregroundColor: errorcolor,
                                  side: BorderSide(color: errorcolor),
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton(
          isEditing ? (isRecovery ? 'Update Recovery' : 'Update Tag') : 'Create Tag',
          _isLoading ? null : _saveTag,
          !_isLoading,
        ),
      ),
    );
  }
}
