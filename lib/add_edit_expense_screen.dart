import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
  String _saveStatus = ''; // Track current save operation status

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

              // Save button with dynamic status
              _buildSaveButton(isEditing),
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
                          _amountController.clear();
                          _toController.clear();
                          _selectedDate = DateTime.now();
                          _selectedTime = TimeOfDay.now();
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

  Widget _buildSaveButton(bool isEditing) {
    final buttonText = isEditing ? 'Update Expense' : 'Add Expense';

    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: _isLoading ? null : _saveExpense,
        style: TextButton.styleFrom(
          backgroundColor: _isLoading ? inactiveColor : primaryColor,
          minimumSize: const Size.fromHeight(50),
        ),
        child: _isLoading
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      color: kWhitecolor,
                      strokeWidth: 2,
                    ),
                  ),
                  if (_saveStatus.isNotEmpty) ...[
                    SizedBox(height: 6),
                    Text(
                      _saveStatus,
                      style: TextStyle(
                        color: kWhitecolor,
                        fontSize: 12, // Smaller font for status
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ],
                ],
              )
            : Text(
                buttonText,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
      ),
    );
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
        // Clear previously extracted data when replacing receipt
        _amountController.clear();
        _toController.clear();
        _selectedDate = DateTime.now();
        _selectedTime = TimeOfDay.now();
      });

      // For web, also read the bytes
      if (kIsWeb) {
        _webImageBytes = await image.readAsBytes();
        setState(() => _isProcessingImage = false);
        _showInfo(
          'OCR is only available on mobile app. Please use the mobile version for auto-fill.',
        );
        return;
      }

      // Perform OCR on mobile
      await _performOCR(image.path);

      setState(() => _isProcessingImage = false);
    } catch (e, stackTrace) {
      print('Error picking image: $e $stackTrace');
      _showError('Failed to pick image');
      setState(() => _isProcessingImage = false);
    }
  }

  Future<void> _performOCR(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final textRecognizer = TextRecognizer();

      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );
      await textRecognizer.close();

      print('OCR completed. Text length: ${recognizedText.text.length}');

      if (recognizedText.text.isEmpty) {
        _showInfo('No text found in receipt. Please enter details manually.');
        return;
      }

      // Extract data from OCR text
      final extractedData = _extractReceiptData(recognizedText.text);

      // Auto-fill form fields
      if (extractedData['amount'] != null) {
        setState(() {
          _amountController.text = extractedData['amount']!;
        });
      }

      if (extractedData['merchant'] != null) {
        setState(() {
          _toController.text = extractedData['merchant']!;
        });
      }

      if (extractedData['date'] != null) {
        setState(() {
          _selectedDate = extractedData['date']!;
        });
      }

      if (extractedData['time'] != null) {
        setState(() {
          _selectedTime = extractedData['time']!;
        });
      }

      // Show success message
      final fieldsExtracted = <String>[];
      if (extractedData['amount'] != null) fieldsExtracted.add('amount');
      if (extractedData['merchant'] != null) fieldsExtracted.add('merchant');
      if (extractedData['date'] != null) {
        fieldsExtracted.add(
          extractedData['time'] != null ? 'date & time' : 'date',
        );
      }

      if (fieldsExtracted.isNotEmpty) {
        _showSuccess(
          'Extracted: ${fieldsExtracted.join(', ')}. Please verify.',
        );
      } else {
        _showInfo('Could not extract data. Please enter manually.');
      }
    } catch (e, stackTrace) {
      print('OCR Error: $e\n$stackTrace');
      _showInfo('OCR failed. Please enter details manually.');
    }
  }

  Map<String, dynamic> _extractReceiptData(String ocrText) {
    final Map<String, dynamic> result = {};

    // Debug: Log the OCR text to see what we're working with
    print('OCR Full Text: $ocrText');

    // Extract amount - Enhanced patterns with better Rupee symbol handling
    // The ₹ symbol might appear as different unicode characters or be missing
    final amountPatterns = [
      // Pattern 1: Look for standalone numbers after "To" or before date/time
      RegExp(
        r'(?:To\s+[A-Z\s]+)\s*[₹₨Rs.]*\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)',
        caseSensitive: false,
      ),

      // Pattern 2: Look for rupee symbols (₹, ₨, or Rs) followed by numbers
      RegExp(r'[₹₨]\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)', caseSensitive: false),
      RegExp(r'Rs\.?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)', caseSensitive: false),
      RegExp(r'INR\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)', caseSensitive: false),

      // Pattern 3: Look for amount labels
      RegExp(
        r'(?:Total|Amount|Paid)[:\s]*[₹₨Rs.]*\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)',
        caseSensitive: false,
      ),

      // Pattern 4: Look for large numbers (likely amounts) - must be reasonable range
      RegExp(r'\b(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\b'),

      // Pattern 5: Just look for any number that could be an amount
      RegExp(r'\b(\d+(?:,\d{3})*(?:\.\d{2})?)\b'),
    ];

    // Try each pattern
    for (int i = 0; i < amountPatterns.length; i++) {
      final pattern = amountPatterns[i];
      final matches = pattern.allMatches(ocrText);

      for (final match in matches) {
        String amount = match.group(1)!.replaceAll(',', '');
        double? amountValue = double.tryParse(amount);

        // Filter: Amount should be reasonable (between 1 and 100,000,000)
        if (amountValue != null &&
            amountValue >= 1 &&
            amountValue <= 100000000) {
          print('Pattern $i matched amount: $amount');
          result['amount'] = amount;
          break;
        }
      }

      if (result.containsKey('amount')) break;
    }

    // Extract date and time (looking for various date formats)
    // IMPORTANT: Try date+time patterns first, and make date-only NOT match if time follows
    final dateTimePatterns = [
      // Date with time: "28 Oct 2025, 10:45 am"
      // RegExp(
      //   r'^\d{1,2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}, \d{1,2}:\d{2} (am|pm)$',
      //   caseSensitive: false, // Set to false to match 'am' or 'pm' in any case
      // ),
      RegExp(
        r'(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{2,4}),?\s+(\d{1,2}):(\d{2})\s*(am|pm)',
        caseSensitive: false,
      ),
      // Date with time: "5 November 2025, 1:45 pm"
      RegExp(
        r'(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{2,4}),?\s+(\d{1,2}):(\d{2})\s*(am|pm)',
        caseSensitive: false,
      ),
    ];

    for (final pattern in dateTimePatterns) {
      final match = pattern.firstMatch(ocrText);
      if (match != null) {
        try {
          print('Trying to parse Date+Time: ${match.group(0)}');
          DateTime? parsedDate = _parseDateWithTime(match.group(0)!);
          // DateTime parsedDate = DateFormat(
          //   'dd MMM yyyy, h:mm a',
          // ).parse(match.group(0)!);
          if (parsedDate != null) {
            print('Date+Time matched: ${match.group(0)}');
            result['date'] = parsedDate;
            result['time'] = TimeOfDay(
              hour: parsedDate.hour,
              minute: parsedDate.minute,
            );
            break;
          }
        } catch (e, stackTrace) {
          print('Date+Time parsing error: $e, $stackTrace');
        }
      }
    }

    // If no date+time found, try date only patterns
    // These patterns should NOT match if followed by a time
    // if (!result.containsKey('date')) {
    //   final datePatterns = [
    //     // Date only (NOT followed by time): "28 Oct 2025" but NOT "28 Oct 2025, 10:45"
    //     RegExp(
    //       r'(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{2,4})(?!\s*,?\s*\d{1,2}:\d{2})',
    //       caseSensitive: false,
    //     ),
    //     RegExp(r'(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})'),
    //     // Full month name (NOT followed by time)
    //     RegExp(
    //       r'(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{2,4})(?!\s*,?\s*\d{1,2}:\d{2})',
    //       caseSensitive: false,
    //     ),
    //   ];

    //   for (final pattern in datePatterns) {
    //     final match = pattern.firstMatch(ocrText);
    //     if (match != null) {
    //       try {
    //         // Try to parse the date
    //         DateTime? parsedDate = _parseDate(match.group(0)!);
    //         if (parsedDate != null) {
    //           print('Date matched: ${match.group(0)}');
    //           result['date'] = parsedDate;
    //           break;
    //         }
    //       } catch (e) {
    //         print('Date parsing error: $e');
    //       }
    //     }
    //   }
    // }

    // Extract merchant name - Multiple strategies
    final lines = ocrText
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();

    // Strategy 1: Look for "To:" or "Paid to" pattern
    final merchantPattern = RegExp(
      r'(?:To|Paid\s+to)[:\s]+([A-Z][A-Z\s]+)',
      caseSensitive: false,
    );
    final merchantMatch = merchantPattern.firstMatch(ocrText);
    if (merchantMatch != null) {
      String merchant = merchantMatch.group(1)!.trim();
      // Clean up
      merchant = merchant.replaceAll(RegExp(r'[₹₨\d.,\-/]'), '').trim();
      if (merchant.length > 2 && merchant.length < 50) {
        print('Merchant matched (pattern): $merchant');
        result['merchant'] = merchant;
      }
    }

    // Strategy 2: If no "To:" found, take first line that looks like a name
    if (!result.containsKey('merchant') && lines.isNotEmpty) {
      for (var line in lines) {
        String cleaned = line
            .trim()
            .replaceAll(RegExp(r'[₹₨\d.,\-/]'), '')
            .trim();
        // Must be mostly letters, reasonable length
        if (cleaned.length > 2 &&
            cleaned.length < 50 &&
            RegExp(r'^[A-Za-z\s]+$').hasMatch(cleaned)) {
          print('Merchant matched (first valid line): $cleaned');
          result['merchant'] = cleaned;
          break;
        }
      }
    }

    print('Extraction result: $result');
    return result;
  }

  DateTime? _parseDate(String dateStr) {
    try {
      // Try various date formats
      final formats = [
        DateFormat('dd/MM/yyyy'),
        DateFormat('dd-MM-yyyy'),
        DateFormat('dd/MM/yy'),
        DateFormat('dd-MM-yy'),
        DateFormat('dd MMM yyyy'),
        DateFormat('dd MMMM yyyy'),
      ];

      for (final format in formats) {
        try {
          return format.parse(dateStr);
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      print('Date parsing failed: $e');
    }
    return null;
  }

  DateTime? _parseDateWithTime(String dateTimeStr) {
    try {
      dateTimeStr = dateTimeStr
          .replaceFirst(' am', ' AM')
          .replaceFirst(' pm', ' PM');
      // Try various date+time formats
      final formats = [
        DateFormat('dd MMM yyyy, h:mm a'), // 28 Oct 2025, 10:45 am
        DateFormat('dd MMMM yyyy, h:mm a'), // 5 November 2025, 1:45 pm
        //DateFormat('dd MMM yyyy h:mm a'), // Without comma
        //DateFormat('dd MMMM yyyy h:mm a'),
      ];

      for (final format in formats) {
        try {
          return format.parse(dateTimeStr);
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      print('DateTime parsing failed: $e');
    }
    return null;
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

    setState(() {
      _isLoading = true;
      _saveStatus = '';
    });

    try {
      String? uploadedReceiptUrl = _receiptUrl;

      // Step 1: Upload receipt if new image exists
      if (_receiptImage != null) {
        setState(() => _saveStatus = 'Uploading receipt...');
        uploadedReceiptUrl = await _uploadReceipt();
      }

      // Step 2: Prepare expense data
      setState(() => _saveStatus = 'Saving expense...');

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
        'ownerId': await getUserIdFromClaim(),
        'txId':
            "${_toController.text}_${DateFormat('MMM-d-yy-h:mm-a').format(transactionDateTime)}",
      };

      // Step 3: Save to Firestore
      if (widget.expense != null) {
        await addOrUpdateUserExpense(expenseData, widget.expense!.id);
        _showSuccess('Expense updated successfully');
      } else {
        expenseData['createdAt'] = FieldValue.serverTimestamp();
        await addOrUpdateUserExpense(expenseData, null);
        _showSuccess('Expense added successfully');
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e, stackTrace) {
      print('Error saving expense: $e $stackTrace');
      _showError('Failed to save expense');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _saveStatus = '';
        });
      }
    }
  }

  Future<String?> _uploadReceipt() async {
    if (_receiptImage == null) return null;

    try {
      // Get the custom userId claim (not Firebase Auth uid)
      final userId = await getUserIdFromClaim();
      if (userId == null) {
        print('Error: userId is null, cannot upload receipt');
        return null;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      String extension = _receiptImage!.path.split('.').last.toLowerCase();
      if (!['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(extension)) {
        extension = 'jpg';
      }

      final fileName = 'receipts/${userId}_$timestamp.$extension';

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
      print('Receipt uploaded successfully: $downloadUrl');
      return downloadUrl;
    } catch (e, stackTrace) {
      print('Error uploading receipt: $e $stackTrace');
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
