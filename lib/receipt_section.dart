import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/bulk_import_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'style.dart';

class ReceiptSection extends StatefulWidget {
  final BaseExpense expense;
  final bool isOwner;
  final bool isExpenseEdit;
  final Future<void> Function()? onMainReceiptRemoved;

  const ReceiptSection({
    super.key,
    required this.expense,
    required this.isOwner,
    required this.isExpenseEdit,
    this.onMainReceiptRemoved,
  });

  @override
  State<ReceiptSection> createState() => _ReceiptSectionState();
}

class _ReceiptSectionState extends State<ReceiptSection> {
  final ImagePicker _picker = ImagePicker();

  String? _mainReceiptUrl;
  File? _receiptImage;
  Uint8List? _webImageBytes;
  bool _isWebUploadingMain = false;

  List<String> _otherReceiptUrls = [];
  final Set<int> _uploadingIndices = {};
  final List<String> _viewingOtherReceiptUrls = [];

  @override
  void initState() {
    super.initState();
    if (widget.isExpenseEdit) {
      _mainReceiptUrl = widget.expense.receiptUrl;
      _receiptImage = widget.expense.localReceiptPath != null ? File(widget.expense.localReceiptPath!) : null;
    }
    _otherReceiptUrls = List.from(widget.expense.otherReceiptUrls);
  }

  bool get _isProcessingMainReceipt {
    if (widget.expense is! WIPExpense) return false;
    final wip = widget.expense as WIPExpense;
    return [ExpenseStatus.extractingData, ExpenseStatus.uploadingReceipt].contains(wip.status) &&
        wip.errorMessage == null;
  }

  String get _mainReceiptProcessingText =>
      widget.expense is WIPExpense ? (widget.expense as WIPExpense).getStatusDisplayText() : '';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMainReceiptSection(),
        _buildAdditionalImagesSection(),
      ],
    );
  }

  Widget _buildMainReceiptSection() {
    if (!widget.isExpenseEdit && widget.expense.receiptUrl == null) return const SizedBox.shrink();
    final hasReceipt = _mainReceiptUrl != null || _receiptImage != null;
    final section = buildReceiptSection(
      initialText: widget.isExpenseEdit ? 'Tap to upload receipt' : 'Tap to load receipt',
      processingText: _mainReceiptProcessingText,
      mainFunction: widget.isExpenseEdit ? _showImageSourceOptions : _lazyLoadMainReceipt,
      isProcessingImage: _isProcessingMainReceipt,
      receiptImage: _receiptImage,
      receiptUrl: _mainReceiptUrl,
      webImageBytes: _webImageBytes,
      onCloseFunction: widget.isExpenseEdit && hasReceipt ? _removeMainReceipt : null,
    );
    if (!_isWebUploadingMain) return section;
    return Stack(
      children: [
        section,
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 10),
                Text('Uploading...', style: TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAdditionalImagesSection() {
    final bool canAdd = widget.isExpenseEdit;
    final bool canRemove = widget.isExpenseEdit;
    final visibleTileEntries = _otherReceiptUrls.asMap().entries
        .where((e) =>
            (_uploadingIndices.contains(e.key) || e.value.startsWith('https://')) &&
            !_viewingOtherReceiptUrls.contains(e.value))
        .toList();

    if (_otherReceiptUrls.isEmpty && !canAdd) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        for (final url in _viewingOtherReceiptUrls) ...[
          buildReceiptSection(
            initialText: '',
            processingText: '',
            mainFunction: () {},
            isProcessingImage: false,
            receiptUrl: url,
            onCloseFunction: canRemove ? () => _confirmRemoveAdditionalReceipt(url) : null,
          ),
          const SizedBox(height: 8),
        ],
        if (visibleTileEntries.isNotEmpty) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: visibleTileEntries.map((entry) {
                final index = entry.key;
                final url = entry.value;
                final isUploading = _uploadingIndices.contains(index);
                return _buildImageTile(url, index: index, isUploading: isUploading);
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (canAdd)
          TextButton.icon(
            onPressed: _showAdditionalImageSourceOptions,
            icon: Icon(Icons.add_photo_alternate_outlined, color: primaryColor),
            label: Text('Add Image', style: TextStyle(color: primaryColor)),
          ),
      ],
    );
  }

  Widget _buildImageTile(String url, {required int index, required bool isUploading}) {
    return Container(
      width: 90,
      margin: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: isUploading ? null : () => setState(() => _viewingOtherReceiptUrls.add(url)),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            color: tileBackgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: bordercolor),
          ),
          child: isUploading
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(height: 4),
                      Text('Uploading', style: TextStyle(fontSize: 10, color: kTextMedium)),
                    ],
                  ),
                )
              : const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined, color: kWhitecolor, size: 28),
                    SizedBox(height: 4),
                    Text('Tap to view', style: TextStyle(fontSize: 9, color: kTextMedium), textAlign: TextAlign.center),
                  ],
                ),
        ),
      ),
    );
  }

  void _lazyLoadMainReceipt() => setState(() => _mainReceiptUrl = widget.expense.receiptUrl);

  Future<void> _removeMainReceipt() async {
    setState(() {
      _mainReceiptUrl = null;
      _receiptImage = null;
      _webImageBytes = null;
    });
    await widget.onMainReceiptRemoved?.call();
  }

  void _showImageSourceOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.camera_alt, color: primaryColor),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_library, color: primaryColor),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                await _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;

      if (kIsWeb) {
        final bytes = await image.readAsBytes();
        setState(() {
          _webImageBytes = bytes;
          _isWebUploadingMain = true;
        });
        final downloadUrl = await handleReceiptWeb(bytes, image.name, widget.expense);
        if (!mounted) return;
        if (downloadUrl == null) {
          setState(() { _isWebUploadingMain = false; _webImageBytes = null; });
          showError(context, 'Failed to upload receipt');
          return;
        }
        setState(() {
          _isWebUploadingMain = false;
          _mainReceiptUrl = downloadUrl;
          widget.expense.receiptUrl = downloadUrl;
        });
        if (widget.expense is WIPExpense) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Receipt submitted'),
              content: const Text('OCR is processing your receipt. Refresh in 1–2 minutes to see the extracted data.'),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
            ),
          );
        }
        return;
      }

      setState(() => _receiptImage = File(image.path));
      handleSharedReceipt(_receiptImage!, wipExpenseAsParam: widget.expense as WIPExpense).then((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const BulkImportScreen()),
          (route) => false,
        );
      });
    } catch (e) {
      if (mounted) showError(context, 'Failed to pick image');
    }
  }

  void _showAdditionalImageSourceOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.camera_alt, color: primaryColor),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickAdditionalImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_library, color: primaryColor),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickAdditionalImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAdditionalImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;
      if (kIsWeb) {
        final bytes = await image.readAsBytes();
        await _addAdditionalImageWeb(bytes, image.name);
        return;
      }
      await _addAdditionalImage(File(image.path));
    } catch (e) {
      if (mounted) showError(context, 'Failed to pick image');
    }
  }

  Future<void> _addAdditionalImageWeb(Uint8List bytes, String filename) async {
    final index = _otherReceiptUrls.length;
    setState(() {
      _otherReceiptUrls.add('uploading_$index');
      _uploadingIndices.add(index);
    });
    final url = await handleReceiptWeb(bytes, filename, widget.expense, arrayIndex: index);
    if (!mounted) return;
    if (url == null) {
      setState(() {
        _otherReceiptUrls.removeAt(index);
        _uploadingIndices.remove(index);
      });
      showError(context, 'Failed to upload image');
      return;
    }
    setState(() {
      _otherReceiptUrls[index] = url;
      _uploadingIndices.remove(index);
      widget.expense.otherReceiptUrls = List.from(_otherReceiptUrls);
    });
  }

  Future<void> _addAdditionalImage(File imageFile) async {
    final index = _otherReceiptUrls.length;
    setState(() {
      _otherReceiptUrls.add(imageFile.path);
      _uploadingIndices.add(index);
    });

    await handleAdditionalReceipt(
      imageFile: imageFile,
      expenseId: widget.expense.id,
      isWIPExpense: widget.expense is WIPExpense,
      arrayIndex: index,
      onDownloadUrl: (url) {
        if (!mounted) return;
        setState(() {
          _otherReceiptUrls[index] = url;
          _uploadingIndices.remove(index);
          widget.expense.otherReceiptUrls = List.from(_otherReceiptUrls);
        });
      },
      onError: () {
        if (!mounted) return;
        setState(() {
          _otherReceiptUrls.removeAt(index);
          _uploadingIndices.remove(index);
        });
        showError(context, 'Failed to upload image');
      },
    );
  }

  Future<void> _confirmRemoveAdditionalReceipt(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove Receipt', style: TextStyle(color: kTextColor)),
        content: Text('Are you sure you want to remove this receipt?', style: TextStyle(color: kTextMedium)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: kTextMedium)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove', style: TextStyle(color: errorcolor)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final updatedUrls = List<String>.from(_otherReceiptUrls)..remove(url);
    final httpsOnly = updatedUrls.where((u) => u.startsWith('https://')).toList();
    final collectionType = widget.expense is WIPExpense ? 'WIPExpenses' : 'Expenses';
    await updateOtherReceiptUrls(widget.expense.id, collectionType, httpsOnly);

    if (!mounted) return;
    setState(() {
      _otherReceiptUrls = updatedUrls;
      _viewingOtherReceiptUrls.remove(url);
      widget.expense.otherReceiptUrls = httpsOnly;
    });
  }
}
