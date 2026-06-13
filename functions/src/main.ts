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
  sendSingleFCM,
  sendMulticastFCM,
  scheduleExpenseMemberFCM,
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

type RecipientEntry = { amount: number; settlementMonth?: string }
type RecipientsMap = Record<string, RecipientEntry>

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

  async commit(tagDocRef: admin.firestore.DocumentReference, batch?: admin.firestore.WriteBatch): Promise<void> {
    if (Object.keys(this.deltas).length === 0) return
    const data: Record<string, any> = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }
    for (const [key, delta] of Object.entries(this.deltas)) {
      data[key] = admin.firestore.FieldValue.increment(delta)
    }

    // TODO: remove after all clients have migrated to the new model.
    // Keeps legacy `expense` and `recovery` fields in sync for old app versions.
    // expense  = spent + paid - received
    // recovery = spent - myShare - received + paid  (equivalent to outstanding)
    for (const [key, delta] of Object.entries(this.deltas)) {
      const parts  = key.split(".")
      const field  = parts[parts.length - 1]
      const prefix = parts.slice(0, -1).join(".")
      const expDelta = field === "spent" || field === "paid" ? delta : field === "received" ? -delta : 0
      const recDelta = field === "spent" || field === "paid" ? delta : field === "received" || field === "myShare" ? -delta : 0
      if (expDelta !== 0) data[`${prefix}.expense`]  = admin.firestore.FieldValue.increment(expDelta)
      if (recDelta !== 0) data[`${prefix}.recovery`] = admin.firestore.FieldValue.increment(recDelta)
    }

    if (batch) {
      batch.update(tagDocRef, data)
    } else {
      await tagDocRef.update(data)
    }
  }
}

async function _getTagContext(tagId: string): Promise<{
  tagDocRef: admin.firestore.DocumentReference
  tagName: string
  allMembers: string[]
}> {
  const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
  const tagDoc = await tagDocRef.get()
  if (!tagDoc.exists) throw new Error(`Tag ${tagId} does not exist`)
  const tagData = tagDoc.data()!
  return {
    tagDocRef,
    tagName: tagData.name ?? tagId,
    allMembers: [tagData.ownerId, ...(tagData.sharedWith ?? [])],
  }
}

function _hasSignificantExpenseChange(before: Record<string, any>, after: Record<string, any>): boolean {
  const beforeMonth = _monthKey((before.timeOfTransaction as admin.firestore.Timestamp).toDate())
  const afterMonth = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())
  return (
    (before.expenseAmount ?? before.amount) !== (after.expenseAmount ?? after.amount) ||
    beforeMonth !== afterMonth ||
    JSON.stringify(before.recipients ?? {}) !== JSON.stringify(after.recipients ?? {})
  )
}

// Computes the full tag-stats contribution of one expense snapshot.
// sign = +1 to apply, -1 to undo.
// Recipients map is empty ({}) in simple mode; non-empty in advanced mode.
function _applyExpenseContribution({
  update,
  expenseData,
  recipients,
  allMembers,
  sign,
}: {
  update: TagStatsUpdate
  expenseData: any
  recipients: RecipientsMap
  allMembers: string[]
  sign: 1 | -1
}): void {
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
          .applyDelta(ownerId, expenseMonth, "spent", -sign * expenseAmount)
          .applyDelta(ownerId, entry.settlementMonth, "paid", sign * entry.amount)
          .applyDelta(recipientId, entry.settlementMonth, "received", sign * entry.amount)
      } else {
        update.applyDelta(recipientId, expenseMonth, "myShare", sign * entry.amount)
      }
    }
  }
}

export const onExpenseCreated = onDocumentCreated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`onExpenseCreated ${inspect(event.params)}`)
    const { tagId, expenseId } = event.params
    const data = event.data?.data()
    if (!data) return

    const { tagDocRef, tagName, allMembers } = await _getTagContext(tagId)

    const existingRecipients: RecipientsMap = data.recipients ?? {}
    const update = new TagStatsUpdate()

    if (Object.keys(existingRecipients).length > 0) {
      // Client pre-populated recipients via saveTagLink — apply advanced-mode stats directly.
      _applyExpenseContribution({ update, expenseData: data, recipients: existingRecipients, allMembers, sign: 1 })
      await update.commit(tagDocRef)
    } else {
      // Simple mode. If client didn't write simpleParticipants (old client), stamp them now.
      _applyExpenseContribution({ update, expenseData: data, recipients: {}, allMembers, sign: 1 })
      if (!data.simpleParticipants?.length) {
        const expenseRef = tagDocRef.collection("Expenses").doc(expenseId)
        const batch = kilvishDb.batch()
        batch.update(expenseRef, { simpleParticipants: allMembers })
        await update.commit(tagDocRef, batch)
        await batch.commit()
      } else {
        await update.commit(tagDocRef)
      }
    }

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
    if (!_hasSignificantExpenseChange(beforeData, afterData)) return

    const { tagDocRef, tagName, allMembers } = await _getTagContext(tagId)

    // Full before→after diff: undo old contribution, apply new contribution.
    const update = new TagStatsUpdate()
    _applyExpenseContribution({ update, expenseData: beforeData, recipients: beforeData.recipients ?? {}, allMembers, sign: -1 })
    _applyExpenseContribution({ update, expenseData: afterData, recipients: afterData.recipients ?? {}, allMembers, sign: 1 })

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

    const { tagDocRef, tagName, allMembers } = await _getTagContext(tagId)

    // Full reversal using the recipients map that was built up over the expense's lifetime.
    const update = new TagStatsUpdate()
    _applyExpenseContribution({ update, expenseData: data, recipients: data.recipients ?? {}, allMembers, sign: -1 })
    await update.commit(tagDocRef)

    await _notifyExpenseAction("expense_deleted", { tagId, expenseId }, data, tagName)
  }
)

// Patches a single key in the parent Expense's recipients map.
// No stats work — onExpenseUpdated handles that via the map diff.
export const onRecipientWritten = onDocumentWritten(
  { document: "Tags/{tagId}/Expenses/{expenseId}/Recipients/{recipientId}", region: "asia-south1", database: "kilvish" },
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
  
  const { members, expenseOwnerToken } = userTokens

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
