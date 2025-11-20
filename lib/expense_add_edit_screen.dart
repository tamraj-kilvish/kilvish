import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';
import 'dart:developer';
import 'package:kilvish/models.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/tag_selection_screen.dart';
import 'style.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ExpenseAddEditScreen extends StatefulWidget {
  Expense? expense;

  ExpenseAddEditScreen({Key? key, this.expense}) : super(key: key);

  @override
  State<ExpenseAddEditScreen> createState() => _ExpenseAddEditScreenState();
}

class _ExpenseAddEditScreenState extends State<ExpenseAddEditScreen> {
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
  Set<Tag> _selectedTags = {};

  // Azure Vision API credentials - passed via --dart-define
  static const String _azureEndpoint = String.fromEnvironment('AZURE_VISION_ENDPOINT', defaultValue: '');
  static const String _azureKey = String.fromEnvironment('AZURE_VISION_KEY', defaultValue: '');

  @override
  void initState() {
    super.initState();

    // Warn if credentials are missing
    if (_azureEndpoint.isEmpty || _azureKey.isEmpty) {
      print('Warning: Azure Vision credentials not configured. OCR will not work.');
    }

    if (widget.expense != null) {
      _toController.text = widget.expense!.to;
      _amountController.text = widget.expense!.amount.toString();
      _notesController.text = widget.expense!.notes ?? '';
      _receiptUrl = widget.expense!.receiptUrl;
      _selectedTime = TimeOfDay.fromDateTime(widget.expense!.timeOfTransaction);
      _selectedDate = widget.expense!.timeOfTransaction;
      _selectedTags = Set.from(widget.expense!.tags);
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
                decoration: customUnderlineInputdecoration(hintText: 'Enter recipient name', bordersideColor: primaryColor),
                validator: (value) => value?.isEmpty ?? true ? 'Please enter recipient name' : null,
              ),
              SizedBox(height: 20),

              // Amount field
              renderPrimaryColorLabel(text: 'Amount'),
              SizedBox(height: 8),
              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                decoration: customUnderlineInputdecoration(hintText: '0.00', bordersideColor: primaryColor),
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
                      customText(DateFormat('MMM d, yyyy').format(_selectedDate), kTextColor, defaultFontSize, FontWeight.normal),
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
                      customText(_selectedTime.format(context), kTextColor, defaultFontSize, FontWeight.normal),
                      Icon(Icons.access_time, color: primaryColor, size: 20),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 20),

              // Tags section .. show only for edit case
              if (widget.expense != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    renderPrimaryColorLabel(text: 'Tags'),
                    IconButton(
                      icon: Icon(Icons.add_circle_outline, color: primaryColor),
                      onPressed: () => _openTagSelection(widget.expense!.id, null),
                      tooltip: 'Add/Edit Tags',
                    ),
                  ],
                ),
                SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _openTagSelection(widget.expense!.id, null),
                  child: renderTagGroup(tags: _selectedTags),
                ),
                SizedBox(height: 20),
              ],

              // Notes field
              renderPrimaryColorLabel(text: 'Notes (Optional)'),
              SizedBox(height: 8),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: customUnderlineInputdecoration(hintText: 'Add any additional notes', bordersideColor: primaryColor),
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
        constraints: BoxConstraints(minHeight: 200, maxHeight: _receiptImage != null || _receiptUrl != null ? 500 : 200),
        decoration: BoxDecoration(
          color: _receiptImage != null || _receiptUrl != null ? Colors.transparent : tileBackgroundColor,
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
                    customText('Processing receipt with OCR...', kTextMedium, defaultFontSize, FontWeight.normal),
                  ],
                ),
              )
            : _receiptImage != null || _receiptUrl != null
            ? Stack(
                children: [
                  // Full image display
                  Center(
                    child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _buildReceiptImage()),
                  ),
                  // Close button
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      icon: Icon(Icons.close, color: kWhitecolor),
                      style: IconButton.styleFrom(backgroundColor: Colors.black54),
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
                  customText('Tap to upload receipt', kTextMedium, defaultFontSize, FontWeight.normal),
                  SizedBox(height: 4),
                  customText('OCR will auto-fill fields from receipt', inactiveColor, smallFontSize, FontWeight.normal),
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
                  SizedBox(height: 16, width: 16, child: CircularProgressIndicator(color: kWhitecolor, strokeWidth: 2)),
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
            : Text(buttonText, style: const TextStyle(color: Colors.white, fontSize: 15)),
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
      });

      // Read bytes for both web and OCR processing
      final imageBytes = await image.readAsBytes();

      if (kIsWeb) {
        _webImageBytes = imageBytes;
      }

      // Process image with OCR
      await _processReceiptWithOCR(imageBytes);

      setState(() => _isProcessingImage = false);
    } catch (e) {
      print('Error picking image: $e');
      if (mounted) {
        showError(context, 'Failed to pick image');
      }
      setState(() => _isProcessingImage = false);
    }
  }

  /// Process receipt image with Azure Computer Vision OCR
  Future<void> _processReceiptWithOCR(Uint8List imageBytes) async {
    try {
      // Call Azure Vision API
      final extractedText = await _callAzureVisionAPI(imageBytes);

      if (extractedText == null || extractedText.isEmpty) {
        if (mounted) {
          showInfo(context, 'Could not extract text from receipt');
        }
        return;
      }

      print('Extracted text from receipt:\n$extractedText');

      // Parse extracted text to fill form fields
      final parsedData = _parseReceiptText(extractedText);

      // Update form fields with extracted data
      setState(() {
        if (parsedData['to'] != null && parsedData['to']!.isNotEmpty) {
          _toController.text = parsedData['to']!;
        }
        if (parsedData['amount'] != null && parsedData['amount']!.isNotEmpty) {
          _amountController.text = parsedData['amount']!;
        }
        if (parsedData['date'] != null) {
          _selectedDate = parsedData['date'];
        }
        if (parsedData['time'] != null) {
          _selectedTime = parsedData['time'];
        }
      });

      if (mounted) {
        final fieldsExtracted = <String>[];
        if (parsedData['to'] != null) fieldsExtracted.add('recipient');
        if (parsedData['amount'] != null) fieldsExtracted.add('amount');
        if (parsedData['date'] != null) fieldsExtracted.add('date');
        if (parsedData['time'] != null) fieldsExtracted.add('time');

        if (fieldsExtracted.isNotEmpty) {
          showSuccess(context, 'Extracted: ${fieldsExtracted.join(', ')}');
        } else {
          showInfo(context, 'Receipt uploaded. Could not auto-fill fields.');
        }
      }
    } catch (e, stackTrace) {
      print('Error processing receipt with OCR: $e, $stackTrace');
      if (mounted) {
        showInfo(context, 'Receipt uploaded. OCR processing failed.');
      }
    }
  }

  /// Call Azure Computer Vision API to extract text from image
  Future<String?> _callAzureVisionAPI(Uint8List imageBytes) async {
    try {
      final url = Uri.parse('$_azureEndpoint/vision/v3.2/read/analyze');

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/octet-stream', 'Ocp-Apim-Subscription-Key': _azureKey},
        body: imageBytes,
      );

      if (response.statusCode != 202) {
        print('Azure Vision API error: ${response.statusCode} - ${response.body}');
        return null;
      }

      // Get the operation location for polling results
      final operationLocation = response.headers['operation-location'];
      if (operationLocation == null) {
        log('No operation-location header in response');
        return null;
      }

      // Poll for results
      String? extractedText;
      int maxAttempts = 10;
      int attempt = 0;

      while (attempt < maxAttempts) {
        await Future.delayed(Duration(seconds: 1));

        final resultResponse = await http.get(Uri.parse(operationLocation), headers: {'Ocp-Apim-Subscription-Key': _azureKey});

        if (resultResponse.statusCode != 200) {
          print('Error polling Azure API. results: ${resultResponse.statusCode}');
          attempt++;
          continue;
        }

        final resultData = jsonDecode(resultResponse.body);
        final status = resultData['status'];

        if (status == 'succeeded') {
          // Extract text from results
          final analyzeResult = resultData['analyzeResult'];
          if (analyzeResult != null && analyzeResult['readResults'] != null) {
            final lines = <String>[];
            for (var page in analyzeResult['readResults']) {
              for (var line in page['lines']) {
                lines.add(line['text']);
              }
            }
            extractedText = lines.join('\n');
          }
          break;
        } else if (status == 'failed') {
          print('Azure Vision analysis failed');
          break;
        }

        attempt++;
      }

      return extractedText;
    } catch (e, stackTrace) {
      print('Error calling Azure Vision API: $e, $stackTrace');
      return null;
    }
  }

  /// Parse extracted text to extract receipt fields
  Map<String, dynamic> _parseReceiptText(String text) {
    final result = <String, dynamic>{};
    final lines = text.split('\n');
    final fullText = text;

    // Extract amount - look for ₹ symbol followed by number
    // Patterns: ₹25,000.00, ₹2,260, ₹57
    final amountRegex = RegExp(r'₹\s*([\d,]+(?:\.\d{2})?)', multiLine: true);
    final amountMatches = amountRegex.allMatches(fullText).toList();

    if (amountMatches.isNotEmpty) {
      // Usually the first or largest amount is the transaction amount
      String? largestAmount;
      double largestValue = 0;

      for (var match in amountMatches) {
        final amountStr = match.group(1)!.replaceAll(',', '');
        final value = double.tryParse(amountStr) ?? 0;
        if (value > largestValue) {
          largestValue = value;
          largestAmount = amountStr;
        }
      }

      if (largestAmount != null) {
        result['amount'] = largestAmount;
      }
    }

    // Extract recipient name - look for patterns like "Paid to", "To", followed by name
    String? recipient;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final lineLower = line.toLowerCase();

      // Pattern: "Paid to" on one line, name on next line
      if (lineLower == 'paid to' && i + 1 < lines.length) {
        recipient = lines[i + 1].trim();
        // Skip if next line looks like bank info
        if (!recipient.toLowerCase().contains('banking name') && !recipient.contains('@') && recipient.isNotEmpty) {
          break;
        }
      }

      // Pattern: "To SHAMBAVI SWEETS" - To followed by name on same line
      if (lineLower.startsWith('to ') && !lineLower.contains('to:')) {
        recipient = line.substring(3).trim();
        if (recipient.isNotEmpty && !recipient.contains('@')) {
          break;
        }
      }
    }

    if (recipient != null && recipient.isNotEmpty) {
      // Clean up recipient name
      recipient = recipient.replaceAll(RegExp(r'[^\w\s]'), ' ').trim();
      // Remove multiple spaces
      recipient = recipient.replaceAll(RegExp(r'\s+'), ' ');
      result['to'] = recipient;
    }

    // Extract date and time
    // Patterns:
    // "5 November 2025, 1:45 pm"
    // "08:00 pm on 31 Oct 2025"
    // "28 Oct 2025, 10:45 am"

    DateTime? extractedDate;
    TimeOfDay? extractedTime;

    // Pattern 1: "5 November 2025, 1:45 pm" or "28 Oct 2025, 10:45 am"
    final datePattern1 = RegExp(
      r'(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4}),?\s*(\d{1,2}):(\d{2})\s*(am|pm)',
      caseSensitive: false,
    );

    // Pattern 2: "08:00 pm on 31 Oct 2025"
    final datePattern2 = RegExp(
      r'(\d{1,2}):(\d{2})\s*(am|pm)\s+on\s+(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})',
      caseSensitive: false,
    );

    var match = datePattern1.firstMatch(fullText);
    if (match != null) {
      final day = int.parse(match.group(1)!);
      final monthStr = match.group(2)!;
      final year = int.parse(match.group(3)!);
      final hour = int.parse(match.group(4)!);
      final minute = int.parse(match.group(5)!);
      final amPm = match.group(6)!.toLowerCase();

      final month = _parseMonth(monthStr);
      if (month != null) {
        extractedDate = DateTime(year, month, day);

        int adjustedHour = hour;
        if (amPm == 'pm' && hour != 12) {
          adjustedHour = hour + 12;
        } else if (amPm == 'am' && hour == 12) {
          adjustedHour = 0;
        }
        extractedTime = TimeOfDay(hour: adjustedHour, minute: minute);
      }
    } else {
      match = datePattern2.firstMatch(fullText);
      if (match != null) {
        final hour = int.parse(match.group(1)!);
        final minute = int.parse(match.group(2)!);
        final amPm = match.group(3)!.toLowerCase();
        final day = int.parse(match.group(4)!);
        final monthStr = match.group(5)!;
        final year = int.parse(match.group(6)!);

        final month = _parseMonth(monthStr);
        if (month != null) {
          extractedDate = DateTime(year, month, day);

          int adjustedHour = hour;
          if (amPm == 'pm' && hour != 12) {
            adjustedHour = hour + 12;
          } else if (amPm == 'am' && hour == 12) {
            adjustedHour = 0;
          }
          extractedTime = TimeOfDay(hour: adjustedHour, minute: minute);
        }
      }
    }

    if (extractedDate != null) {
      result['date'] = extractedDate;
    }
    if (extractedTime != null) {
      result['time'] = extractedTime;
    }

    return result;
  }

  /// Parse month string to month number
  int? _parseMonth(String monthStr) {
    final monthMap = {
      'january': 1,
      'jan': 1,
      'february': 2,
      'feb': 2,
      'march': 3,
      'mar': 3,
      'april': 4,
      'apr': 4,
      'may': 5,
      'june': 6,
      'jun': 6,
      'july': 7,
      'jul': 7,
      'august': 8,
      'aug': 8,
      'september': 9,
      'sep': 9,
      'october': 10,
      'oct': 10,
      'november': 11,
      'nov': 11,
      'december': 12,
      'dec': 12,
    };
    return monthMap[monthStr.toLowerCase()];
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(colorScheme: ColorScheme.light(primary: primaryColor)),
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
        data: Theme.of(context).copyWith(colorScheme: ColorScheme.light(primary: primaryColor)),
        child: child!,
      ),
    );

    if (picked != null) setState(() => _selectedTime = picked);
  }

  Future<void> _openTagSelection(String expenseId, bool? popAgain) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TagSelectionScreen(initialSelectedTags: _selectedTags, expenseId: expenseId),
      ),
    );

    Expense? updatedExpense = await getExpense(expenseId);
    if (updatedExpense == null) {
      if (mounted) showError(context, "Updated expenses is null .. something gone wrong");
      return;
    }

    if (result != null && result is Set<Tag>) {
      result.forEach((Tag tag) => updatedExpense.addTagToExpense(tag));
    }

    if (popAgain != null) {
      // send control to callee screen
      if (mounted) Navigator.pop(context, updatedExpense);
      return;
    }

    setState(() {
      widget.expense = updatedExpense;
      if (result != null && result is Set<Tag>) {
        _selectedTags = result;
      }
    });
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
        'notes': _notesController.text.isNotEmpty ? _notesController.text : null,
        'receiptUrl': uploadedReceiptUrl,
        'updatedAt': FieldValue.serverTimestamp(),
        'txId': "${_toController.text}_${DateFormat('MMM-d-yy-h:mm-a').format(transactionDateTime)}",
      };

      // Step 3: Save to Firestore
      if (widget.expense != null) {
        await addOrUpdateUserExpense(expenseData, widget.expense!.id, _selectedTags);

        if (mounted) showSuccess(context, 'Expense updated successfully');
        if (mounted) Navigator.pop(context, await getExpense(widget.expense!.id));
      } else {
        expenseData['createdAt'] = FieldValue.serverTimestamp();
        String? expenseId = await addOrUpdateUserExpense(expenseData, null, null);

        //Take user to tag selection screen
        if (expenseId != null) {
          if (mounted) {
            showSuccess(context, 'Expense added successfully, add some tags to it');
          }
          await _openTagSelection(expenseId, true);
        } else {
          if (mounted) showError(context, 'Error in creating Expense');
        }
      }
    } catch (e, stackTrace) {
      print('Error saving expense: $e $stackTrace');
      if (mounted) showError(context, 'Failed to save expense');
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
        log('Error: userId is null, cannot upload receipt');
        return null;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      String extension = _receiptImage!.path.split('.').last.toLowerCase();
      if (!['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(extension)) {
        extension = 'jpg';
      }

      final fileName = 'receipts/${userId}_$timestamp.$extension';

      final ref = FirebaseStorage.instanceFor(bucket: 'gs://tamraj-kilvish.firebasestorage.app').ref().child(fileName);

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
      print('Error uploading receipt: $e, $stackTrace');
      return null;
    }
  }
}
