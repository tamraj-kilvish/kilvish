import { onCall, HttpsError } from "firebase-functions/v2/https"
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
  _getKilvishId,
  _parseUpdatedBy,
  _getTagUserTokens,
  _notifyExpenseAction,
  _notifyMembersOfTagMemberChange,
  _updateLastFCMSentAt,
  sendSingleFCM,
  sendMulticastFCM,
  scheduleExpenseMemberFCM,
} from "./fcm_notification"

function _monthKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`
}

type RecipientEntry = { amount: number; settlementMonth?: string }
type RecipientsMap = Record<string, RecipientEntry>

// Accumulates numeric deltas and commits them as atomic FieldValue.increment calls.
// acrossUsers is derived client-side — never written here.
class TagStatsUpdate {
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
  console.log(
    `_applySharedWithChangesToAccessibleTagIds: +${addedUserIds.length} -${removedUserIds.length} for tag ${tagId}`
  )

  const tagName = afterData.name || "Unknown"
  const { userId: actorId } = await _parseUpdatedBy(afterData.updatedBy)

  for (const affectedUserId of addedUserIds) {
    const kilvishId = await _getKilvishId(affectedUserId)
    await _notifyMembersOfTagMemberChange(tagId, tagName, afterData.ownerId, affectedUserId, kilvishId, "joined", actorId)
  }
  for (const affectedUserId of removedUserIds) {
    const kilvishId = await _getKilvishId(affectedUserId)
    await _notifyMembersOfTagMemberChange(tagId, tagName, afterData.ownerId, affectedUserId, kilvishId, "left", actorId)
  }
}

async function _updateTagSharedWithFromSharedWithFriendsChanges(
  tagId: string,
  beforeData: Record<string, any>,
  afterData: Record<string, any>
) {
  const beforeFriends: string[] = beforeData.sharedWithFriends || []
  const afterFriends: string[] = afterData.sharedWithFriends || []
  if (_setsAreEqual(new Set(beforeFriends), new Set(afterFriends))) return

  const ownerId = afterData.ownerId || beforeData.ownerId
  const addedFriends = afterFriends.filter((id) => !beforeFriends.includes(id) && id?.trim())
  const removedFriends = beforeFriends.filter((id) => !afterFriends.includes(id) && id?.trim())

  const addedUserIds: string[] = []
  for (const friendId of addedFriends) {
    const userId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(ownerId, friendId)
    if (userId) addedUserIds.push(userId)
  }

  const removedUserIds: string[] = []
  for (const friendId of removedFriends) {
    const userId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(ownerId, friendId)
    if (userId) removedUserIds.push(userId)
  }

  await _updateSharedWithOfTag(tagId, removedUserIds, addedUserIds)

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

  const nameChanged = before.name !== after.name
  const totalChanged = Object.keys({ ...beforeTotal, ...afterTotal }).some((k) =>
    ["spent", "myShare", "received", "paid"].some(
      (f) => (beforeTotal[k]?.[f] ?? 0) !== (afterTotal[k]?.[f] ?? 0)
    )
  )
  if (!nameChanged && !totalChanged) return

  const userTokens = await _getTagUserTokens(tagId, after.ownerId)
  if (!userTokens) return

  const { members, expenseOwnerToken, allMemberIds } = userTokens
  await _updateLastFCMSentAt(allMemberIds)

  const allTokenPairs = [...members]
  if (expenseOwnerToken) allTokenPairs.push({ userId: after.ownerId, token: expenseOwnerToken })

  await sendMulticastFCM(allTokenPairs, { data: { type: "tag_updated", tagId, tagName: "" } })
  console.log(`handleTagUpdate: tag_updated FCM sent to ${allTokenPairs.length} member(s) for ${tagId}`)
}

async function _updateSharedWithOfTag(
  tagId: string,
  removedUserIds: string[],
  addedUserIds: string[]
) {
  console.log(
    `_updateSharedWithOfTag ${tagId} removed=${inspect(removedUserIds)} added=${inspect(addedUserIds)}`
  )
  const docRef = kilvishDb.collection("Tags").doc(tagId)
  const tagDoc = await docRef.get()
  if (!tagDoc.exists) throw new Error(`Tag ${tagId} does not exist`)

  let sharedWith: string[] = tagDoc.data()?.sharedWith || []
  if (removedUserIds.length > 0) {
    sharedWith = sharedWith.filter((id) => !removedUserIds.includes(id))
  }
  if (addedUserIds.length > 0) {
    const uniqueAdded = addedUserIds.filter((id) => !sharedWith.includes(id))
    sharedWith = [...sharedWith, ...uniqueAdded]
  }
  await docRef.update({ sharedWith })
  console.log(`_updateSharedWithOfTag: updated ${tagDoc.data()?.name} → ${inspect(sharedWith)}`)
}

export const handleTagSharingOnTagCreate = onDocumentCreated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`handleTagSharingOnTagCreate ${inspect(event.params)}`)
    const tagId = event.params.tagId
    const data = event.data?.data()
    if (!data) return
    await _applySharedWithChangesToAccessibleTagIdsAndNotifyUsers(tagId, {}, data)
    await _updateTagSharedWithFromSharedWithFriendsChanges(tagId, {}, data)
  }
)

export const handleTagUpdate = onDocumentUpdated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`handleTagUpdate ${event.params.tagId}`)
    const tagId = event.params.tagId
    const before = event.data?.before.data() as Record<string, any> | undefined
    const after = event.data?.after.data() as Record<string, any> | undefined
    if (!before || !after) return
    await _applySharedWithChangesToAccessibleTagIdsAndNotifyUsers(tagId, before, after)
    await _updateTagSharedWithFromSharedWithFriendsChanges(tagId, before, after)
    await _handleTagDataChanges(tagId, before, after)
  }
)

// Create User document if tag is shared with a user who has NOT signed up on Kilvish.
// Also queries & updates kilvishId & other information of the user in Friend's doc.
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
    const friendDoc = await kilvishDb
      .collection("Users")
      .doc(ownerId)
      .collection("Friends")
      .doc(friendId)
      .get()
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

  await kilvishDb
    .collection("Users")
    .doc(ownerId)
    .collection("Friends")
    .doc(friendId)
    .update({
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
    if (!(await tagRef.get()).exists) throw new HttpsError("not-found", "Tag not found")

    const batch = kilvishDb.batch()
    batch.update(tagRef, {
      sharedWith: admin.firestore.FieldValue.arrayUnion(userId),
      updatedBy: userId,
    })
    batch.update(kilvishDb.collection("Users").doc(userId), {
      accessibleTagIds: admin.firestore.FieldValue.arrayUnion(tagId),
    })
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
    if (!isOwner && !isSelf) {
      throw new HttpsError("permission-denied", "Only the tag owner or the user themselves can remove a member")
    }

    const batch = kilvishDb.batch()
    batch.update(kilvishDb.collection("Tags").doc(tagId), {
      sharedWith: admin.firestore.FieldValue.arrayRemove(userId),
      updatedBy: callerId,
    })
    batch.update(kilvishDb.collection("Users").doc(userId), {
      accessibleTagIds: admin.firestore.FieldValue.arrayRemove(tagId),
    })
    await batch.commit()
    console.log(`removeTagMember: user ${userId} removed from tag ${tagId} by ${callerId}`)
    return { success: true }
  }
)


