import {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
  onDocumentWritten,
} from "firebase-functions/v2/firestore"
import * as admin from "firebase-admin"
import { inspect } from "util"
import { kilvishDb } from "./common"
import {
  _notifyExpenseAction,
  _getTagUserTokens,
  _updateLastFCMSentAt,
  sendSingleFCM,
  scheduleExpenseMemberFCM,
} from "./fcm_notification"

export function _monthKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`
}

type RecipientEntry = { amount: number; settlementMonth?: string }
type RecipientsMap = Record<string, RecipientEntry>

// Accumulates numeric deltas and commits them as atomic FieldValue.increment calls.
// acrossUsers is derived client-side — never written here.
export class TagStatsUpdate {
  private deltas: Record<string, number> = {}

  applyDelta(userId: string, monthKey: string, field: string, delta: number): this {
    this._add(`total.${userId}.${field}`, delta)
    this._add(`monthWiseTotal.${monthKey}.${userId}.${field}`, delta)
    return this
  }

  // Initialises total.{userId}.* to 0 (no-op if they already exist).
  initUser(userId: string): this {
    for (const f of ["spent", "myShare", "received", "paid"]) {
      this._add(`total.${userId}.${f}`, 0)
    }
    return this
  }

  private _add(key: string, delta: number): void {
    this.deltas[key] = (this.deltas[key] ?? 0) + delta
  }

  async commit(
    tagDocRef: admin.firestore.DocumentReference,
    batch?: admin.firestore.WriteBatch
  ): Promise<void> {
    if (Object.keys(this.deltas).length === 0) return
    const data: Record<string, any> = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }
    for (const [key, delta] of Object.entries(this.deltas)) {
      data[key] = admin.firestore.FieldValue.increment(delta)
    }

    // TODO: remove after all clients have migrated to the new model.
    // Keeps legacy `expense` and `recovery` fields in sync for old app versions.
    for (const [key, delta] of Object.entries(this.deltas)) {
      const parts = key.split(".")
      const field = parts[parts.length - 1]
      const prefix = parts.slice(0, -1).join(".")
      const expDelta =
        field === "spent" || field === "paid" ? delta : field === "received" ? -delta : 0
      const recDelta =
        field === "spent" || field === "paid"
          ? delta
          : field === "received" || field === "myShare"
          ? -delta
          : 0
      if (expDelta !== 0) data[`${prefix}.expense`] = admin.firestore.FieldValue.increment(expDelta)
      if (recDelta !== 0) data[`${prefix}.recovery`] = admin.firestore.FieldValue.increment(recDelta)
    }

    if (batch) {
      batch.update(tagDocRef, data)
    } else {
      await tagDocRef.update(data)
    }
  }
}

// Computes the full tag-stats contribution of one expense snapshot.
// sign = +1 to apply, -1 to undo.
// Recipients map is empty ({}) in simple mode; non-empty in advanced mode.
function _applyExpenseContribution(
  update: TagStatsUpdate,
  expenseData: any,
  recipients: RecipientsMap,
  allMembers: string[],
  sign: 1 | -1
): void {
  const ownerId: string = expenseData.ownerId
  const expenseAmount: number = (expenseData.expenseAmount ?? expenseData.amount) as number
  const expenseMonth = _monthKey(
    (expenseData.timeOfTransaction as admin.firestore.Timestamp).toDate()
  )

  update.applyDelta(ownerId, expenseMonth, "spent", sign * expenseAmount)

  const recipientEntries = Object.entries(recipients)

  if (recipientEntries.length === 0) {
    // Simple mode: equal split among stamped participants, falling back to current members.
    const participants: string[] = expenseData.simpleParticipants?.length
      ? expenseData.simpleParticipants
      : allMembers
    const N = participants.length
    if (N > 0) {
      for (const participantId of participants) {
        update.applyDelta(participantId, expenseMonth, "myShare", (sign * expenseAmount) / N)
      }
    }
  } else {
    for (const [recipientId, entry] of recipientEntries) {
      if (entry.settlementMonth) {
        // Settlement: reverse debtor's spent in filing month; apply paid/received in settlement month.
        update
          .applyDelta(ownerId, expenseMonth, "spent", -sign * entry.amount)
          .applyDelta(ownerId, entry.settlementMonth, "paid", sign * entry.amount)
          .applyDelta(recipientId, entry.settlementMonth, "received", sign * entry.amount)
      } else {
        update.applyDelta(recipientId, expenseMonth, "myShare", sign * entry.amount)
      }
    }
  }
}

// Returns true only when a change affects tag stats or FCM-worthy content.
// Changes to fcmETag, updatedBy, updatedAt, or other metadata return false.
function _hasSignificantChange(before: any, after: any): boolean {
  const beforeMonth = _monthKey(
    (before.timeOfTransaction as admin.firestore.Timestamp).toDate()
  )
  const afterMonth = _monthKey(
    (after.timeOfTransaction as admin.firestore.Timestamp).toDate()
  )
  return (
    (before.expenseAmount ?? before.amount) !== (after.expenseAmount ?? after.amount) ||
    beforeMonth !== afterMonth ||
    JSON.stringify(before.recipients ?? {}) !== JSON.stringify(after.recipients ?? {}) ||
    JSON.stringify(before.simpleParticipants ?? []) !== JSON.stringify(after.simpleParticipants ?? [])
  )
}

// Patches a single key in the parent Expense's recipients map.
// No stats work — onExpenseUpdated handles that via the map diff.
export const onRecipientWritten = onDocumentWritten(
  {
    document: "Tags/{tagId}/Expenses/{expenseId}/Recipients/{recipientId}",
    region: "asia-south1",
    database: "kilvish",
  },
  async (event) => {
    console.log(`onRecipientWritten ${inspect(event.params)}`)
    const { tagId, expenseId, recipientId } = event.params
    const after = event.data?.after.data()
    const expenseRef = kilvishDb
      .collection("Tags")
      .doc(tagId)
      .collection("Expenses")
      .doc(expenseId)

    if (after) {
      const entry: RecipientEntry = {
        amount: after.amount as number,
        ...(after.settlementMonth ? { settlementMonth: after.settlementMonth as string } : {}),
      }
      await expenseRef.update({ [`recipients.${recipientId}`]: entry })
    } else {
      await expenseRef.update({
        [`recipients.${recipientId}`]: admin.firestore.FieldValue.delete(),
      })
    }
  }
)

export const onExpenseCreated = onDocumentCreated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`onExpenseCreated ${inspect(event.params)}`)
    const { tagId, expenseId } = event.params
    const data = event.data?.data()
    if (!data) return

    const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
    const tagDoc = await tagDocRef.get()
    if (!tagDoc.exists) throw new Error(`Tag ${tagId} does not exist`)
    const tagData = tagDoc.data()!
    const tagName: string = tagData.name ?? tagId
    const allMembers: string[] = [tagData.ownerId, ...(tagData.sharedWith ?? [])]

    const update = new TagStatsUpdate()
    _applyExpenseContribution(update, data, {}, allMembers, 1)

    // Stamp simple-mode metadata and initialise empty recipients map.
    const expenseRef = tagDocRef.collection("Expenses").doc(expenseId)
    const batch = kilvishDb.batch()
    batch.update(expenseRef, { isSimpleMode: true, simpleParticipants: allMembers, recipients: {} })
    await update.commit(tagDocRef, batch)
    await batch.commit()

    await _notifyExpenseAction("expense_created", { tagId, expenseId }, data, tagName)
  }
)

export const onExpenseUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`onExpenseUpdated ${inspect(event.params)}`)
    const { tagId, expenseId } = event.params
    const beforeData = event.data?.before.data()
    const afterData = event.data?.after.data()
    if (!beforeData || !afterData) return
    if (!_hasSignificantChange(beforeData, afterData)) return

    const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
    const tagDoc = await tagDocRef.get()
    if (!tagDoc.exists) throw new Error(`Tag ${tagId} does not exist`)
    const tagData = tagDoc.data()!
    const tagName: string = tagData.name ?? tagId
    const allMembers: string[] = [tagData.ownerId, ...(tagData.sharedWith ?? [])]

    // Full before→after diff: undo old contribution, apply new contribution.
    const update = new TagStatsUpdate()
    _applyExpenseContribution(update, beforeData, beforeData.recipients ?? {}, allMembers, -1)
    _applyExpenseContribution(update, afterData, afterData.recipients ?? {}, allMembers, 1)

    // Write stats + eTag atomically. The eTag guards the debounced member FCM task.
    const eTag = crypto.randomUUID()
    const expenseRef = tagDocRef.collection("Expenses").doc(expenseId)
    const batch = kilvishDb.batch()
    batch.update(expenseRef, { fcmETag: eTag })
    await update.commit(tagDocRef, batch)
    await batch.commit()

    // Silent immediate FCM to expense owner so their tag summary refreshes ASAP.
    const userTokens = await _getTagUserTokens(tagId, afterData.ownerId)
    if (userTokens?.expenseOwnerToken) {
      await _updateLastFCMSentAt([afterData.ownerId])
      await sendSingleFCM(afterData.ownerId, userTokens.expenseOwnerToken, {
        data: { type: "expense_updated", tagId, expenseId },
      })
    }

    // Debounced visible FCM to members (1-min delay, last-write-wins via eTag).
    await scheduleExpenseMemberFCM(tagId, expenseId, eTag, tagName, afterData)
  }
)

export const onExpenseDeleted = onDocumentDeleted(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`onExpenseDeleted ${inspect(event.params)}`)
    const { tagId, expenseId } = event.params
    const data = event.data?.data()
    if (!data) return

    const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
    const tagDoc = await tagDocRef.get()
    if (!tagDoc.exists) throw new Error(`Tag ${tagId} does not exist`)
    const tagData = tagDoc.data()!
    const tagName: string = tagData.name ?? tagId
    const allMembers: string[] = [tagData.ownerId, ...(tagData.sharedWith ?? [])]

    // Full reversal using the recipients map that was built up over the expense's lifetime.
    const update = new TagStatsUpdate()
    _applyExpenseContribution(update, data, data.recipients ?? {}, allMembers, -1)
    await update.commit(tagDocRef)

    await _notifyExpenseAction("expense_deleted", { tagId, expenseId }, data, tagName)
  }
)
