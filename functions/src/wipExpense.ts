// Add these imports at the top of index.ts
import axios from "axios"
import { FirestoreEvent, onDocumentUpdated } from 'firebase-functions/firestore'
import { kilvishDb } from "./common"
import * as admin from "firebase-admin"


// Add this Firebase Function to your index.ts

/**
 * Process WIPExpense receipt with OCR when receiptUrl is added
 */
export const processWIPExpenseReceipt = onDocumentUpdated(
  { document: "Users/{userId}/WIPExpenses/{wipExpenseId}", region: "asia-south1", database: "kilvish" },
  async ( event: FirestoreEvent<any>,) => {
    console.log(`Processing WIPExpense receipt: ${event.params.wipExpenseId}`)
    
    try {
      const beforeData = event.data?.before.data()
      const afterData = event.data?.after.data()

      if (!beforeData || !afterData) return

      // Trigger OCR only when:
      // 1. receiptUrl was just added
      // 2. Status is extractingData
      const receiptAdded = !beforeData.receiptUrl && afterData.receiptUrl
      const isExtracting = afterData.status === 'extractingData'

      if (!receiptAdded || !isExtracting) {
        console.log('Skipping OCR - conditions not met')
        return
      }

      const receiptUrl = afterData.receiptUrl as string
      console.log(`Starting OCR for receipt: ${receiptUrl}`)

      await notifyUserOfWIPExpenseUpdate(
        event.params.userId as string,
        event.params.wipExpenseId as string,
        'extractingData'
      )

      // Call Azure Vision API
      const ocrData = await extractDataFromReceipt(receiptUrl)

      if (!ocrData) {
        console.log('OCR extraction failed')
        await event.data.after.ref.update({
          status: 'uploadingReceipt',
          errorMessage: 'Failed to extract data from receipt',
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        })
        await notifyUserOfWIPExpenseUpdate(
          event.params.userId as string,
          event.params.wipExpenseId as string,
          'error'
        )
        return
      }

      // Update WIPExpense with extracted data
      const updateData: any = {
        status: 'readyForReview',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        errorMessage: admin.firestore.FieldValue.delete(),
      }

      if (ocrData.to) updateData.to = ocrData.to
      if (ocrData.amount) updateData.amount = ocrData.amount
      if (ocrData.timeOfTransaction) {
        updateData.timeOfTransaction = admin.firestore.Timestamp.fromDate(ocrData.timeOfTransaction)
      }

      await event.data.after.ref.update(updateData)

      console.log(`OCR complete for ${event.params.wipExpenseId}`)

      await notifyUserOfWIPExpenseUpdate(
        event.params.userId as string,
        event.params.wipExpenseId as string,
        'readyForReview'
      )

      // Send notification to user
      await notifyUserIfAllWIPExpensesReady(event.params.userId as string)

    } catch (error) {
      console.error('Error in processWIPExpenseReceipt:', error)
      
      // Update with error status
      try {
        await event.data?.after.ref.update({
          status: 'uploadingReceipt',
          errorMessage: `OCR processing failed: ${error}`,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        })
      } catch (updateError) {
        console.error('Failed to update error status:', updateError)
      }
    }
  }
)

/**
 * Extract data from receipt using Azure Vision API
 */
async function extractDataFromReceipt(receiptUrl: string): Promise<{
  to?: string
  amount?: number
  timeOfTransaction?: Date
} | null> {
  try {
    const azureEndpoint = process.env.AZURE_VISION_ENDPOINT
    const azureKey = process.env.AZURE_VISION_KEY

    if (!azureEndpoint || !azureKey) {
      console.error('Azure credentials not configured')
      return null
    }

    // Download image from URL
    const imageResponse = await axios.get(receiptUrl, { responseType: 'arraybuffer' })
    const imageBuffer = Buffer.from(imageResponse.data)

    // Call Azure Vision Read API
    const analyzeUrl = `${azureEndpoint}/vision/v3.2/read/analyze`
    
    const analyzeResponse = await axios.post(analyzeUrl, imageBuffer, {
      headers: {
        'Content-Type': 'application/octet-stream',
        'Ocp-Apim-Subscription-Key': azureKey,
      },
    })

    const operationLocation = analyzeResponse.headers['operation-location']
    if (!operationLocation) {
      console.error('No operation-location in response')
      return null
    }

    // Poll for results
    let extractedText = ''
    for (let i = 0; i < 10; i++) {
      await new Promise(resolve => setTimeout(resolve, 1000))

      const resultResponse = await axios.get(operationLocation, {
        headers: { 'Ocp-Apim-Subscription-Key': azureKey },
      })

      const status = resultResponse.data.status

      if (status === 'succeeded') {
        const analyzeResult = resultResponse.data.analyzeResult
        if (analyzeResult?.readResults) {
          const lines: string[] = []
          for (const page of analyzeResult.readResults) {
            for (const line of page.lines) {
              lines.push(line.text)
            }
          }
          extractedText = lines.join('\n')
        }
        break
      } else if (status === 'failed') {
        console.error('Azure Vision analysis failed')
        return null
      }
    }

    if (!extractedText) {
      console.error('No text extracted from receipt')
      return null
    }

    console.log('Extracted text:', extractedText)

    // Parse extracted text
    return parseReceiptText(extractedText)

  } catch (error) {
    console.error('Error in extractDataFromReceipt:', error)
    return null
  }
}

/**
 * Parse receipt text to extract fields
 */
function parseReceiptText(text: string): {
  to?: string
  amount?: number
  timeOfTransaction?: Date
} {
  const result: any = {}
  const lines = text.split('\n')

  // Extract amount - look for ₹ symbol
  const amountRegex = /₹\s*([\d,]+(?:\.\d{2})?)/g
  const amountMatches = Array.from(text.matchAll(amountRegex))

  if (amountMatches.length > 0) {
    let largestAmount = 0
    for (const match of amountMatches) {
      const amountStr = match[1].replace(/,/g, '')
      const value = parseFloat(amountStr)
      if (value > largestAmount) {
        largestAmount = value
      }
    }
    if (largestAmount > 0) {
      result.amount = largestAmount
    }
  }

  // Extract recipient name
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim()
    const lineLower = line.toLowerCase()

    if (lineLower === 'paid to' && i + 1 < lines.length) {
      let recipient = lines[i + 1].trim()
      if (recipient && !recipient.includes('@') && recipient.length > 2) {
        recipient = recipient.replace(/[^\w\s]/g, ' ').trim()
        recipient = recipient.replace(/\s+/g, ' ')
        result.to = recipient
        break
      }
    }

    if (lineLower.startsWith('to ') && !lineLower.includes('to:')) {
      let recipient = line.substring(3).trim()
      if (recipient && !recipient.includes('@') && recipient.length > 2) {
        recipient = recipient.replace(/[^\w\s]/g, ' ').trim()
        recipient = recipient.replace(/\s+/g, ' ')
        result.to = recipient
        break
      }
    }
  }

  // Extract date and time
  const datePattern1 = /(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4}),?\s*(\d{1,2}):(\d{2})\s*(am|pm)/i
  const datePattern2 = /(\d{1,2}):(\d{2})\s*(am|pm)\s+on\s+(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})/i

  let match = text.match(datePattern1)
  if (match) {
    const day = parseInt(match[1])
    const month = parseMonth(match[2])
    const year = parseInt(match[3])
    let hour = parseInt(match[4])
    const minute = parseInt(match[5])
    const amPm = match[6].toLowerCase()

    if (month !== null) {
      if (amPm === 'pm' && hour !== 12) hour += 12
      if (amPm === 'am' && hour === 12) hour = 0

      result.timeOfTransaction = new Date(year, month - 1, day, hour, minute)
    }
  } else {
    match = text.match(datePattern2)
    if (match) {
      let hour = parseInt(match[1])
      const minute = parseInt(match[2])
      const amPm = match[3].toLowerCase()
      const day = parseInt(match[4])
      const month = parseMonth(match[5])
      const year = parseInt(match[6])

      if (month !== null) {
        if (amPm === 'pm' && hour !== 12) hour += 12
        if (amPm === 'am' && hour === 12) hour = 0

        result.timeOfTransaction = new Date(year, month - 1, day, hour, minute)
      }
    }
  }

  return result
}

function parseMonth(monthStr: string): number | null {
  const months: { [key: string]: number } = {
    'january': 1, 'jan': 1,
    'february': 2, 'feb': 2,
    'march': 3, 'mar': 3,
    'april': 4, 'apr': 4,
    'may': 5,
    'june': 6, 'jun': 6,
    'july': 7, 'jul': 7,
    'august': 8, 'aug': 8,
    'september': 9, 'sep': 9,
    'october': 10, 'oct': 10,
    'november': 11, 'nov': 11,
    'december': 12, 'dec': 12,
  }
  return months[monthStr.toLowerCase()] || null
}

/**
 * Send silent notification for individual WIPExpense status update
 */
async function notifyUserOfWIPExpenseUpdate(
  userId: string,
  wipExpenseId: string,
  status: string
) {
  try {
    const userDoc = await kilvishDb.collection('Users').doc(userId).get()
    const userData = userDoc.data()
    
    if (!userData?.fcmToken) {
      console.log('No FCM token for user')
      return
    }

    // Send SILENT data-only message (no notification field)
    await admin.messaging().send({
      token: userData.fcmToken,
      data: {
        type: 'wip_status_update',
        wipExpenseId: wipExpenseId,
        status: status,
      },
    })

    console.log(`Silent status update sent for WIPExpense ${wipExpenseId}: ${status}`)
  } catch (error) {
    console.error('Error sending status update:', error)
  }
}

/**
 * Check if ALL WIPExpenses are ready, then send notification
 */
async function notifyUserIfAllWIPExpensesReady(userId: string) {
  try {
    const wipSnapshot = await kilvishDb
      .collection('Users')
      .doc(userId)
      .collection('WIPExpenses')
      .get()

    const allDocs = wipSnapshot.docs
    const readyDocs = allDocs.filter(doc => doc.data().status === 'readyForReview')
    const processingDocs = allDocs.filter(doc => 
      doc.data().status === 'uploadingReceipt' || 
      doc.data().status === 'extractingData'
    )

    // Only send notification if all are ready (none processing)
    if (readyDocs.length > 0 && processingDocs.length === 0) {
      const userDoc = await kilvishDb.collection('Users').doc(userId).get()
      const userData = userDoc.data()
      
      if (!userData?.fcmToken) return

      await admin.messaging().send({
        token: userData.fcmToken,
        notification: {
          title: 'Receipts Ready for Review',
          body: `${readyDocs.length} expense${readyDocs.length > 1 ? 's are' : ' is'} ready for your review`,
        },
        data: {
          type: 'wip_ready',
          count: readyDocs.length.toString(),
        },
      })

      console.log(`All-ready notification sent: ${readyDocs.length} WIPExpenses`)
    }
  } catch (error) {
    console.error('Error checking all WIPExpenses ready:', error)
  }
}