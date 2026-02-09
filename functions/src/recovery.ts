import {
  onDocumentCreated,
  onDocumentDeleted,
  FirestoreEvent,
} from "firebase-functions/v2/firestore"
import { kilvishDb } from "./common"
import { FieldValue } from "firebase-admin/firestore"
import * as admin from "firebase-admin"

/**
 * Helper: Get FCM tokens for recovery users (excluding a specific user)
 */
async function _getRecoveryUserTokens(
  recoveryId: string,
  excludeUserId?: string
): Promise<{ tokens: string[]; expenseOwnerToken?: string }> {
  const recoveryDoc = await kilvishDb.collection("Recoveries").doc(recoveryId).get()
  if (!recoveryDoc.exists) {
    return { tokens: [] }
  }

  const recoveryData = recoveryDoc.data()
  if (!recoveryData) {
    return { tokens: [] }
  }

  const sharedWith = recoveryData.sharedWith as string[]
  if (!sharedWith || sharedWith.length === 0) {
    return { tokens: [] }
  }

  const usersSnapshot = await kilvishDb.collection("Users").where(admin.firestore.FieldPath.documentId(), "in", sharedWith).get()

  const tokens: string[] = []
  let expenseOwnerToken: string | undefined = undefined

  usersSnapshot.forEach((doc) => {
    const userData = doc.data()
    if (doc.id == excludeUserId && userData.fcmToken) {
      expenseOwnerToken = userData.fcmToken
    }
    if (doc.id !== excludeUserId && userData.fcmToken) {
      tokens.push(userData.fcmToken)
    }
  })

  return { tokens, expenseOwnerToken }
}

/**
 * Update Recovery aggregates when an expense is created
 */
export const onRecoveryExpenseCreated = onDocumentCreated(
  {
    document: "Recoveries/{recoveryId}/Expenses/{expenseId}",
    region: "asia-south1",
  },
  async (event: FirestoreEvent<any>) => {
    const expenseData = event.data?.data()
    if (!expenseData) return

    const recoveryId = event.params.recoveryId
    const ownerId = expenseData.ownerId
    const amount = expenseData.amount || 0
    const totalRecoveryAmount = expenseData.totalRecoveryAmount || 0
    const timeOfTransaction = expenseData.timeOfTransaction

    // Get month key in YYYY-MM format
    const date = timeOfTransaction.toDate()
    const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`

    const recoveryRef = kilvishDb.collection("Recoveries").doc(recoveryId)

    // Update totals
    await recoveryRef.update({
      "totalTillDate.expense": FieldValue.increment(amount),
      "totalTillDate.recovery": FieldValue.increment(totalRecoveryAmount),
      [`userWiseTotal.${ownerId}.expense`]: FieldValue.increment(amount),
      [`userWiseTotal.${ownerId}.recovery`]: FieldValue.increment(totalRecoveryAmount),
      [`monthWiseTotal.${monthKey}.totalExpense`]: FieldValue.increment(amount),
      [`monthWiseTotal.${monthKey}.totalRecovery`]: FieldValue.increment(totalRecoveryAmount),
      [`monthWiseTotal.${monthKey}.${ownerId}.expense`]: FieldValue.increment(amount),
      [`monthWiseTotal.${monthKey}.${ownerId}.recovery`]: FieldValue.increment(totalRecoveryAmount),
    })

    // Send FCM notifications
    const { tokens } = await _getRecoveryUserTokens(recoveryId, ownerId)
    if (tokens.length > 0) {
      const recoveryDoc = await recoveryRef.get()
      const recoveryName = recoveryDoc.data()?.name || "Recovery"

      await admin.messaging().sendEachForMulticast({
        tokens,
        data: {
          type: "recovery_expense_created",
          recoveryId,
          expenseId: event.params.expenseId,
        },
        notification: {
          title: `New expense in ${recoveryName}`,
          body: `${expenseData.to}: ₹${amount}`,
        },
      })
    }

    console.log(`Updated Recovery ${recoveryId} totals for expense creation`)
  }
)

/**
 * Update Recovery aggregates when a settlement is created
 */
export const onRecoverySettlementCreated = onDocumentCreated(
  {
    document: "Recoveries/{recoveryId}/Settlements/{settlementId}",
    region: "asia-south1",
  },
  async (event: FirestoreEvent<any>) => {
    const settlementData = event.data?.data()
    if (!settlementData) return

    const recoveryId = event.params.recoveryId
    const settlements = settlementData.settlements || []
    
    if (settlements.length === 0) return

    const settlement = settlements[0] // Settlement entry
    const payerId = settlementData.ownerId
    const recipientId = settlement.to
    const amount = settlementData.amount || 0
    const timeOfTransaction = settlementData.timeOfTransaction

    const date = timeOfTransaction.toDate()
    const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`

    const recoveryRef = kilvishDb.collection("Recoveries").doc(recoveryId)

    // Payer's expense increases, recipient's recovery decreases
    await recoveryRef.update({
      "totalTillDate.recovery": FieldValue.increment(-amount),
      [`userWiseTotal.${payerId}.expense`]: FieldValue.increment(amount),
      [`userWiseTotal.${recipientId}.recovery`]: FieldValue.increment(-amount),
      [`monthWiseTotal.${monthKey}.totalExpense`]: FieldValue.increment(amount),
      [`monthWiseTotal.${monthKey}.totalRecovery`]: FieldValue.increment(-amount),
      [`monthWiseTotal.${monthKey}.${payerId}.expense`]: FieldValue.increment(amount),
      [`monthWiseTotal.${monthKey}.${recipientId}.recovery`]: FieldValue.increment(-amount),
    })

    // Send FCM notifications to recipient
    const { tokens } = await _getRecoveryUserTokens(recoveryId, payerId)
    if (tokens.length > 0) {
      const recoveryDoc = await recoveryRef.get()
      const recoveryName = recoveryDoc.data()?.name || "Recovery"

      await admin.messaging().sendEachForMulticast({
        tokens,
        data: {
          type: "recovery_settlement_created",
          recoveryId,
          settlementId: event.params.settlementId,
        },
        notification: {
          title: `Settlement in ${recoveryName}`,
          body: `Payment received: ₹${amount}`,
        },
      })
    }

    console.log(`Updated Recovery ${recoveryId} totals for settlement creation`)
  }
)

/**
 * Update Recovery aggregates when an expense is deleted
 */
export const onRecoveryExpenseDeleted = onDocumentDeleted(
  {
    document: "Recoveries/{recoveryId}/Expenses/{expenseId}",
    region: "asia-south1",
  },
  async (event: FirestoreEvent<any>) => {
    const expenseData = event.data?.data()
    if (!expenseData) return

    const recoveryId = event.params.recoveryId
    const ownerId = expenseData.ownerId
    const amount = expenseData.amount || 0
    const totalRecoveryAmount = expenseData.totalRecoveryAmount || 0
    const timeOfTransaction = expenseData.timeOfTransaction

    const date = timeOfTransaction.toDate()
    const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`

    const recoveryRef = kilvishDb.collection("Recoveries").doc(recoveryId)

    // Reverse the increments
    await recoveryRef.update({
      "totalTillDate.expense": FieldValue.increment(-amount),
      "totalTillDate.recovery": FieldValue.increment(-totalRecoveryAmount),
      [`userWiseTotal.${ownerId}.expense`]: FieldValue.increment(-amount),
      [`userWiseTotal.${ownerId}.recovery`]: FieldValue.increment(-totalRecoveryAmount),
      [`monthWiseTotal.${monthKey}.totalExpense`]: FieldValue.increment(-amount),
      [`monthWiseTotal.${monthKey}.totalRecovery`]: FieldValue.increment(-totalRecoveryAmount),
      [`monthWiseTotal.${monthKey}.${ownerId}.expense`]: FieldValue.increment(-amount),
      [`monthWiseTotal.${monthKey}.${ownerId}.recovery`]: FieldValue.increment(-totalRecoveryAmount),
    })

    console.log(`Updated Recovery ${recoveryId} totals for expense deletion`)
  }
)

/**
 * Update Recovery aggregates when a settlement is deleted
 */
export const onRecoverySettlementDeleted = onDocumentDeleted(
  {
    document: "Recoveries/{recoveryId}/Settlements/{settlementId}",
    region: "asia-south1",
  },
  async (event: FirestoreEvent<any>) => {
    const settlementData = event.data?.data()
    if (!settlementData) return

    const recoveryId = event.params.recoveryId
    const settlements = settlementData.settlements || []
    
    if (settlements.length === 0) return

    const settlement = settlements[0]
    const payerId = settlementData.ownerId
    const recipientId = settlement.to
    const amount = settlementData.amount || 0
    const timeOfTransaction = settlementData.timeOfTransaction

    const date = timeOfTransaction.toDate()
    const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`

    const recoveryRef = kilvishDb.collection("Recoveries").doc(recoveryId)

    // Reverse the settlement
    await recoveryRef.update({
      "totalTillDate.recovery": FieldValue.increment(amount),
      [`userWiseTotal.${payerId}.expense`]: FieldValue.increment(-amount),
      [`userWiseTotal.${recipientId}.recovery`]: FieldValue.increment(amount),
      [`monthWiseTotal.${monthKey}.totalExpense`]: FieldValue.increment(-amount),
      [`monthWiseTotal.${monthKey}.totalRecovery`]: FieldValue.increment(amount),
      [`monthWiseTotal.${monthKey}.${payerId}.expense`]: FieldValue.increment(-amount),
      [`monthWiseTotal.${monthKey}.${recipientId}.recovery`]: FieldValue.increment(amount),
    })

    console.log(`Updated Recovery ${recoveryId} totals for settlement deletion`)
  }
)