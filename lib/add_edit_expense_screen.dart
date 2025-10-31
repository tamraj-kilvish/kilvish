import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';
import 'dart:developer';
import 'package:kilvish/models.dart';
import 'package:kilvish/common_widgets.dart';
import 'style.dart';

class AddEditExpenseScreen extends StatefulWidget {
  final Expense? expense;

  const AddEditExpenseScreen({Key? key, this.expense}) : super(key: key);

  @override
  State<AddEditExpenseScreen> createState() => _AddEditExpenseScreenState();
}

class _AddEditExpenseScreenState extends State<AddEditExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _toController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  File? _receiptImage;
  Uint8List? _webImageBytes;
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();
  bool _isLoading = false;
  bool _isProcessingImage = false;
  String? _receiptUrl;

  @override
  void initState() {
    super.initState();
    if (widget.expense != null) {
      _toController.text = widget.expense!.to;
      _amountController.text = widget.expense!.amount.toString();
      _notesController.text = widget.expense!.notes ?? '';
      _receiptUrl = widget.expense!.receiptUrl;
      _selectedTime = TimeOfDay.fromDateTime(widget.expense!.timeOfTransaction);
      _selectedDate = widget.expense!.timeOfTransaction;
    }
  }

  @override
  void dispose() {
    _toController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.expense != null;

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: appBarTitleText(isEditing ? 'Edit Expense' : 'Add Expense'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Receipt upload section - Large centered area
              _buildReceiptUploadSection(),
              SizedBox(height: 24),

              // To field
              renderPrimaryColorLabel(text: 'Recipient'),
              SizedBox(height: 8),
              TextFormField(
                controller: _toController,
                decoration: customUnderlineInputdecoration(
                  hintText: 'Enter recipient name',
                  bordersideColor: primaryColor,
                ),
                validator: (value) => value?.isEmpty ?? true
                    ? 'Please enter recipient name'
                    : null,
              ),
              SizedBox(height: 20),

              // Amount field
              renderPrimaryColorLabel(text: 'Amount'),
              SizedBox(height: 8),
              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                decoration: customUnderlineInputdecoration(
                  hintText: '0.00',
                  bordersideColor: primaryColor,
                ),
                validator: (value) {
                  if (value?.isEmpty ?? true) return 'Please enter amount';
                  if (double.tryParse(value!) == null) {
                    return 'Please enter a valid number';
                  }
                  return null;
                },
              ),
              SizedBox(height: 20),

              // Date picker
              renderPrimaryColorLabel(text: 'Date'),
              SizedBox(height: 8),
              InkWell(
                onTap: _selectDate,
                child: Container(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: primaryColor)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      customText(
                        DateFormat('MMM d, yyyy').format(_selectedDate),
                        kTextColor,
                        defaultFontSize,
                        FontWeight.normal,
                      ),
                      Icon(Icons.calendar_today, color: primaryColor, size: 20),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 20),

              // Time picker
              renderPrimaryColorLabel(text: 'Time'),
              SizedBox(height: 8),
              InkWell(
                onTap: _selectTime,
                child: Container(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: primaryColor)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      customText(
                        _selectedTime.format(context),
                        kTextColor,
                        defaultFontSize,
                        FontWeight.normal,
                      ),
                      Icon(Icons.access_time, color: primaryColor, size: 20),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 20),

              // Notes field
              renderPrimaryColorLabel(text: 'Notes (Optional)'),
              SizedBox(height: 8),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: customUnderlineInputdecoration(
                  hintText: 'Add any additional notes',
                  bordersideColor: primaryColor,
                ),
              ),
              SizedBox(height: 32),

              // Save button
              renderMainBottomButton(
                isEditing ? 'Update Expense' : 'Add Expense',
                _isLoading ? null : _saveExpense,
                !_isLoading,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptUploadSection() {
    return GestureDetector(
      onTap: _isProcessingImage ? null : _showImageSourceOptions,
      child: Container(
        constraints: BoxConstraints(
          minHeight: 200,
          maxHeight: _receiptImage != null || _receiptUrl != null ? 500 : 200,
        ),
        decoration: BoxDecoration(
          color: _receiptImage != null || _receiptUrl != null
              ? Colors.transparent
              : tileBackgroundColor,
          border: Border.all(color: bordercolor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _isProcessingImage
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: primaryColor),
                    SizedBox(height: 16),
                    customText(
                      'Processing receipt...',
                      kTextMedium,
                      defaultFontSize,
                      FontWeight.normal,
                    ),
                  ],
                ),
              )
            : _receiptImage != null || _receiptUrl != null
            ? Stack(
                children: [
                  // Full image display
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildReceiptImage(),
                    ),
                  ),
                  // Close button
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      icon: Icon(Icons.close, color: kWhitecolor),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                      ),
                      onPressed: () {
                        setState(() {
                          _receiptImage = null;
                          _receiptUrl = null;
                          _webImageBytes = null;
                        });
                      },
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  renderImageIcon(Icons.add_photo_alternate_outlined),
                  SizedBox(height: 12),
                  customText(
                    'Tap to upload receipt',
                    kTextMedium,
                    defaultFontSize,
                    FontWeight.normal,
                  ),
                  SizedBox(height: 4),
                  customText(
                    kIsWeb
                        ? 'Auto-fill available on mobile app'
                        : 'OCR will auto-fill fields',
                    inactiveColor,
                    smallFontSize,
                    FontWeight.normal,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildReceiptImage() {
    if (_receiptUrl != null && _receiptUrl!.isNotEmpty) {
      // Show network image (for existing receipts)
      return Image.network(
        _receiptUrl!,
        fit: BoxFit.contain, // Changed from cover to contain to show full image
        width: double.infinity,
      );
    } else if (kIsWeb && _webImageBytes != null) {
      // Web platform - use memory bytes
      return Image.memory(
        _webImageBytes!,
        fit: BoxFit.contain, // Show full image
        width: double.infinity,
      );
    } else if (!kIsWeb && _receiptImage != null) {
      // Mobile platform - use file
      return Image.file(
        _receiptImage!,
        fit: BoxFit.contain, // Show full image
        width: double.infinity,
      );
    } else {
      return Container(color: Colors.grey[300]);
    }
  }

  void _showImageSourceOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.camera_alt, color: primaryColor),
              title: Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_library, color: primaryColor),
              title: Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
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

      setState(() {
        _receiptImage = File(image.path);
        _isProcessingImage = true;
      });

      // For web, also read the bytes
      if (kIsWeb) {
        _webImageBytes = await image.readAsBytes();
      }

      // TODO: Implement OCR to extract text from receipt
      // For now, just simulate processing
      await Future.delayed(Duration(seconds: 2));

      setState(() => _isProcessingImage = false);

      _showInfo('Receipt uploaded! OCR feature coming soon.');
    } catch (e) {
      log('Error picking image: $e', error: e);
      _showError('Failed to pick image');
      setState(() => _isProcessingImage = false);
    }
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(
          context,
        ).copyWith(colorScheme: ColorScheme.light(primary: primaryColor)),
        child: child!,
      ),
    );

    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _selectTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) => Theme(
        data: Theme.of(
          context,
        ).copyWith(colorScheme: ColorScheme.light(primary: primaryColor)),
        child: child!,
      ),
    );

    if (picked != null) setState(() => _selectedTime = picked);
  }

  Future<void> _saveExpense() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      String? uploadedReceiptUrl = _receiptUrl;
      if (_receiptImage != null) {
        uploadedReceiptUrl = await _uploadReceipt();
      }

      final transactionDateTime = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

      final expenseData = {
        'to': _toController.text,
        'amount': double.parse(_amountController.text),
        'timeOfTransaction': Timestamp.fromDate(transactionDateTime),
        'notes': _notesController.text.isNotEmpty
            ? _notesController.text
            : null,
        'receiptUrl': uploadedReceiptUrl,
        'updatedAt': FieldValue.serverTimestamp(),
        'ownerId': getUserIdFromClaim(),
        'txId':
            "${_toController.text}_${DateFormat('MMM-d-yy-h:mm-a').format(transactionDateTime)}",
      };

      if (widget.expense != null) {
        await addOrUpdateUserExpense(expenseData, widget.expense!.id);
        _showSuccess('Expense updated successfully');
      } else {
        expenseData['createdAt'] = FieldValue.serverTimestamp();
        await addOrUpdateUserExpense(expenseData, null);
        _showSuccess('Expense added successfully');
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      log('Error saving expense: $e', error: e);
      _showError('Failed to save expense');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _uploadReceipt() async {
    if (_receiptImage == null) return null;

    try {
      final user = FirebaseAuth.instance.currentUser;
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      String extension = _receiptImage!.path.split('.').last.toLowerCase();
      if (!['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(extension)) {
        extension = 'jpg';
      }

      final fileName =
          'receipts/${user?.uid ?? 'anonymous'}_$timestamp.$extension';

      final ref = FirebaseStorage.instanceFor(
        bucket: 'gs://tamraj-kilvish.firebasestorage.app',
      ).ref().child(fileName);

      // Upload differently for web vs mobile
      if (kIsWeb && _webImageBytes != null) {
        await ref.putData(_webImageBytes!);
      } else {
        await ref.putFile(_receiptImage!);
      }

      final downloadUrl = await ref.getDownloadURL();
      log('Receipt uploaded successfully: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      log('Error uploading receipt: $e', error: e);
      return null;
    }
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: errorcolor),
    );
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
