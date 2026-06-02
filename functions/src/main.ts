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
  _notifyMembersOfTagMemberChange,
  _updateLastFCMSentAt,
  sendSingleFCM,
  sendMulticastFCM,
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
// acrossUsers is derived client-side — never written here.
class TagStatsUpdate {
  private deltas: Record<string, number> = {}

  // Updates total.{userId}.{field} and monthWiseTotal.{monthKey}.{userId}.{field}.
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
  return before.amount !== after.amount || before.expenseAmount !== after.expenseAmount || beforeMonth !== afterMonth
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

  const expenseAmount = data.expenseAmount ?? data.amount
  const amount = isIncrement ? expenseAmount : -expenseAmount
  _update.applyDelta(ownerId, monthKey, "spent", amount)

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
    const createUpdate = new TagStatsUpdate()
    await _processTagSummaryForExpenseOwnerContribution({ data: before, tagId, update: createUpdate })
    // Simple-mode tags: write equal-split myShare for all members and stamp isSimpleMode on expense.
    const tagData = tagDoc.data()
    if (tagData?.dontShowOutstanding) {
      const expenseAmount: number = (before.expenseAmount ?? before.amount) as number
      const allMembers: string[] = [tagData.ownerId, ...(tagData.sharedWith ?? [])]
      const N = allMembers.length
      for (const memberId of allMembers) {
        createUpdate.applyDelta(memberId, monthKey, "myShare", expenseAmount / N)
      }
      const expenseRef = tagDocRef.collection("Expenses").doc(expenseId)
      await expenseRef.update({ isSimpleMode: true, simpleParticipants: allMembers })
    }
    await createUpdate.commit(tagDocRef)
    return tagName
  }

  if (eventType === "expense_deleted") {
    const deleteUpdate = new TagStatsUpdate()
    await _processTagSummaryForExpenseOwnerContribution({ data: before, tagId, isIncrement: false, update: deleteUpdate })
    // Reverse simple-mode myShare if it was stamped
    if (before.isSimpleMode) {
      const expenseAmount: number = (before.expenseAmount ?? before.amount) as number
      const simpleParticipants: string[] = before.simpleParticipants ?? []
      const N = simpleParticipants.length
      for (const participantId of simpleParticipants) {
        deleteUpdate.applyDelta(participantId, monthKey, "myShare", -(expenseAmount / N))
      }
    }
    await deleteUpdate.commit(tagDocRef)
    return tagName
  }

  // expense_updated
  const after = event.data?.after.data()!
  const newMonthKey = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())

  await _processTagSummaryForExpenseOwnerContribution({ data: before, tagId, isIncrement: false, update })
  await _processTagSummaryForExpenseOwnerContribution({ data: after, tagId, update })

  if (monthKey !== newMonthKey) {
    // Recipients: old-month undo + new-month apply; total.{userId}.myShare nets to zero.
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
        .applyDelta(recipientId, monthKey, "myShare", amount)
        .applyDelta(recipientId, newMonthKey, "myShare", -amount)
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
    const { tagId, expenseId } = event.params
    const tagName = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_updated")
    if (tagName != null) await _notifyExpenseAction("expense_updated", event.params, event.data?.after.data(), tagName)

    // Keep cached expense context on recipient docs in sync when expenseAmount or month changes
    const beforeData = event.data?.before.data()
    const afterData = event.data?.after.data()
    if (beforeData && afterData) {
      const prevAmount = beforeData.expenseAmount ?? beforeData.amount
      const afterAmount = afterData.expenseAmount ?? afterData.amount
      const expenseAmountChanged = prevAmount !== afterAmount
      
      const beforeMonth = _monthKey((beforeData.timeOfTransaction as admin.firestore.Timestamp).toDate())
      const afterMonth = _monthKey((afterData.timeOfTransaction as admin.firestore.Timestamp).toDate())
      const monthChanged = beforeMonth !== afterMonth

      if (expenseAmountChanged || monthChanged) {
        const recipientsSnap = await kilvishDb
          .collection("Tags").doc(tagId)
          .collection("Expenses").doc(expenseId)
          .collection("Recipients").get()

        if (!recipientsSnap.empty) {
          const patch: Record<string, any> = {}
          if (monthChanged) patch.expenseMonth = afterMonth
          if (expenseAmountChanged) patch.expenseAmount = afterAmount

          const batch = kilvishDb.batch()
          recipientsSnap.docs.forEach((doc) => batch.update(doc.ref, patch))
          await batch.commit()
          
          console.log(`onExpenseUpdated: patched ${recipientsSnap.size} recipient(s) with updated expense context`)
        }
      }
    }
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

function _updateRecipientContributionToTagSummary({
  data,
  update,
  recipientId,
  isInvert = false,
}: {
  data: any
  update: TagStatsUpdate
  recipientId: string
  isInvert?: boolean
}) {
  const settlementMonth: string | undefined = data.settlementMonth
  const expenseMonth: string = data.expenseMonth ?? ""
  const expenseOwnerId: string = data.expenseOwnerId ?? ""
  const amount = isInvert ? -data.amount : data.amount

  if (settlementMonth) {
    // recipientId = creditor (gets paid back), expenseOwnerId = debtor (filed the settlement expense).
    // onExpenseCreated already incremented debtor's `spent`. Reclassify it: spent → paid.
    // Net effect on debtor's `spent` across both events = 0.
    update
      .applyDelta(expenseOwnerId, settlementMonth, "spent", -amount)
      .applyDelta(expenseOwnerId, settlementMonth, "paid", amount)
      .applyDelta(recipientId, settlementMonth, "received", amount)
  } else {
    // Distribution: both owner-share and regular recipient record their claimed share.
    update.applyDelta(recipientId, expenseMonth, "myShare", amount)
  }
}

/**
 * Update tag stats when a recipient entry changes.
 * All expense context (ownerId, month, amount) is stored on the recipient doc itself,
 * so this function works correctly even when the parent expense has been deleted.
 */
export const onRecipientWritten = onDocumentWritten(
  { document: "Tags/{tagId}/Expenses/{expenseId}/Recipients/{recipientId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onRecipientWritten for params ${inspect(event.params)}`)
    const { tagId, expenseId, recipientId } = event.params
    const before = event.data?.before.data()
    const after = event.data?.after.data()

    const expenseOwnerId: string | undefined = after?.expenseOwnerId ?? before?.expenseOwnerId
    if (!expenseOwnerId) {
      console.warn(`onRecipientWritten: no expenseOwnerId on recipient ${recipientId} — skipping`)
      return
    }

    const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
    const update = new TagStatsUpdate()
    if (before) _updateRecipientContributionToTagSummary({ data: before, update, recipientId, isInvert: true })
    if (after)  _updateRecipientContributionToTagSummary({ data: after,  update, recipientId })

    // Simple-mode undo: any first Recipient doc on a simple-mode expense must reverse the
    // equal-split myShare that onExpenseCreated wrote (covers both distribution and settlement).
    if (after && !before) {
      const expenseRef = tagDocRef.collection("Expenses").doc(expenseId)
      const expenseDoc = await expenseRef.get()
      const expenseData = expenseDoc.data()
      if (expenseData?.isSimpleMode) {
        const simpleParticipants: string[] = expenseData.simpleParticipants ?? []
        const expenseAmount = (expenseData.expenseAmount ?? expenseData.amount) as number
        const N = simpleParticipants.length
        const txDate = (expenseData.timeOfTransaction as admin.firestore.Timestamp).toDate()
        const expenseMonthKey = _monthKey(txDate)
        for (const participantId of simpleParticipants) {
          update.applyDelta(participantId, expenseMonthKey, "myShare", -(expenseAmount / N))
        }
        await expenseRef.update({ isSimpleMode: false })
      }
    }

    await update.commit(tagDocRef)
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
    const userTokens = await _getTagUserTokens(tagId, expenseOwnerId)
    if (!userTokens) return

    const { members, expenseOwnerToken, allMemberIds } = userTokens
    await _updateLastFCMSentAt(allMemberIds)

    const baseData: Record<string, string> = {
      type: "expense_updated",
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(ownerKilvishId && { actorKilvishId: ownerKilvishId }),
    }

    if (expenseOwnerToken) {
      await sendSingleFCM(expenseOwnerId, expenseOwnerToken, { data: baseData })
    }

    if (members.length > 0) {
      let body: string
      const isOwnerRecipient = recipientId === expenseOwnerId

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

      await sendMulticastFCM(members, {
        notification: { title: `Tag: ${tagName}`, body },
        data: baseData,
        apns: {
          headers: { 'apns-priority': '10' },
          payload: { aps: { 'content-available': 1, sound: 'default' } },
        },
        android: { priority: 'high' },
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

async function _applySharedWithChangesToAccessibleTagIdsAndNotifyUsers(
  tagId: string,
  beforeData: Record<string, any>,
  afterData: Record<string, any>
) {
  const beforeSharedWith: string[] = beforeData.sharedWith || []
  const afterSharedWith: string[] = afterData.sharedWith || []
  if (_setsAreEqual(new Set(beforeSharedWith), new Set(afterSharedWith))) return

  const addedUserIds = afterSharedWith.filter((id) => !beforeSharedWith.includes(id))
  const removedUserIds = beforeSharedWith.filter((id) => !afterSharedWith.includes(id))
  const ownerId = afterData.ownerId || beforeData.ownerId

  const batch = kilvishDb.batch()
  for (const userId of addedUserIds) {
    batch.update(kilvishDb.collection("Users").doc(userId), {
      accessibleTagIds: admin.firestore.FieldValue.arrayUnion(tagId),
    })
  }
  for (const userId of removedUserIds) {
    batch.update(kilvishDb.collection("Users").doc(userId), {
      accessibleTagIds: admin.firestore.FieldValue.arrayRemove(tagId),
    })
  }
  await batch.commit()
  console.log(`_applySharedWithChangesToUserAccessibleTagIds: +${addedUserIds.length} -${removedUserIds.length} users for tag ${tagId}`)

  const tagName = afterData.name || "Unknown"
  const { userId: actorId } = await _parseUpdatedBy(afterData.updatedBy)

  for (const affectedUserId of addedUserIds) {
    const kilvishId = await _getKilvishId(affectedUserId)
    await _notifyMembersOfTagMemberChange(tagId, tagName, ownerId, affectedUserId, kilvishId, "joined", actorId)
  }

  for (const affectedUserId of removedUserIds) {
    const kilvishId = await _getKilvishId(affectedUserId)
    await _notifyMembersOfTagMemberChange(tagId, tagName, ownerId, affectedUserId, kilvishId, "left", actorId)
  }
}

async function _updateTagSharedWithFromSharedWithFriendsChanges(
  tagId: string,
  beforeData: Record<string, any>,
  afterData: Record<string, any>
) {
  const beforeSharedWithFriends = (beforeData.sharedWithFriends as string[]) || []
  const afterSharedWithFriends = (afterData.sharedWithFriends as string[]) || []

  if (_setsAreEqual(new Set(beforeSharedWithFriends), new Set(afterSharedWithFriends))) return

  const addedUserFriends = afterSharedWithFriends.filter((id) => !beforeSharedWithFriends.includes(id) && id?.trim())
  const removedUserFriends = beforeSharedWithFriends.filter((id) => !afterSharedWithFriends.includes(id) && id?.trim())
  const ownerId = afterData.ownerId || beforeData.ownerId

  const addedUserIds: string[] = []
  for (const friendId of addedUserFriends) {
    const userId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(ownerId, friendId)
    if (userId) addedUserIds.push(userId)
  }

  const removedUserIds: string[] = []
  for (const friendId of removedUserFriends) {
    const userId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(ownerId, friendId)
    if (userId) removedUserIds.push(userId)
  }

  await _updateSharedWithOfTag(tagId, removedUserIds, addedUserIds)

  //this is for adding user keys in tag summary
  if (addedUserIds.length > 0) {
    const init = new TagStatsUpdate()
    for (const userId of addedUserIds) init.initUser(userId)
    await init.commit(kilvishDb.collection("Tags").doc(tagId))
  }
}

async function _handleTagDataChanges(
  tagId: string,
  before: Record<string, any>,
  after: Record<string, any>
) {
  const beforeTotal = (before.total ?? {}) as Record<string, any>
  const afterTotal = (after.total ?? {}) as Record<string, any>

  // Check if any display-relevant field changed
  const nameChanged = before.name !== after.name
  const totalChanged = Object.keys({ ...beforeTotal, ...afterTotal })
    .some((k) =>
      ["spent", "myShare", "received", "paid"].some(
        (f) => (beforeTotal[k]?.[f] ?? 0) !== (afterTotal[k]?.[f] ?? 0)
      )
    )

  if (!nameChanged && !totalChanged) return

  const userTokens = await _getTagUserTokens(tagId, after.ownerId)
  if (!userTokens) return
  
  const { members, expenseOwnerToken, allMemberIds } = userTokens
  await _updateLastFCMSentAt(allMemberIds)

  const userTokenPairs: { userId: string; token: string }[] = [...members]
  if (expenseOwnerToken) userTokenPairs.push({ userId: after.ownerId, token: expenseOwnerToken })

  await sendMulticastFCM(userTokenPairs, { data: { type: "tag_updated", tagId, tagName: "" } })
  
  console.log(`handleTagUpdate: tag_updated FCM sent to ${userTokenPairs.length} member(s) for tag ${tagId}`)
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

      await _applySharedWithChangesToAccessibleTagIdsAndNotifyUsers(tagId, {}, data)
      await _updateTagSharedWithFromSharedWithFriendsChanges(tagId, {}, data)

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

      await _applySharedWithChangesToAccessibleTagIdsAndNotifyUsers(tagId, beforeData, afterData)
      await _updateTagSharedWithFromSharedWithFriendsChanges(tagId, beforeData, afterData)
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

export const joinTag = onCall(
  { region: "asia-south1", cors: true },
  async (request) => {
    const userId = request.auth?.token?.userId as string | undefined
    if (!userId) throw new HttpsError("unauthenticated", "Not signed in")

    const { tagId } = request.data as { tagId: string }
    if (!tagId) throw new HttpsError("invalid-argument", "Missing tagId")

    const tagRef = kilvishDb.collection("Tags").doc(tagId)
    const tagSnap = await tagRef.get()
    if (!tagSnap.exists) throw new HttpsError("not-found", "Tag not found")

    const userRef = kilvishDb.collection("Users").doc(userId)
    const batch = kilvishDb.batch()
    batch.update(tagRef, { sharedWith: admin.firestore.FieldValue.arrayUnion(userId), updatedBy: userId })
    batch.update(userRef, { accessibleTagIds: admin.firestore.FieldValue.arrayUnion(tagId) })
    await batch.commit()

    console.log(`joinTag: user ${userId} joined tag ${tagId}`)
    return { success: true }
  }
)

export const removeTagMember = onCall(
  { region: "asia-south1", cors: true },
  async (request) => {
    const callerId = request.auth?.token?.userId as string | undefined
    if (!callerId) throw new HttpsError("unauthenticated", "Not signed in")

    const { tagId, userId } = request.data as { tagId: string; userId: string }
    if (!tagId || !userId) throw new HttpsError("invalid-argument", "Missing tagId or userId")

    const tagSnap = await kilvishDb.collection("Tags").doc(tagId).get()
    if (!tagSnap.exists) throw new HttpsError("not-found", "Tag not found")

    const isOwner = tagSnap.data()?.ownerId === callerId
    const isSelf = callerId === userId
    if (!isOwner && !isSelf) throw new HttpsError("permission-denied", "Only the tag owner or the user themselves can remove a member")

    const batch = kilvishDb.batch()
    batch.update(kilvishDb.collection("Tags").doc(tagId), { sharedWith: admin.firestore.FieldValue.arrayRemove(userId), updatedBy: callerId })
    batch.update(kilvishDb.collection("Users").doc(userId), { accessibleTagIds: admin.firestore.FieldValue.arrayRemove(tagId) })
    await batch.commit()

    console.log(`removeTagMember: user ${userId} removed from tag ${tagId} by ${callerId}`)
    return { success: true }
  }
)
