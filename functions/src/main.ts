import { onCall, HttpsError } from "firebase-functions/v2/https"
import {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
  onDocumentWritten,
  FirestoreEvent,
} from "firebase-functions/v2/firestore"
import * as admin from "firebase-admin"
import { inspect } from "util"
import { kilvishDb } from "./common"
import {
  _getKilvishId,
  _parseUpdatedBy,
  _getTagUserTokens,
  _notifyExpenseAction,
  _notifyUserOfTagShared,
  _notifyOtherMembersOfTagChange,
} from "./fcm_notification"

export const getUserByPhone = onCall(
  {
    region: "asia-south1",
    invoker: "public",
    cors: true,
  },
  async (request) => {
    console.log("Entering getUserByPhone")
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "User must be authenticated to call this function.")
    }

    const { phoneNumber } = request.data
    const uid = request.auth.uid

    if (!phoneNumber) {
      throw new HttpsError("invalid-argument", "Phone number is required.")
    }

    try {
      const userQuery = await kilvishDb.collection("Users").where("phone", "==", phoneNumber).limit(1).get()

      if (userQuery.empty) {
        console.log(`Creating new user for phone ${phoneNumber}`)
        const authUser = await admin.auth().getUser(uid)
        if (authUser.phoneNumber !== phoneNumber) {
          throw new HttpsError("permission-denied", "You can only create your own user data.")
        }

        const newUserRef = kilvishDb.collection("Users").doc()
        const newUserData = {
          uid: uid,
          phone: phoneNumber,
          accessibleTagIds: [],
        }

        await newUserRef.set(newUserData)
        await admin.auth().setCustomUserClaims(uid, { userId: newUserRef.id })

        console.log(`New user created with ID ${newUserRef.id}`)

        return { success: true, user: { id: newUserRef.id, ...newUserData } }
      }

      const userDoc = userQuery.docs[0]
      const userData = userDoc.data()
      const userDocId = userDoc.id

      const authUser = await admin.auth().getUser(uid)
      if (authUser.phoneNumber !== phoneNumber) {
        throw new HttpsError("permission-denied", "You can only access your own user data.")
      }

      await kilvishDb.collection("Users").doc(userDocId).update({
        uid: uid,
      })

      await admin.auth().setCustomUserClaims(uid, { userId: userDocId })

      return { success: true, user: { id: userDocId, ...userData, uid: uid } }
    } catch (error) {
      console.error("Error in getUserByPhone:", error)
      if (error instanceof HttpsError) throw error
      throw new HttpsError("internal", "An internal error occurred.")
    }
  }
)

function _monthKey(date: Date): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, "0")
  return `${year}-${month}`
}

// Accumulates numeric deltas and commits them as atomic FieldValue.increment calls in one update.
// Numeric accumulation lets multiple applyDelta calls for the same key compose correctly
// (e.g. old-month decrement + new-month increment net to zero on total.* automatically).
// Pass "acrossUsers" as userId for the aggregate row.
class TagStatsUpdate {
  private deltas: Record<string, number> = {}

  // Updates total.{userId}.{field} and monthWiseTotal.{monthKey}.{userId}.{field},
  // and ensures the sibling field exists in monthWiseTotal (initialised to 0 if untouched).
  applyDelta(userId: string, monthKey: string, field: "expense" | "recovery", delta: number): this {
    const other = field === "expense" ? "recovery" : "expense"
    this._add(`total.${userId}.${field}`, delta)
    this._add(`monthWiseTotal.${monthKey}.${userId}.${field}`, delta)
    this._add(`monthWiseTotal.${monthKey}.${userId}.${other}`, 0)

    //update acrossUsers expense if update is of expense
    if (field === "expense" && userId != "acrossUsers") {
      this.applyDelta("acrossUsers", monthKey, "expense", delta)
    }
    return this
  }

  // Initialises total.{userId}.expense and total.{userId}.recovery to 0 (no-op if they exist).
  initUser(userId: string): this {
    this._add(`total.${userId}.expense`, 0)
    this._add(`total.${userId}.recovery`, 0)
    return this
  }

  private _add(key: string, delta: number): void {
    this.deltas[key] = (this.deltas[key] ?? 0) + delta
  }

  async commit(tagDocRef: admin.firestore.DocumentReference): Promise<void> {
    if (Object.keys(this.deltas).length === 0) return
    const data: Record<string, any> = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }
    for (const [key, delta] of Object.entries(this.deltas)) {
      data[key] = admin.firestore.FieldValue.increment(delta)
    }
    await tagDocRef.update(data)
  }
}

function _hasSignificantExpenseChange(before: Record<string, any>, after: Record<string, any>): boolean {
  const beforeMonth = _monthKey((before.timeOfTransaction as admin.firestore.Timestamp).toDate())
  const afterMonth = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())
  return before.amount !== after.amount || beforeMonth !== afterMonth
}

async function _processTagSummaryForExpenseOwnerContribution({
  data,
  tagId,
  isIncrement = true,
  update,
}: {
  data: any
  tagId: string
  isIncrement?: boolean
  update?: TagStatsUpdate
}): Promise<TagStatsUpdate> {
  const ownerId: string = data.ownerId
  const txTimestamp = data.timeOfTransaction as admin.firestore.Timestamp
  const monthKey = _monthKey(txTimestamp.toDate())
  const _update = update ?? new TagStatsUpdate()

  const amount = isIncrement ? data.amount : -data.amount
  _update.applyDelta(ownerId, monthKey, "expense", amount)

  if (!update) await _update.commit(kilvishDb.collection("Tags").doc(tagId))
  return _update
}

async function _updateTagMonetarySummaryStatsDueToExpense(
  event: FirestoreEvent<any>,
  eventType: string
): Promise<string | undefined> {
  const { tagId, expenseId } = event.params
  const before = eventType === "expense_updated" ? event.data?.before.data() : event.data?.data()
  if (!before) return

  const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
  const tagDoc = await tagDocRef.get()
  if (!tagDoc.exists) throw new Error(`Tag ${tagId} does not exist`)
  const tagName = tagDoc.data()?.name

  if (eventType === "expense_updated") {
    const after = event.data?.after.data()
    if (!after || !_hasSignificantExpenseChange(before, after)) return tagName
  }

  const txTimestamp = before.timeOfTransaction as admin.firestore.Timestamp
  const monthKey = _monthKey(txTimestamp.toDate())
  const update = new TagStatsUpdate()

  if (eventType === "expense_created") {
    await _processTagSummaryForExpenseOwnerContribution({ data: before, tagId: tagId })
    return tagName
  }

  if (eventType === "expense_deleted") {
    await _processTagSummaryForExpenseOwnerContribution({ data: before, tagId: tagId, isIncrement: false })
    return tagName
  }

  // expense_updated
  const after = event.data?.after.data()!
  const newMonthKey = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())

  await _processTagSummaryForExpenseOwnerContribution({ data: before, tagId: tagId, isIncrement: false, update: update })
  await _processTagSummaryForExpenseOwnerContribution({ data: after, tagId: tagId, update: update })

  if (monthKey !== newMonthKey) {
    // Recipients: old-month undo + new-month apply; their total.{userId}.recovery nets to zero.
    const recipientsSnap = await kilvishDb
      .collection("Tags")
      .doc(tagId)
      .collection("Expenses")
      .doc(expenseId)
      .collection("Recipients")
      .get()
    for (const doc of recipientsSnap.docs) {
      const recipientId = doc.id
      const recipientData = doc.data()

      // Settlement recipients track their own settlementMonth — onRecipientWritten handles them
      if (recipientData.settlementMonth) continue

      const amount: number = (recipientData.amount as number) || 0
      update
        .applyDelta(recipientId, monthKey, "recovery", amount)
        .applyDelta(recipientId, newMonthKey, "recovery", -amount)
    }
  }

  await update.commit(tagDocRef)
  return tagName
}

export const onExpenseCreated = onDocumentCreated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseCreated for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_created")
    if (tagName) await _notifyExpenseAction("expense_created", event.params, event.data?.data(), tagName)
  }
)

export const onExpenseUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseUpdated for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_updated")
    if (tagName != null) await _notifyExpenseAction("expense_updated", event.params, event.data?.after.data(), tagName)
  }
)

export const onExpenseDeleted = onDocumentDeleted(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseDeleted for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_deleted")
    if (tagName != null) await _notifyExpenseAction("expense_deleted", event.params, event.data?.data(), tagName)
  }
)

async function _updateRecipientContributionToTagSummary({
  data,
  expenseData,
  update,
  recipientId,
  isInvert = false,
}: {
  data: any
  expenseData: any
  update: TagStatsUpdate
  recipientId: string
  isInvert?: boolean
}) {
  const settlementMonth: string | undefined = data.settlementMonth
  const txTimestamp = expenseData.timeOfTransaction as admin.firestore.Timestamp
  const expenseMonth = _monthKey(txTimestamp.toDate())

  if (settlementMonth) {
    // Settlement: undo the expense owner's acrossUsers.expense contribution (settlement is between
    // two parties, not a group spend), and transfer recovery from recipient to owner.
    const amount = isInvert ? -data.amount : data.amount
    update
      .applyDelta(recipientId, settlementMonth, "expense", -amount)
      .applyDelta(recipientId, settlementMonth, "recovery", -amount)
      .applyDelta(expenseData.ownerId, settlementMonth, "recovery", amount)
  } else if (recipientId === expenseData.ownerId) {
    // Owner tracking their own share: owner.recovery = expense.amount - ownerShare.
    // Expressed as a delta so create/update/delete all compose correctly via the invert pattern.
    const ownerShare: number = data.amount ?? 0
    const outstanding: number = (expenseData.amount as number) - ownerShare
    const delta = isInvert ? -outstanding : outstanding
    update.applyDelta(recipientId, expenseMonth, "recovery", delta)
  } else {
    // Regular recipient: their recovery goes negative (they owe the owner).
    const amount = isInvert ? -data.amount : data.amount
    update.applyDelta(recipientId, expenseMonth, "recovery", -amount)
  }
}

/**
 * Update tag stats when a recipient entry changes.
 * Settlement detected from settlementMonth on the recipient doc; no isSettlement field on expense needed.
 */
export const onRecipientWritten = onDocumentWritten(
  { document: "Tags/{tagId}/Expenses/{expenseId}/Recipients/{recipientId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onRecipientWritten for params ${inspect(event.params)}`)
    const { tagId, expenseId, recipientId } = event.params
    const before = event.data?.before.data()
    const after = event.data?.after.data()

    const expenseDoc = await kilvishDb
      .collection("Tags")
      .doc(tagId)
      .collection("Expenses")
      .doc(expenseId)
      .get()
    if (!expenseDoc.exists) return

    const expenseData = expenseDoc.data()!
    const isSettlement = !!(after?.settlementMonth ?? before?.settlementMonth)

    const update = new TagStatsUpdate()
    if (before) await _updateRecipientContributionToTagSummary({ data: before, expenseData, update, recipientId, isInvert: true })
    if (after) await _updateRecipientContributionToTagSummary({ data: after, expenseData, update, recipientId })

    await update.commit(kilvishDb.collection("Tags").doc(tagId))
    console.log(`onRecipientWritten: ${recipientId} stats updated in tag ${tagId} (settlement=${isSettlement})`)

    // Fetch tag name for notification body
    const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
    const tagName: string = tagDoc.data()?.name || tagId

    // Determine action type
    const action = !before ? "create" : !after ? "delete" : "update"
    const recipientData = after ?? before
    const amount: number = recipientData?.amount || 0
    const recipientKilvishId: string | undefined = after?.recipientKilvishId ?? before?.recipientKilvishId

    // Parse actor (owner is always the writer of recipient docs)
    const rawUpdatedBy = after?.updatedBy ?? before?.updatedBy
    const { userId: actorId, kilvishId: ownerKilvishId } = await _parseUpdatedBy(rawUpdatedBy)

    // Broadcast to ALL tag members as expense_updated; owner gets silent FCM
    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
    if (!userTokens) return

    const { members, expenseOwnerToken } = userTokens
    const baseData: Record<string, string> = {
      type: "expense_updated",
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(ownerKilvishId && { actorKilvishId: ownerKilvishId }),
    }

    if (expenseOwnerToken) {
      await admin.messaging().send({ token: expenseOwnerToken, data: baseData })
    }

    if (members.length > 0) {
      let body: string
      const isOwnerRecipient = recipientId === expenseData.ownerId

      if (isOwnerRecipient) {
        body =
          action === "delete"
            ? `@${ownerKilvishId} is no more owed ₹${amount}`
            : `@${ownerKilvishId} is owed ₹${amount}`
      } else if (isSettlement) {
        body =
          action === "delete"
            ? `@${ownerKilvishId} has no more settled ₹${amount} with @${recipientKilvishId}`
            : `@${ownerKilvishId} settled ₹${amount} with @${recipientKilvishId}`
      } else {
        body =
          action === "delete"
            ? `@${recipientKilvishId} no more owes @${ownerKilvishId} ₹${amount}`
            : `@${recipientKilvishId} owes @${ownerKilvishId} ₹${amount}`
      }

      await admin.messaging().sendEachForMulticast({
        tokens: members.map((m) => m.token),
        notification: { title: `Tag: ${tagName}`, body },
        data: baseData,
      })
      console.log(`onRecipientWritten: ${action} → expense_updated "${tagName}: ${body}" sent to ${members.length} member(s)`)
    }
  }
)

function _setsAreEqual<T>(set1: Set<T>, set2: Set<T>): boolean {
  if (set1.size !== set2.size) return false
  for (const item of set1) {
    if (!set2.has(item)) return false
  }
  return true
}

async function _handleTagSharingChanges(
  tagId: string,
  beforeData: Record<string, any>,
  afterData: Record<string, any>
) {
  const beforeSharedWithFriends = (beforeData.sharedWithFriends as string[]) || []
  const afterSharedWithFriends = (afterData.sharedWithFriends as string[]) || []

  if (_setsAreEqual(new Set(beforeSharedWithFriends), new Set(afterSharedWithFriends))) return

  const addedUserFriends = afterSharedWithFriends.filter((id) => !beforeSharedWithFriends.includes(id) && id?.trim())
  const removedUserFriends = beforeSharedWithFriends.filter((id) => !afterSharedWithFriends.includes(id) && id?.trim())

  const addedUserIds: string[] = []
  for (const friendId of addedUserFriends) {
    const userId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(beforeData.ownerId, friendId)
    if (userId) addedUserIds.push(userId)
  }

  const removedUserIds: string[] = []
  for (const friendId of removedUserFriends) {
    const userId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(beforeData.ownerId, friendId)
    if (userId) removedUserIds.push(userId)
  }

  await _updateSharedWithOfTag(tagId, removedUserIds, addedUserIds)

  if (addedUserIds.length > 0) {
    const init = new TagStatsUpdate()
    for (const userId of addedUserIds) init.initUser(userId)
    await init.commit(kilvishDb.collection("Tags").doc(tagId))
  }

  const tagName = afterData.name || "Unknown"
  const ownerKilvishId = await _getKilvishId(beforeData.ownerId)

  for (const userId of addedUserIds) {
    await _notifyUserOfTagShared(userId, tagId, tagName, "tag_shared", ownerKilvishId)
    const memberKilvishId = await _getKilvishId(userId)
    await _notifyOtherMembersOfTagChange(tagId, tagName, beforeData.ownerId, userId, ownerKilvishId, memberKilvishId, "added")
  }

  for (const userId of removedUserIds) {
    const memberKilvishId = await _getKilvishId(userId)
    await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed", ownerKilvishId)
    await _notifyOtherMembersOfTagChange(tagId, tagName, beforeData.ownerId, userId, ownerKilvishId, memberKilvishId, "removed")
  }
}

async function _ifRecoveryChangedUpdateAcrossUsers(
  before: Record<string, any>,
  after: Record<string, any>,
  tagId: string
): Promise<boolean> {

  const beforeTotal = (before.total ?? {}) as Record<string, any>
  const afterTotal = (after.total ?? {}) as Record<string, any>
  const beforeMonthWise = (before.monthWiseTotal ?? {}) as Record<string, any>
  const afterMonthWise = (after.monthWiseTotal ?? {}) as Record<string, any>

 // Check whether any user-specific (non-acrossUsers) recovery value changed
  const userRecoveryChangedInTotal = Object.keys({ ...beforeTotal, ...afterTotal })
    .filter((k) => k !== "acrossUsers")
    .some((k) => (beforeTotal[k]?.recovery ?? 0) !== (afterTotal[k]?.recovery ?? 0))

  const allMonths = new Set([...Object.keys(beforeMonthWise), ...Object.keys(afterMonthWise)])
  let userRecoveryChangedInMonth = false
  for (const month of allMonths) {
    const bMonth = (beforeMonthWise[month] ?? {}) as Record<string, any>
    const aMonth = (afterMonthWise[month] ?? {}) as Record<string, any>
    if (
      Object.keys({ ...bMonth, ...aMonth })
        .filter((k) => k !== "acrossUsers")
        .some((k) => (bMonth[k]?.recovery ?? 0) !== (aMonth[k]?.recovery ?? 0))
    ) {
      userRecoveryChangedInMonth = true
      break
    }
  }

  if (userRecoveryChangedInTotal || userRecoveryChangedInMonth) {
    // Recalculate acrossUsers.recovery as sum of positive user recovery values.
    // Skip the write if the stored value is already correct (avoids a redundant trigger).
    const updates: Record<string, number> = {}

    const newTotalRecovery = Object.entries(afterTotal)
      .filter(([k]) => k !== "acrossUsers")
      .reduce((sum, [, v]) => sum + Math.max(0, (v as any).recovery ?? 0), 0)
    if (Math.abs(newTotalRecovery - (afterTotal.acrossUsers?.recovery ?? 0)) > 0.001)
      updates["total.acrossUsers.recovery"] = newTotalRecovery

    for (const month of Object.keys(afterMonthWise)) {
      const monthData = (afterMonthWise[month] ?? {}) as Record<string, any>
      const newMonthRecovery = Object.entries(monthData)
        .filter(([k]) => k !== "acrossUsers")
        .reduce((sum, [, v]) => sum + Math.max(0, (v as any).recovery ?? 0), 0)
      if (Math.abs(newMonthRecovery - (monthData.acrossUsers?.recovery ?? 0)) > 0.001)
        updates[`monthWiseTotal.${month}.acrossUsers.recovery`] = newMonthRecovery
    }

    if (Object.keys(updates).length > 0) {
      await kilvishDb.collection("Tags").doc(tagId).update(updates)
      console.log(`handleTagUpdate: acrossUsers.recovery recalculated for ${tagId}, exit`)
      return true; // Next trigger will send tag_updated FCM
    }
    // acrossUsers was already correct — fall through to send FCM now
  }
  return false;
 }

async function _handleTagDataChanges(
  tagId: string,
  before: Record<string, any>,
  after: Record<string, any>
) {

  if (await _ifRecoveryChangedUpdateAcrossUsers(before, after, tagId)){
    console.log(`handleTagUpdate: returning as recovery values were changed & acrossUsers values updated for tag ${tagId}`)
     return; //tag is updated with acrossUser.recovery & that would trigger _handleTagDataChanges again
  }
  
  const beforeTotal = (before.total ?? {}) as Record<string, any>
  const afterTotal = (after.total ?? {}) as Record<string, any>

  // Check if any display-relevant field changed
  const nameChanged = before.name !== after.name
  const totalChanged = Object.keys({ ...beforeTotal, ...afterTotal })
    .some((k) => 
      (beforeTotal[k]?.recovery ?? 0) !== (afterTotal[k]?.recovery ?? 0) || 
      (beforeTotal[k]?.expense ?? 0) !== (afterTotal[k]?.expense ?? 0))

  if (!nameChanged && !totalChanged) return

  const userTokens = await _getTagUserTokens(tagId, after.ownerId)
  if (!userTokens) return
  
  const { members, expenseOwnerToken } = userTokens
  let tokens = members.map((r: Record<string, string>) => r['token'])
  if (expenseOwnerToken) tokens.push(expenseOwnerToken)
 
  await admin.messaging().sendEachForMulticast(
    { tokens, data:  { type: "tag_updated", tagId, tagName: ""}}
  )
  
  console.log(`handleTagUpdate: tag_updated FCM sent to ${tokens.length} member(s) for tag ${tagId}`)
}

async function _updateSharedWithOfTag(tagId: string, removedUserIds: string[], addedUserIds: string[]) {
  try {
    console.log(
      `Entered _updateSharedWithOfTag for ${tagId}, removedUserIds ${inspect(removedUserIds)} adduserIds ${inspect(addedUserIds)}`
    )

    const docRef = kilvishDb.collection("Tags").doc(tagId)

    const tagDoc = await docRef.get()
    if (!tagDoc.exists) {
      throw new Error(`Tag ${tagId} does not exist`)
    }

    const tagData = tagDoc.data()
    let sharedWith: string[] = tagData?.sharedWith || []

    if (removedUserIds.length > 0) {
      sharedWith = sharedWith.filter((userId) => !removedUserIds.includes(userId))
    }

    if (addedUserIds.length > 0) {
      const uniqueAddedIds = addedUserIds.filter((userId) => !sharedWith.includes(userId))
      sharedWith = [...sharedWith, ...uniqueAddedIds]
    }

    await docRef.update({
      sharedWith: sharedWith,
    })
    console.log(`Updated sharedWith field of ${tagData?.name} with ${inspect(sharedWith)}`)
  } catch (e) {
    console.error(`Failed to update SharedWith of tag ${tagId} - ${e}`)
    throw new Error(`Failed to update sharedWith of ${tagId}`)
  }
}

export const handleTagAccessRemovalOnTagDelete = onDocumentDeleted(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Entering handleTagAccessRemovalOnTagDelete event params ${inspect(event.params)}`)
    try {
      const tagId = event.params.tagId
      const data = event.data?.data()

      if (!data) {
        console.log("data is empty so returning")
        return
      }

      const sharedWithFriends = (data.sharedWithFriends as string[]) || []
      if (sharedWithFriends.length == 0) {
        console.log("empty sharedWithFriends .. so returning")
        return
      }

      const removedUserIds: string[] = []
      for (const friendId of sharedWithFriends) {
        const friendUserId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(data.ownerId, friendId)
        if (friendUserId) removedUserIds.push(friendUserId)
      }

      const tagName = data.name || "Unknown"
      const ownerKilvishId = await _getKilvishId(data.ownerId)
      console.log(`Users removed from tag ${tagName}:`, removedUserIds)

      for (const userId of removedUserIds) {
        const memberKilvishId = await _getKilvishId(userId)
        await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed", ownerKilvishId)
        void memberKilvishId
      }
    } catch (error) {
      console.error("Error in handleTagAccessRemovalOnTagDelete:", error)
      throw error
    }
  }
)

export const handleTagSharingOnTagCreate = onDocumentCreated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Entering handleTagSharingOnTagCreate event params ${inspect(event.params)}`)
    try {
      const tagId = event.params.tagId
      const data = event.data?.data()

      if (!data) {
        console.log("data is empty so returning")
        return
      }

      const sharedWithFriends = (data.sharedWithFriends as string[]) || []
      if (sharedWithFriends.length == 0) {
        console.log("empty sharedWithFriends .. so returning")
        return
      }

      const addedUserIds: string[] = []
      for (const friendId of sharedWithFriends) {
        const friendUserId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(data.ownerId, friendId)
        if (friendUserId) addedUserIds.push(friendUserId)
      }

      await _updateSharedWithOfTag(tagId, [], addedUserIds)

      const tagName = data.name || "Unknown"
      const ownerKilvishId = await _getKilvishId(data.ownerId)
      console.log(`Users added to tag ${tagName}:`, addedUserIds)

      for (const userId of addedUserIds) {
        await _notifyUserOfTagShared(userId, tagId, tagName, "tag_shared", ownerKilvishId)
        const memberKilvishId = await _getKilvishId(userId)
        await _notifyOtherMembersOfTagChange(tagId, tagName, data.ownerId, userId, ownerKilvishId, memberKilvishId, "added")
      }
    } catch (error) {
      console.error("Error in handleTagSharingOnTagCreate:", error)
      throw error
    }
  }
)

export const handleTagUpdate = onDocumentUpdated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Entering handleTagUpdate for ${event.params.tagId}`)
    try {
      const tagId = event.params.tagId
      const beforeData = event.data?.before.data() as Record<string, any> | undefined
      const afterData = event.data?.after.data() as Record<string, any> | undefined
      if (!beforeData || !afterData) return

      await _handleTagSharingChanges(tagId, beforeData, afterData)
      await _handleTagDataChanges(tagId, beforeData, afterData)
    } catch (error) {
      console.error("Error in handleTagUpdate:", error)
      throw error
    }
  }
)

// Create User document if tag is shared with a user who has NOT signed up on Kilvish
// Also query & update kilvishId & other information of the user in Friend's doc
async function _registerFriendAsKilvishUserAndReturnKilvishUserId(
  ownerId: string,
  friendId: string,
  _friendData?: admin.firestore.DocumentData
): Promise<string | undefined> {
  console.log(
    `Entering _registerFriendAsKilvishUserAndReturnKilvishUserId with ownerId ${ownerId}, friendId ${friendId}`
  )
  let friendData = _friendData
  if (!friendData) {
    const friendDoc = await kilvishDb.collection("Users").doc(ownerId).collection("Friends").doc(friendId).get()
    friendData = friendDoc.data()
  }
  let kilvishUserId = friendData?.kilvishUserId as string | undefined
  if (kilvishUserId) {
    console.log(`kilvishUserId ${friendData!.kilvishUserId} exist for ${friendId} .. exiting`)
    return kilvishUserId
  }

  const phoneNumber = friendData?.phoneNumber as string | undefined
  if (!phoneNumber) {
    console.log("No phone number in friend document, skipping")
    return
  }

  console.log(
    `New friend added for user ${ownerId}: ${friendId} with phone ${phoneNumber}. Trying to find the user, if not found, create one`
  )

  const userQuery = await kilvishDb.collection("Users").where("phone", "==", phoneNumber).limit(1).get()

  if (!userQuery.empty) {
    const existingUserDoc = userQuery.docs[0]
    kilvishUserId = existingUserDoc.id
    console.log(`User ${kilvishUserId} already exists for phone ${phoneNumber}`)
  } else {
    console.log(`Creating new User for phone ${phoneNumber}`)

    const newUserData = {
      phone: phoneNumber,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      accessibleTagIds: [],
    }

    const docRef = await kilvishDb.collection("Users").add(newUserData)
    kilvishUserId = docRef.id

    console.log(`Successfully created user ${docRef.id}`)
  }

  await kilvishDb.collection("Users").doc(ownerId).collection("Friends").doc(friendId).update({
    kilvishUserId: kilvishUserId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  })

  console.log(`Updated friend ${friendId} with kilvishUserId: ${kilvishUserId}`)
  return kilvishUserId
}
