import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/firestore_expenses.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:kilvish/model_tags.dart';
import 'package:kilvish/tag_selection_screen.dart';
import 'style.dart';

class ExpenseAddEditScreen extends StatefulWidget {
  final BaseExpense baseExpense;

  const ExpenseAddEditScreen({super.key, required this.baseExpense});

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
  DateTime? _selectedDate;
  TimeOfDay _selectedTime = TimeOfDay.now();
  bool _isLoading = false;
  String? _receiptUrl;
  String _saveStatus = '';
  late BaseExpense _baseExpense;
  List<Tag> _userTags = [];

  final TextEditingController _recoveryTagNameController = TextEditingController(); // NEW
  final TextEditingController _recoveryAmountController = TextEditingController(); // NEW

  @override
  void initState() {
    super.initState();

    _baseExpense = widget.baseExpense;
    print("AddEditExpense screen - _baseExpense with receipt url ${_baseExpense.receiptUrl}");

    _toController.text = _baseExpense.to ?? '';
    _amountController.text = _baseExpense.amount?.toString() ?? '';
    _notesController.text = _baseExpense.notes ?? '';
    _receiptUrl = _baseExpense.receiptUrl;
    _receiptImage = _baseExpense.localReceiptPath != null ? File(_baseExpense.localReceiptPath!) : null;

    if (_baseExpense.timeOfTransaction != null) {
      _selectedDate = _baseExpense.timeOfTransaction as DateTime;
      _selectedTime = TimeOfDay.fromDateTime(_baseExpense.timeOfTransaction as DateTime);
    }

    getUserAccessibleTags().then((tags) {
      setState(() {
        _userTags = tags;
      });
    });
  }

  @override
  void dispose() {
    _toController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    _recoveryTagNameController.dispose(); // NEW
    _recoveryAmountController.dispose(); // NEW
    super.dispose();
  }

  List<Widget> recoveryExpenseWidget() {
    return [
      Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.money_off, color: Colors.orange),
                SizedBox(width: 8),
                Text(
                  'Recovery Tracking',
                  style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w600, color: Colors.orange.shade700),
                ),
              ],
            ),
            SizedBox(height: 16),

            // Recovery Tag Name
            renderPrimaryColorLabel(text: 'Recovery Tag Name *'),
            SizedBox(height: 8),
            TextFormField(
              controller: _recoveryTagNameController,
              decoration: customUnderlineInputdecoration(
                hintText: 'e.g., Travel Recovery, Medical Recovery',
                bordersideColor: Colors.orange,
              ),
              validator: (value) => value?.isEmpty ?? true ? 'Please enter tag name' : null,
            ),
            SizedBox(height: 16),

            // Recovery Amount
            renderPrimaryColorLabel(text: 'Recovery Amount *'),
            SizedBox(height: 8),
            TextFormField(
              controller: _recoveryAmountController,
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              decoration: customUnderlineInputdecoration(hintText: '0.00', bordersideColor: Colors.orange),
              validator: (value) {
                if (value?.isEmpty ?? true) return 'Please enter recovery amount';
                if (double.tryParse(value!) == null) {
                  return 'Please enter a valid number';
                }
                return null;
              },
            ),
            SizedBox(height: 8),
            Text(
              'This amount will be tracked for recovery from the recipient',
              style: TextStyle(fontSize: xsmallFontSize, color: Colors.orange.shade700),
            ),
          ],
        ),
      ),
      SizedBox(height: 32),
    ];
  }

  Widget wipExpenseBanner(WIPExpense wipExpense) {
    final (color, image, text) = getWIPBannerContent(wipExpense);

    return Container(
      padding: EdgeInsets.all(12),
      margin: EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          image,
          SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color.shade700, fontSize: smallFontSize),
            ),
          ),
        ],
      ),
    );
  }

  (MaterialColor, Widget, String) getWIPBannerContent(WIPExpense wipExpense) {
    bool isError = wipExpense.errorMessage != null && wipExpense.errorMessage!.isNotEmpty;
    if (isError) {
      return (
        Colors.red,
        Icon(Icons.error, color: Colors.red),
        "${wipExpense.errorMessage!}. Remove & reattach receipt to trigger the workflow again.",
      );
    }

    // NEW: Check if recovery amount is needed
    if (wipExpense.needsRecoveryAmount()) {
      return (
        Colors.red,
        Icon(Icons.warning, color: Colors.red),
        "Navigate to Tag Selection to specify recovery amount before saving",
      );
    }

    return (
      wipExpense.getStatusColor(),
      wipExpense.status == ExpenseStatus.readyForReview
          ? Icon(Icons.receipt_long, color: Colors.green)
          : SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kWhitecolor)),
      wipExpense.status == ExpenseStatus.readyForReview
          ? 'Review and confirm the details extracted from your receipt'
          : wipExpense.getStatusDisplayText(),
    );
  }

  @override
  Widget build(BuildContext context) {
    String title = 'Edit Expense';

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: appBarTitleText(title),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () {
            Navigator.pop(context, {'expense': _baseExpense});
          },
        ),
        actions: [
          if (_baseExpense is WIPExpense)
            IconButton(
              icon: Icon(Icons.delete, color: kWhitecolor),
              onPressed: _deleteWIPExpense,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_baseExpense is WIPExpense) ...[
                wipExpenseBanner(_baseExpense as WIPExpense),
                if ((_baseExpense as WIPExpense).isRecoveryExpense != null) ...[...recoveryExpenseWidget()],
              ],

              // Receipt upload section
              buildReceiptSection(
                initialText: 'Tap to upload receipt',
                processingText: _baseExpense is WIPExpense ? (_baseExpense as WIPExpense).getStatusDisplayText() : "",
                mainFunction: _showImageSourceOptions,
                isProcessingImage:
                    _baseExpense is WIPExpense &&
                    [
                      ExpenseStatus.extractingData,
                      ExpenseStatus.uploadingReceipt,
                    ].contains((_baseExpense as WIPExpense).status) &&
                    (_baseExpense as WIPExpense).errorMessage == null,
                receiptImage: _receiptImage,
                receiptUrl: _receiptUrl,
                webImageBytes: _webImageBytes,
                onCloseFunction: () async {
                  if (_baseExpense is Expense) {
                    Expense expense = _baseExpense as Expense;
                    deleteReceipt(expense.receiptUrl);
                    expense.receiptUrl = null;
                    BaseExpense wipExpense = await convertExpenseToWIPExpense(expense) as BaseExpense;

                    setState(() {
                      _baseExpense = wipExpense;
                    });
                  }
                  setState(() {
                    _receiptImage = null;
                    _receiptUrl = null;
                    _webImageBytes = null;
                  });
                },
              ),
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
                      if (_selectedDate != null) ...[
                        customText(
                          DateFormat('MMM d, yyyy').format(_selectedDate!),
                          kTextColor,
                          defaultFontSize,
                          FontWeight.normal,
                        ),
                        Icon(Icons.calendar_today, color: primaryColor, size: 20),
                      ],
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

              // Attachments section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  renderPrimaryColorLabel(text: 'Attachments (Tags & Settlements)'),
                  IconButton(
                    icon: Icon(Icons.add_circle_outline, color: primaryColor),
                    onPressed: () => _openTagSelection(),
                    tooltip: 'Add/Edit Attachments',
                  ),
                ],
              ),
              SizedBox(height: 8),
              GestureDetector(
                onTap: () => _openTagSelection(),
                child: renderAttachmentsDisplay(
                  expenseTags: _baseExpense.tags,
                  settlements: _baseExpense.settlements,
                  recoveries: _baseExpense.recoveries, // NEW
                  allUserTags: _userTags,
                ),
              ),
              SizedBox(height: 20),

              // Notes field
              renderPrimaryColorLabel(text: 'Notes (Optional)'),
              SizedBox(height: 8),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: customUnderlineInputdecoration(hintText: 'Add any additional notes', bordersideColor: primaryColor),
              ),
              SizedBox(height: 32),

              // Save button
              _buildSaveButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    final buttonText = 'Save Updates';

    // NEW: Check if save should be disabled for WIPExpense with missing recovery amount
    final bool isSaveDisabled = _baseExpense is WIPExpense && (_baseExpense as WIPExpense).needsRecoveryAmount();

    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: (_isLoading || isSaveDisabled) ? null : _saveExpense,
        style: TextButton.styleFrom(
          backgroundColor: (_isLoading || isSaveDisabled) ? inactiveColor : primaryColor,
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
                      style: TextStyle(color: kWhitecolor, fontSize: 12, fontWeight: FontWeight.normal),
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

      setState(() {
        print('in _pickImage .. got file path ${image.path}');
        _receiptImage = File(image.path);
      });

      final imageBytes = await image.readAsBytes();

      if (kIsWeb) {
        _webImageBytes = imageBytes;
      }

      startReceiptUploadViaBackgroundTask(_baseExpense as WIPExpense).then((WIPExpense updatedExpense) {
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (context) => HomeScreen(expenseAsParam: updatedExpense)));
      });
    } catch (e) {
      print('Error picking image: $e');
      if (mounted) {
        showError(context, 'Failed to pick image');
      }
    }
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

  Future<void> _openTagSelection() async {
    // Prepare initial attachments data
    Map<Tag, TagStatus> initialTags = {};
    Map<Tag, SettlementEntry> initialSettlementData = {};
    Map<Tag, RecoveryEntry> initialRecoveryData = {};

    // Add regular expense tags
    for (Tag tag in _baseExpense.tags) {
      initialTags[tag] = TagStatus.expense;
    }

    // Add recoveries tags
    for (RecoveryEntry recovery in _baseExpense.recoveries) {
      final tag = await getTagData(recovery.tagId!);

      initialTags[tag] = TagStatus.expense;
      initialRecoveryData[tag] = recovery;
    }

    // Add settlement tags
    for (SettlementEntry settlement in _baseExpense.settlements) {
      final tag = await getTagData(settlement.tagId!);

      initialTags[tag] = TagStatus.settlement;
      initialSettlementData[tag] = settlement;
    }

    print("Calling TagSelectionScreen with ${_baseExpense.id}");
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TagSelectionScreen(
          expense: _baseExpense,
          initialAttachments: initialTags,
          initialSettlementData: initialSettlementData,
          initialRecoveryData: initialRecoveryData,
        ),
      ),
    );
    print("ExpenseDetailScreen: Back from TagSelection with result $result");

    if (result != null && result is Map<String, dynamic>) {
      setState(() {
        _baseExpense.tags = result['tags'] as Set<Tag>;
        _baseExpense.settlements = result['settlements'] as List<SettlementEntry>;
        _baseExpense.recoveries = result['recoveries'] as List<RecoveryEntry>;
      });
    }
  }

  Future<void> _saveExpense() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedDate == null) {
      showError(context, 'Expense date is empty.');
      return;
    }

    final transactionDateTime = DateTime(
      _selectedDate!.year,
      _selectedDate!.month,
      _selectedDate!.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    final String txId = "${_amountController.text}_${DateFormat('MMM-d-yy-h:mm-a').format(transactionDateTime)}";

    final kilvishUser = await getLoggedInUserData();
    if (kilvishUser == null) {
      if (mounted) showError(context, "No logged in user found");
      return;
    }
    if (kilvishUser.expenseAlreadyExist(txId)) {
      if (mounted) showError(context, "An expense with amount & time already exists. Stopping the import");
      return;
    }

    setState(() {
      _isLoading = true;
      _saveStatus = '';
    });

    try {
      String? uploadedReceiptUrl = _receiptUrl;

      final expenseData = {
        'to': _toController.text,
        'amount': double.parse(_amountController.text),
        'timeOfTransaction': Timestamp.fromDate(transactionDateTime),
        'notes': _notesController.text.isNotEmpty ? _notesController.text : null,
        'receiptUrl': uploadedReceiptUrl,
        'updatedAt': FieldValue.serverTimestamp(),
        'txId': txId,
        'createdAt': _baseExpense.createdAt,
      };

      String? tagId;

      if ((_baseExpense as WIPExpense).isRecoveryExpense != null) {
        if (_recoveryTagNameController.text.isEmpty || _recoveryAmountController.text.isEmpty) {
          showError(context, "Recovery is checked but one or more field is empty. Fix those & retry");
          return;
        }

        setState(() => _saveStatus = 'Creating recovery tag ...');

        final recoveryAmount = double.tryParse(_recoveryAmountController.text) ?? 0;

        tagId = await createRecoveryTag(tagName: _recoveryTagNameController.text);

        // Update local base expense
        final recoveryEntry = RecoveryEntry(tagId: tagId, amount: recoveryAmount);
        _baseExpense.recoveries.add(recoveryEntry);
      }

      Expense? expense = await updateExpense(expenseData, _baseExpense);

      if (_baseExpense is WIPExpense) {
        final localReceiptPath = _baseExpense.localReceiptPath;
        if (localReceiptPath != null) {
          File file = File(localReceiptPath);
          if (file.existsSync()) {
            file
                .delete()
                .then((value) {
                  print("$localReceiptPath successfully deleted");
                })
                .onError((e, stackTrace) {
                  print("Error deleting $localReceiptPath - $e, $stackTrace");
                });
          }
        }
      }
      kilvishUser.addToUserTxIds(txId);

      if (expense == null) {
        showError(context, "Changes can not be saved");
      } else {
        if ((_baseExpense as WIPExpense).isRecoveryExpense != null) {
          Navigator.pop(context, {'expense': expense, 'tag': await getTagData(tagId!)});
        }
        Navigator.pop(context, {'expense': expense});
      }
    } catch (e, stackTrace) {
      print('Error saving expense: $e $stackTrace');
      if (mounted) showError(context, 'Failed to save expense');
    } finally {
      setState(() {
        _isLoading = false;
        _saveStatus = '';
      });
    }
  }

  Future<void> _deleteWIPExpense() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete Draft', style: TextStyle(color: kTextColor)),
          content: Text('Are you sure you want to delete this draft expense?', style: TextStyle(color: kTextMedium)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: TextStyle(color: kTextMedium)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);

    try {
      await deleteWIPExpense(_baseExpense);
      if (mounted) {
        showSuccess(context, 'Draft deleted successfully');
        Navigator.pop(context, {'expense': null});
      }
    } catch (e, stackTrace) {
      print('Error deleting WIPExpense: $e, $stackTrace');
      if (mounted) showError(context, 'Failed to delete draft');
    } finally {
      setState(() => _isLoading = false);
    }
  }
}
