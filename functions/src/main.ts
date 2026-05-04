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
// Initialize Firebase Admin
import { kilvishDb } from "./common"

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

          //   createdAt: admin.firestore.FieldValue.serverTimestamp(),
          //   lastLogin: admin.firestore.FieldValue.serverTimestamp(),
        }

        await newUserRef.set(newUserData)
        await admin.auth().setCustomUserClaims(uid, { userId: newUserRef.id })

        // await kilvishDb.collection("PublicInfo").doc(newUserRef.id).set({
        //   createdAt: admin.firestore.FieldValue.serverTimestamp(),
        // })

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

      //   const publicInfoDoc = await kilvishDb.collection("PublicInfo").doc(userDocId).get()
      //   if (!publicInfoDoc.exists) {
      //     await kilvishDb.collection("PublicInfo").doc(userDocId).set({
      //       createdAt: admin.firestore.FieldValue.serverTimestamp(),
      //     })
      //   }

      await admin.auth().setCustomUserClaims(uid, { userId: userDocId })

      return { success: true, user: { id: userDocId, ...userData, uid: uid } }
    } catch (error) {
      console.error("Error in getUserByPhone:", error)
      if (error instanceof HttpsError) throw error
      throw new HttpsError("internal", "An internal error occurred.")
    }
  }
)

/** Fetch kilvishId from PublicInfo for a given userId */
async function _getKilvishId(userId: string): Promise<string | undefined> {
  const doc = await kilvishDb.collection("PublicInfo").doc(userId).get()
  return doc.data()?.kilvishId as string | undefined
}

/**
 * Parse updatedBy field — supports both old string format and new {userId, kilvishId} map.
 * Falls back to PublicInfo lookup for the kilvishId when the string format is used.
 */
async function _parseUpdatedBy(updatedBy: any): Promise<{ userId?: string; kilvishId?: string }> {
  if (!updatedBy) return {}
  if (typeof updatedBy === "string") {
    const kilvishId = await _getKilvishId(updatedBy)
    return { userId: updatedBy, kilvishId }
  }
  return { userId: updatedBy.userId, kilvishId: updatedBy.kilvishId }
}

/**
 * Helper: Get FCM tokens for tag users, split into expense-owner token and member tokens with userIds.
 */
async function _getTagUserTokens(
  tagId: string,
  expenseOwnerId: string
): Promise<{ members: { userId: string; token: string }[]; expenseOwnerToken: string | undefined } | undefined> {
  console.log(`Entering _getTagUserTokens for tagId - ${tagId}, expenseOwnerId ${expenseOwnerId}`)

  const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
  if (!tagDoc.exists) return

  const tagData = tagDoc.data()
  if (!tagData) return

  const friendIds = ((tagData.sharedWith as string[]) || []).filter((id) => id && id.trim())
  const userIdsToNotify: string[] = [tagData.ownerId, ...friendIds]

  const usersSnapshot = await kilvishDb.collection("Users").where("__name__", "in", userIdsToNotify).get()

  const members: { userId: string; token: string }[] = []
  let expenseOwnerToken: string | undefined = undefined

  usersSnapshot.forEach((doc) => {
    const userData = doc.data()
    if (doc.id === expenseOwnerId && userData.fcmToken) {
      expenseOwnerToken = userData.fcmToken
    } else if (doc.id !== expenseOwnerId && userData.fcmToken) {
      members.push({ userId: doc.id, token: userData.fcmToken })
    }
  })

  return { members, expenseOwnerToken }
}

function _monthKey(date: Date): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
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
  return (
    before.amount !== after.amount ||
    beforeMonth !== afterMonth ||
    (before.totalOutstandingAmount || 0) !== (after.totalOutstandingAmount || 0) ||
    (before.isSettlement || false) !== (after.isSettlement || false)
  )
}

async function _processTagSummaryForExpenseOwnerContribution(
  {data, tagId, isIncrement = true, update }: 
  {data: any, tagId: string, isIncrement?: boolean, update?: TagStatsUpdate}
): Promise<TagStatsUpdate> {

  const ownerId: string = data.ownerId
  const txTimestamp = data.timeOfTransaction as admin.firestore.Timestamp
  const monthKey = _monthKey(txTimestamp.toDate())
  const isSettlement: boolean = data.isSettlement === true
  const _update = update ?? new TagStatsUpdate();

  const amount = isIncrement === true ? data.amount : -data.amount

  _update.applyDelta(ownerId, monthKey, "expense", amount)
  if (!isSettlement) _update.applyDelta("acrossUsers", monthKey, "expense", amount)
  
  let outstanding: number = data.totalOutstandingAmount || 0
  if (outstanding > 0) {
    outstanding = isIncrement === true ? outstanding : -outstanding

    _update.applyDelta(ownerId, monthKey, "recovery", outstanding)
    if (!isSettlement) _update.applyDelta("acrossUsers", monthKey, "recovery", outstanding)
  }

  if (isSettlement) {
    //increment recovery of the owner anyway 
    _update.applyDelta(ownerId, monthKey, "recovery", amount)
  }

  if(!update) await _update.commit(kilvishDb.collection("Tags").doc(tagId))

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
    await _processTagSummaryForExpenseOwnerContribution({data: before, tagId: tagId})
    return tagName;
  }

  if (eventType === "expense_deleted") {
    await _processTagSummaryForExpenseOwnerContribution({data: before, tagId: tagId, isIncrement: false})
    return tagName
  }

  // expense_updated
  const after = event.data?.after.data()!
  const newMonthKey = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())

  await _processTagSummaryForExpenseOwnerContribution({data: before, tagId: tagId, isIncrement: false, update: update})
  await _processTagSummaryForExpenseOwnerContribution({data: after, tagId: tagId, update: update})

  if (monthKey !== newMonthKey) {
    // Recipients: old-month undo + new-month apply; their total.{userId}.recovery nets to zero.
    const recipientsSnap = await kilvishDb
      .collection("Tags").doc(tagId)
      .collection("Expenses").doc(expenseId)
      .collection("Recipients").get()
    for (const doc of recipientsSnap.docs) {
      const recipientId = doc.id
      const recipientData = doc.data()

      // Settlement recipients track their own settlementMonth — onRecipientWritten handles them
      if (recipientData.settlementMonth) continue
      
      const amount: number = (recipientData.amount as number) || 0
      update
        .applyDelta(recipientId, monthKey, "recovery", amount)
        .applyDelta(recipientId, newMonthKey, "recovery", -amount) //recipient is owing money, hence recovery goes < 0, their outstanding will show negative 
        // also recipient recovery values does NOT affect acrossUsers.recovery
    }
  }

  await update.commit(tagDocRef)
  return tagName
}

async function _notifyExpenseCreated(event: FirestoreEvent<any>, tagName: string) {
  try {
    const { tagId, expenseId } = event.params
    const expenseData = event.data?.data()
    if (!expenseData) return

    const { userId: actorId, kilvishId: actorKilvishId } = await _parseUpdatedBy(expenseData.updatedBy)
    const ownerKilvishId = actorKilvishId // creator is always the owner on expense_created

    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
    if (!userTokens) return
    const { members, expenseOwnerToken } = userTokens

    const baseData: Record<string, string> = {
      type: "expense_created",
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(actorKilvishId && { actorKilvishId }),
    }

    // Silent cache-refresh to expense owner
    if (expenseOwnerToken) {
      await admin.messaging().send({ token: expenseOwnerToken, data: baseData })
      console.log(`expense_created: silent sent to owner`)
    }

    if (members.length === 0) return

    // Fetch recipients to send personalised messages
    const recipientsSnap = await kilvishDb
      .collection("Tags").doc(tagId)
      .collection("Expenses").doc(expenseId)
      .collection("Recipients").get()
    const recipientIds = new Set(recipientsSnap.docs.map((d) => d.id))
    const isSettlement: boolean = expenseData.isSettlement === true
    const amount: number = expenseData.amount || 0

    const recipientMembers = members.filter((m) => recipientIds.has(m.userId))
    const otherMembers = members.filter((m) => !recipientIds.has(m.userId))

    // Personalised notification to each recipient
    for (const member of recipientMembers) {
      const body = isSettlement
        ? `Tag: ${tagName}, @${ownerKilvishId} paid you ₹${amount}`
        : `Tag: ${tagName}, you owe ₹${amount} to @${ownerKilvishId}`
      await admin.messaging().send({
        token: member.token,
        notification: { title: tagName, body },
        data: baseData,
      })
    }

    // Generic notification to other tag members
    if (otherMembers.length > 0) {
      const body = `Tag: ${tagName}, @${ownerKilvishId} added expense ₹${amount} to ${expenseData.to || "unknown"}`
      await admin.messaging().sendEachForMulticast({
        tokens: otherMembers.map((m) => m.token),
        notification: { title: tagName, body },
        data: baseData,
      })
    }

    console.log(`expense_created FCM: ${recipientMembers.length} personalised, ${otherMembers.length} generic`)
  } catch (error) {
    console.error(`Error in expense_created notification:`, error)
  }
}

async function _notifyExpenseUpdated(event: FirestoreEvent<any>, tagName: string) {
  try {
    const { tagId, expenseId } = event.params
    const expenseData = event.data?.after.data()
    if (!expenseData) return

    const { userId: actorId, kilvishId: actorKilvishId } = await _parseUpdatedBy(expenseData.updatedBy)
    const ownerKilvishId = actorKilvishId

    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
    if (!userTokens) return
    const { members, expenseOwnerToken } = userTokens

    const baseData: Record<string, string> = {
      type: "expense_updated",
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(actorKilvishId && { actorKilvishId }),
    }

    if (expenseOwnerToken) {
      await admin.messaging().send({ token: expenseOwnerToken, data: baseData })
    }

    if (members.length === 0) return

    const body = `Tag: ${tagName}, @${ownerKilvishId} updated an expense`
    await admin.messaging().sendEachForMulticast({
      tokens: members.map((m) => m.token),
      notification: { title: tagName, body },
      data: baseData,
    })
    console.log(`expense_updated FCM: sent to ${members.length} members`)
  } catch (error) {
    console.error(`Error in expense_updated notification:`, error)
  }
}

async function _notifyExpenseDeleted(event: FirestoreEvent<any>, tagName: string) {
  try {
    const { tagId, expenseId } = event.params
    const expenseData = event.data?.data()
    if (!expenseData) return

    // Parse actor from updatedBy (last writer = owner); fall back to PublicInfo
    const { userId: actorId, kilvishId: actorKilvishId } = await _parseUpdatedBy(expenseData.updatedBy)
    const ownerKilvishId = actorKilvishId ?? (expenseData.ownerId ? await _getKilvishId(expenseData.ownerId) : undefined)

    const isSettlement: boolean = expenseData.isSettlement === true
    const amount: number = expenseData.amount || 0

    // Fetch & delete Recipients subcollection
    const recipientsSnap = await kilvishDb
      .collection("Tags").doc(tagId)
      .collection("Expenses").doc(expenseId)
      .collection("Recipients").get()

    if (!recipientsSnap.empty) {
      const batch = kilvishDb.batch()
      recipientsSnap.docs.forEach((doc) => batch.delete(doc.ref))
      await batch.commit()
      console.log(`expense_deleted: deleted ${recipientsSnap.size} Recipient(s) under ${expenseId}`)
    }

    // Only notify recipients (not all tag members)
    const recipientIds = recipientsSnap.docs.map((d) => d.id)
    if (recipientIds.length === 0) return

    const usersSnap = await kilvishDb.collection("Users").where("__name__", "in", recipientIds).get()
    const tokens: string[] = usersSnap.docs
      .map((d) => d.data().fcmToken as string | undefined)
      .filter((t): t is string => !!t)

    if (tokens.length === 0) return

    const body = isSettlement
      ? `Tag: ${tagName}, @${ownerKilvishId} removed settlement record of ₹${amount}`
      : `Tag: ${tagName}, @${ownerKilvishId} removed expense — your ₹${amount} debt is cleared`

    const baseData: Record<string, string> = {
      type: "expense_deleted",
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(actorKilvishId && { actorKilvishId }),
    }

    await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title: tagName, body },
      data: baseData,
    })
    console.log(`expense_deleted FCM: notified ${tokens.length} recipient(s)`)
  } catch (error) {
    console.error(`Error in expense_deleted notification:`, error)
  }
}

/**
 * Notify when expense is CREATED
 */
export const onExpenseCreated = onDocumentCreated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseCreated for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_created")
    if (tagName) await _notifyExpenseCreated(event, tagName)
  }
)

/**
 * Notify when expense is UPDATED
 */
export const onExpenseUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseUpdated for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_updated")
    if (tagName != null) await _notifyExpenseUpdated(event, tagName)
  }
)

/**
 * Notify when expense is DELETED
 */
export const onExpenseDeleted = onDocumentDeleted(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseDeleted for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_deleted")
    if (tagName != null) await _notifyExpenseDeleted(event, tagName)
  }
)

async function _updateRecipientContributionToTagSummary(
  {data, expenseData, tagId, update, recipientId, isInvert = false} : 
  {data: any, expenseData: any, tagId: string, update: TagStatsUpdate, recipientId: string, isInvert?: boolean}
) {

  const data_amount = isInvert ? -data.amount : data.amount

  const settlementMonth = data.settlementMonth
  if (settlementMonth) {
    // in settlement, acrossUser expense will NOT get affected, only acrossUser recovery will
    update
      .applyDelta(recipientId, settlementMonth, "expense", -data_amount)
      .applyDelta(recipientId, settlementMonth, "recovery", -data_amount)
      .applyDelta("acrossUsers", settlementMonth, "recovery", -data_amount)
  }
  else {
    // its expense distribution
    const txTimestamp = expenseData.timeOfTransaction as admin.firestore.Timestamp
    const expenseMonth = _monthKey(txTimestamp.toDate())

    // nothing in acrossUser will change .. neither expense nor recovery
    update.applyDelta(recipientId, expenseMonth, "recovery", -data_amount)
  }


}

/**
 * Incrementally update recipient's recovery when their amount changes.
 * Owner's recovery is driven by totalOutstandingAmount on the Expense doc.
 */
export const onRecipientWritten = onDocumentWritten(
  { document: "Tags/{tagId}/Expenses/{expenseId}/Recipients/{recipientId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onRecipientWritten for params ${inspect(event.params)}`)
    const { tagId, expenseId, recipientId } = event.params
    const before = event.data?.before.data()
    const after = event.data?.after.data()

    const expenseDoc = await kilvishDb
      .collection("Tags").doc(tagId)
      .collection("Expenses").doc(expenseId).get()
    if (!expenseDoc.exists) return

    const expenseData = expenseDoc.data()!
    const isSettlement: boolean = expenseData.isSettlement === true

    const update = new TagStatsUpdate()
    if (before) await _updateRecipientContributionToTagSummary({ data: before, expenseData: expenseData, tagId: tagId, update: update, recipientId: recipientId, isInvert: true})
    if(after) await _updateRecipientContributionToTagSummary({ data: after, expenseData: expenseData, tagId: tagId, update: update, recipientId: recipientId})

    await update.commit(kilvishDb.collection("Tags").doc(tagId))
    console.log(`onRecipientWritten: ${recipientId} stats updated in tag ${tagId} (settlement=${isSettlement})`)

    // Fetch tag name for notification body
    const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
    const tagName: string = tagDoc.data()?.name || tagId

    // Determine action type
    const action = !before ? "create" : !after ? "delete" : "update"
    const recipientData = after ?? before
    const amount: number = recipientData?.amount || 0

    // Parse actor (owner is the writer of recipient docs)
    const rawUpdatedBy = after?.updatedBy ?? before?.updatedBy
    const { userId: actorId, kilvishId: ownerKilvishId } = await _parseUpdatedBy(rawUpdatedBy)

    // Get recipient FCM token
    const recipientUserDoc = await kilvishDb.collection("Users").doc(recipientId).get()
    const recipientToken = recipientUserDoc.data()?.fcmToken as string | undefined

    // Also send silent cache-refresh to expense owner
    const ownerUserDoc = await kilvishDb.collection("Users").doc(expenseData.ownerId).get()
    const ownerToken = ownerUserDoc.data()?.fcmToken as string | undefined

    const baseData: Record<string, string> = {
      type: "recipient_written",
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(ownerKilvishId && { actorKilvishId: ownerKilvishId }),
    }

    if (ownerToken && ownerUserDoc.id !== recipientId) {
      await admin.messaging().send({ token: ownerToken, data: baseData })
    }

    if (recipientToken) {
      let body: string
      if (action === "create") {
        body = isSettlement
          ? `Tag: ${tagName}, @${ownerKilvishId} paid you ₹${amount}`
          : `Tag: ${tagName}, you owe ₹${amount} to @${ownerKilvishId}`
      } else if (action === "update") {
        body = isSettlement
          ? `Tag: ${tagName}, @${ownerKilvishId} updated settlement to ₹${amount}`
          : `Tag: ${tagName}, @${ownerKilvishId} updated your owed amount to ₹${amount}`
      } else {
        body = isSettlement
          ? `Tag: ${tagName}, @${ownerKilvishId} removed settlement record of ₹${amount}`
          : `Tag: ${tagName}, @${ownerKilvishId} removed your debt of ₹${amount}`
      }
      await admin.messaging().send({
        token: recipientToken,
        notification: { title: tagName, body },
        data: baseData,
      })
      console.log(`onRecipientWritten: ${action} notification sent to recipient ${recipientId}`)
    }
  }
)

function _setsAreEqual<T>(set1: Set<T>, set2: Set<T>): boolean {
  // Step 1: Check if the sizes are equal
  if (set1.size !== set2.size) {
    return false
  }

  // Step 2: Check if every element in set1 is present in set2
  for (const item of set1) {
    if (!set2.has(item)) {
      return false
    }
  }

  return true // If all checks pass, the sets are equal
}

async function _notifyUserOfTagShared(
  userId: string,
  tagId: string,
  tagName: string,
  type: string,
  ownerKilvishId?: string
) {
  console.log(`Inside _notifyUserOfTagShared userId ${userId} tagName ${tagName}`)
  try {
    const userDoc = await kilvishDb.collection("Users").doc(userId).get()
    if (!userDoc.exists) return

    const userData = userDoc.data()
    if (!userData) return

    const fcmToken = userData.fcmToken as string | undefined

    await kilvishDb
      .collection("Users")
      .doc(userId)
      .update({
        accessibleTagIds:
          type === "tag_shared"
            ? admin.firestore.FieldValue.arrayUnion(tagId)
            : admin.firestore.FieldValue.arrayRemove(tagId),
      })
    console.log(`${type === "tag_shared" ? "Added" : "Removed"} tag ${tagId} ${type === "tag_shared" ? "to" : "from"} user ${userId}'s accessibleTagIds`)

    if (fcmToken) {
      const isAdded = type === "tag_shared"
      const body = isAdded
        ? `Tag: ${tagName} has been shared with you${ownerKilvishId ? ` by @${ownerKilvishId}` : ""}`
        : `Tag: ${tagName}, @${ownerKilvishId ?? "someone"} removed you from this tag`
      await admin.messaging().send({
        data: { type, tagId, tagName },
        notification: { title: tagName, body },
        token: fcmToken,
      })
      console.log(`${type} notification sent to user: ${userId}`)
    }
  } catch (error) {
    console.error(`Error in _notifyUserOfTagShared ${error}`)
  }
}

/** Notify all tag members (except the directly affected user) about a participant add/remove */
async function _notifyOtherMembersOfTagChange(
  tagId: string,
  tagName: string,
  ownerId: string,
  affectedUserId: string,
  ownerKilvishId: string | undefined,
  affectedKilvishId: string | undefined,
  action: "added" | "removed"
) {
  try {
    const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
    const sharedWith: string[] = tagDoc.data()?.sharedWith || []
    const otherUserIds = [ownerId, ...sharedWith].filter((id) => id && id !== affectedUserId)
    if (otherUserIds.length === 0) return

    const usersSnap = await kilvishDb.collection("Users").where("__name__", "in", otherUserIds).get()
    const tokens: string[] = usersSnap.docs
      .map((d) => d.data().fcmToken as string | undefined)
      .filter((t): t is string => !!t)
    if (tokens.length === 0) return

    const body =
      action === "added"
        ? `Tag: ${tagName}, @${ownerKilvishId} added @${affectedKilvishId}`
        : `Tag: ${tagName}, @${ownerKilvishId} removed @${affectedKilvishId}`

    await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title: tagName, body },
      data: { type: action === "added" ? "tag_shared" : "tag_removed", tagId, tagName },
    })
    console.log(`_notifyOtherMembersOfTagChange: ${action} sent to ${tokens.length} other member(s)`)
  } catch (error) {
    console.error(`Error in _notifyOtherMembersOfTagChange: ${error}`)
  }
}

async function _sendTagUpdatedToOwner(tagId: string, ownerId: string, tagName: string) {
  try {
    const userDoc = await kilvishDb.collection("Users").doc(ownerId).get()
    const fcmToken = userDoc.data()?.fcmToken as string | undefined
    if (!fcmToken) return
    await admin.messaging().send({
      token: fcmToken,
      data: { type: "tag_updated", tagId, tagName },
    })
    console.log(`tag_updated FCM sent to owner ${ownerId} for tag ${tagId}`)
  } catch (e) {
    console.error(`Failed to send tag_updated to owner ${ownerId}: ${e}`)
  }
}

async function _updateSharedWithOfTag(tagId: string, removedUserIds: string[], addedUserIds: string[]) {
  try {
    console.log(
      `Entered _updateSharedWithOfTag for ${tagId}, removedUserIds ${inspect(removedUserIds)} adduserIds ${inspect(
        addedUserIds
      )}`
    )

    //update sharedWith field of Tag with the kilvishUserIds
    const docRef = kilvishDb.collection("Tags").doc(tagId)

    const tagDoc = await docRef.get()
    if (!tagDoc.exists) {
      throw new Error(`Tag ${tagId} does not exist`)
    }

    const tagData = tagDoc.data()
    let sharedWith: string[] = tagData?.sharedWith || []

    // Remove the removed user IDs
    if (removedUserIds.length > 0) {
      sharedWith = sharedWith.filter((userId) => !removedUserIds.includes(userId))
    }

    // Add the new user IDs (avoid duplicates)
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

      if (!data){
        console.log("data is empty so returning")
        return
      } 

      const sharedWithFriends = (data.sharedWithFriends as string[]) || []
      if(sharedWithFriends.length == 0){
        console.log("empty sharedWithFriends .. so returning")
        return
      }

      const removedUserIds: string[] = []
      for (const friendId of sharedWithFriends) {
        const friendUserId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(data.ownerId, friendId)
        if (friendUserId) removedUserIds.push(friendUserId)
      }
      
      // tag isnt there .. so what to remove 
      // await _updateSharedWithOfTag(tagId, removedUserIds, [])

      const tagName = data.name || "Unknown"
      const ownerKilvishId = await _getKilvishId(data.ownerId)
      console.log(`Users removed from tag ${tagName}:`, removedUserIds)

      for (const userId of removedUserIds) {
        const memberKilvishId = await _getKilvishId(userId)
        await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed", ownerKilvishId)
        // Tag is deleted — no remaining members to notify, skip _notifyOtherMembersOfTagChange
        void memberKilvishId // referenced to avoid lint warning
      }
    }
    catch(error){
      console.error("Error in handleTagAccessRemovalOnTagDelete:", error)
      throw error
    }
  })

export const handleTagSharingOnTagCreate = onDocumentCreated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Entering handleTagSharingOnTagCreate event params ${inspect(event.params)}`)
    try {
      const tagId = event.params.tagId
      const data = event.data?.data()

      if (!data){
        console.log("data is empty so returning")
        return
      } 

      const sharedWithFriends = (data.sharedWithFriends as string[]) || []
      if(sharedWithFriends.length == 0){
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
    }
    catch(error){
      console.error("Error in handleTagSharingOnTagCreate:", error)
      throw error
    }
  })


export const handleTagSharingOnTagUpdate = onDocumentUpdated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Entering handleTagSharingOnTagUpdate event params ${inspect(event.params)}`)
    try {
      const tagId = event.params.tagId
      const beforeData = event.data?.before.data()
      const afterData = event.data?.after.data()

      console.log(`Entering handleTagSharingOnTagUpdate for ${tagId}`)

      if (!beforeData || !afterData) return

      const beforeSharedWithFriends = (beforeData.sharedWithFriends as string[]) || []
      const afterSharedWithFriends = (afterData.sharedWithFriends as string[]) || []

      // there is no change in users with whom the Tag is shared with
      if (_setsAreEqual(new Set(beforeSharedWithFriends), new Set(afterSharedWithFriends))) return

      // Find newly added users
      const addedUserFriends = afterSharedWithFriends.filter(
        (userId) => !beforeSharedWithFriends.includes(userId) && userId && userId.trim()
      )

      const addedUserIds: string[] = []
      for (const friendId of addedUserFriends) {
        const friendUserId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(beforeData.ownerId, friendId)
        if (friendUserId) addedUserIds.push(friendUserId)
      }

      // Find removed users
      const removedUserFriends = beforeSharedWithFriends.filter(
        (userId) => !afterSharedWithFriends.includes(userId) && userId && userId.trim()
      )

      const removedUserIds: string[] = []
      for (const friendId of removedUserFriends) {
        const friendUserId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(beforeData.ownerId, friendId)
        if (friendUserId) removedUserIds.push(friendUserId)
      }

      await _updateSharedWithOfTag(tagId, removedUserIds, addedUserIds)

      // Initialise total stats entry for each newly added user
      if (addedUserIds.length > 0) {
        const init = new TagStatsUpdate()
        for (const userId of addedUserIds) init.initUser(userId)
        await init.commit(kilvishDb.collection("Tags").doc(tagId))
      }

      const tagName = afterData.name || "Unknown"
      const ownerKilvishId = await _getKilvishId(beforeData.ownerId)

      // Notify tag owner so their cache refreshes with updated sharedWith
      await _sendTagUpdatedToOwner(tagId, beforeData.ownerId, tagName)

      // Notify newly added users + all other members
      if (addedUserIds.length > 0) {
        console.log(`Users added to tag ${tagId}:`, addedUserIds)
        for (const userId of addedUserIds) {
          await _notifyUserOfTagShared(userId, tagId, tagName, "tag_shared", ownerKilvishId)
          const memberKilvishId = await _getKilvishId(userId)
          await _notifyOtherMembersOfTagChange(tagId, tagName, beforeData.ownerId, userId, ownerKilvishId, memberKilvishId, "added")
        }
      }

      // Notify removed users + all remaining members
      if (removedUserIds.length > 0) {
        console.log(`Users removed from tag ${tagId}:`, removedUserIds)
        for (const userId of removedUserIds) {
          const memberKilvishId = await _getKilvishId(userId)
          await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed", ownerKilvishId)
          await _notifyOtherMembersOfTagChange(tagId, tagName, beforeData.ownerId, userId, ownerKilvishId, memberKilvishId, "removed")
        }
      }

      return { success: true, addedUsers: addedUserIds.length, removedUsers: removedUserIds.length }
    } catch (error) {
      console.error("Error in handleTagSharingOnTagUpdate:", error)
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

  // Check if User with this phone number exists
  const userQuery = await kilvishDb.collection("Users").where("phone", "==", phoneNumber).limit(1).get()

  if (!userQuery.empty) {
    const existingUserDoc = userQuery.docs[0]
    kilvishUserId = existingUserDoc.id

    console.log(`User ${kilvishUserId} already exists for phone ${phoneNumber}`)
  } else {
    // create User
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

// export const findOrCreateFriendWithPhoneNumberAndAddTheirKilvishId = onDocumentCreated(
//   { document: "Users/{userId}/Friends/{friendId}", region: "asia-south1", database: "kilvish" },
//   async (event) => {
//     try {
//       const { userId, friendId } = event.params
//       const friendData = event.data?.data()
//       if (!friendData) return

//       await _registerFriendAsKilvishUserAndReturnKilvishUserId(userId, friendId, friendData)
//     } catch (error) {
//       console.error("Error in onUserFriendDocumentAdded:", error)
//       throw error
//     }
//   }
// )

// ─── Helpers for onUserDeleted ────────────────────────────────────────────────

async function _deleteSubcollection(collectionRef: FirebaseFirestore.CollectionReference) {
  const snapshot = await collectionRef.get()
  const batch = kilvishDb.batch()
  snapshot.docs.forEach((doc) => batch.delete(doc.ref))
  if (!snapshot.empty) await batch.commit()
}

async function _stripTagFromUserExpenseDoc(
  ownerId: string,
  expenseId: string,
  tagId: string
) {
  try {
    const expRef = kilvishDb.collection("Users").doc(ownerId).collection("Expenses").doc(expenseId)
    const expDoc = await expRef.get()
    if (!expDoc.exists) return

    const tagsJson: string = expDoc.data()?.tags || "[]"
    const tags: Array<{ id: string }> = JSON.parse(tagsJson)
    const filtered = tags.filter((t) => t.id !== tagId)
    if (filtered.length === tags.length) return // nothing to strip
    
    await expRef.update({ tags: JSON.stringify(filtered) })
    console.log(`Stripped tag ${tagId} from expense ${expenseId} of user ${ownerId}`)
  } catch (e) {
    console.error(`_stripTagFromUserExpenseDoc error for user ${ownerId} exp ${expenseId} tag ${tagId}: ${e}`)
  }
}

async function _cleanupOwnedTag(tagId: string, deletedUserId: string) {
  const tagRef = kilvishDb.collection("Tags").doc(tagId)
  const tagDoc = await tagRef.get()
  if (!tagDoc.exists) return
  const tagData = tagDoc.data()!
  const tagName: string = tagData.name || "Unknown"
  const members: string[] = (tagData.sharedWith as string[]) || []

  console.log(`Deleting owned tag "${tagName}" (${tagId}) — ${members.length} member(s) to notify`)

  const expensesSnap = await tagRef.collection("Expenses").get()
  console.log(`Tag "${tagName}": deleting ${expensesSnap.size} expense(s) and their Recipients`)
  for (const expDoc of expensesSnap.docs) {
    const expData = expDoc.data()
    const expOwnerId: string = expData.ownerId || ""

    const recipientsSnap = await expDoc.ref.collection("Recipients").get()
    if (!recipientsSnap.empty) {
      const batch = kilvishDb.batch()
      recipientsSnap.docs.forEach((doc) => batch.delete(doc.ref))
      await batch.commit()
      console.log(`Deleted ${recipientsSnap.size} Recipient(s) under expense ${expDoc.id} in tag "${tagName}"`)
    }

    // If expense was owned by another user, strip this tag from their personal expense copy
    if (expOwnerId && expOwnerId !== deletedUserId) {
      await _stripTagFromUserExpenseDoc(expOwnerId, expDoc.id, tagId)
    }

    await expDoc.ref.delete()
    console.log(`Deleted expense ${expDoc.id} from tag "${tagName}"`)
  }

  // Notify members they no longer have access, and remove tag from their accessibleTagIds
  for (const memberId of members) {
    try {
      console.log(`Removing tag "${tagName}" from accessibleTagIds of member ${memberId} and notifying`)
      await _notifyUserOfTagShared(memberId, tagId, tagName, "tag_removed")
    } catch (e) {
      console.error(`Failed to notify member ${memberId} about removal from tag "${tagName}": ${e}`)
    }
  }

  await tagRef.delete()
  console.log(`Deleted tag document "${tagName}" (${tagId})`)
}

async function _cleanupMemberTag(tagId: string, deletedUserId: string) {
  const tagRef = kilvishDb.collection("Tags").doc(tagId)
  const tagDoc = await tagRef.get()
  const tagName: string = tagDoc.data()?.name || tagId

  console.log(`Removing deleted user from member tag "${tagName}" (${tagId})`)
  await tagRef.update({
    sharedWith: admin.firestore.FieldValue.arrayRemove(deletedUserId),
  })
  console.log(`Removed ${deletedUserId} from sharedWith of tag "${tagName}"`)

  const expensesSnap = await tagRef.collection("Expenses").get()
  for (const expDoc of expensesSnap.docs) {
    const expData = expDoc.data()
    if (expData.ownerId === deletedUserId) {
      const recipientsSnap = await expDoc.ref.collection("Recipients").get()
      if (!recipientsSnap.empty) {
        const batch = kilvishDb.batch()
        recipientsSnap.docs.forEach((doc) => batch.delete(doc.ref))
        await batch.commit()
        console.log(`Deleted ${recipientsSnap.size} Recipient(s) under expense ${expDoc.id} in tag "${tagName}"`)
      }
      await expDoc.ref.delete()
      console.log(`Deleted expense ${expDoc.id} (owned by deleted user) from tag "${tagName}"`)
    } else {
      // Delete any Recipient entry for this user under other users' expenses
      const recipientRef = expDoc.ref.collection("Recipients").doc(deletedUserId)
      const recipientDoc = await recipientRef.get()
      if (recipientDoc.exists) {
        await recipientRef.delete()
        console.log(`Deleted Recipient entry for ${deletedUserId} under expense ${expDoc.id} in tag "${tagName}"`)
      }
    }
  }
  console.log(`Done cleaning up member tag "${tagName}" (${tagId})`)
}

async function _deleteUserStorageFiles(userId: string) {
  try {
    const bucket = admin.storage().bucket("gs://tamraj-kilvish.firebasestorage.app")
    const [files] = await bucket.getFiles({ prefix: `receipts/${userId}_` })
    await Promise.all(files.map((f) => f.delete()))
    console.log(`Deleted ${files.length} storage file(s) for user ${userId}`)
  } catch (e) {
    console.error(`_deleteUserStorageFiles error for user ${userId}: ${e}`)
  }
}

// ─── Firestore trigger: clean up all data when a User document is deleted ────

export const onUserDeleted = onDocumentDeleted(
  { document: "Users/{userId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    const userId = event.params.userId
    console.log(`onUserDeleted: starting cleanup for userId ${userId}`)

    // 1. Owned tags
    const ownedTagsSnap = await kilvishDb.collection("Tags").where("ownerId", "==", userId).get()
    for (const tagDoc of ownedTagsSnap.docs) {
      await _cleanupOwnedTag(tagDoc.id, userId)
    }

    // 2. Member tags (tags this user was shared into)
    const memberTagsSnap = await kilvishDb.collection("Tags").where("sharedWith", "array-contains", userId).get()
    for (const tagDoc of memberTagsSnap.docs) {
      await _cleanupMemberTag(tagDoc.id, userId)
    }

    // 3. User's own subcollections
    const userRef = kilvishDb.collection("Users").doc(userId)
    await _deleteSubcollection(userRef.collection("Expenses"))
    await _deleteSubcollection(userRef.collection("WIPExpenses"))
    await _deleteSubcollection(userRef.collection("Friends"))

    // 4. PublicInfo
    await kilvishDb.collection("PublicInfo").doc(userId).delete()

    // 5. User document
    await userRef.delete()

    // 6. Storage receipts
    await _deleteUserStorageFiles(userId)

    console.log(`onUserDeleted: cleanup complete for userId ${userId}`)
  })
