import { inspect } from 'util';
import { parseReceiptText, extractDataFromReceipt } from '../src/wipExpense'; // Ensure you add 'export' to the function in wipExpense.ts

describe('Receipt Parser', () => {
    jest.setTimeout(60000);

  test('Zerodha Receipt fetch', async () => {
    //const url = "https://github.com/tamraj-kilvish/kilvish/blob/ocr-azure-vision/assets/images/receipt.jpeg?raw=true";
    // cred receipt
    const url = "https://firebasestorage.googleapis.com/v0/b/tamraj-kilvish.firebasestorage.app/o/receipts%2Fdpuxymx146RtRjEXTqsK_LeiKAAb7nUQLrK9wwQyO.png?alt=media&token=9cfcecd8-673a-4fdb-9b8f-fda3b2715ff8";

    const result = await extractDataFromReceipt(url);
    console.log(result)
    // expect(result.amount).toBe(250);
    // expect(result.to).toBe('Starbucks');
  });


//   test('Zerodha Receipt field extraction', () => {
//     const text = 'Zerodha Broking Ltd requested money from ...\n' +
//         '₹80,000\n' +
//         'ga5cNWwYXQm27citZlbU94gbr\n' +
//         'Completed\n' +
//         '6 Jan 2026, 11:24 pm\n' +
//         'Kotak Mahindra Bank 7246\n' +
//         'V\n' +
//         'UPI transaction ID\n' +
//         '108927697233\n' +
//         'To: Zerodha Broking Limited\n' +
//         'zerodha.rzpiccl.brk@validicici\n' +
//         'From: PARTHVI RAMESHKUMAR VALA (Kotak\n' +
//         'Mahindra Bank)\n' +
//         'Google Pay . parthvi.vala@okhdfcbank\n' +
//         'Google transaction ID\n' +
//         'CICAgJjlw6nNPw\n' +
//         'POWERED BY\n' +
//         'UPIN\n' +
//         'UNIFIED PAYMENTS INTERFACE\n' +
//         'G Pay';
//     const result = parseReceiptText(text);
//     console.log(inspect(result));
//     // expect(result.amount).toBe(250);
//     // expect(result.to).toBe('Starbucks');
//   });


});