import { onCall, HttpsError } from "firebase-functions/v2/https"
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore"
import { onTaskDispatched } from "firebase-functions/v2/tasks"
import * as admin from "firebase-admin"
import { inspect } from "util"
import { kilvishDb } from "./common"
import { TagStatsUpdate } from "./expense_handlers"
import {
  _getKilvishId,
  _parseUpdatedBy,
  _getTagUserTokens,
  _notifyMembersOfTagMemberChange,
  _updateLastFCMSentAt,
  sendMulticastFCM,
} from "./fcm_notification"

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

async function _registerFriendAsKilvishUserAndReturnKilvishUserId(
  ownerId: string,
  friendId: string,
  _friendData?: admin.firestore.DocumentData
): Promise<string | undefined> {
  console.log(`_registerFriend ownerId=${ownerId} friendId=${friendId}`)
  let friendData = _friendData
  if (!friendData) {
    const doc = await kilvishDb
      .collection("Users")
      .doc(ownerId)
      .collection("Friends")
      .doc(friendId)
      .get()
    friendData = doc.data()
  }

  let kilvishUserId = friendData?.kilvishUserId as string | undefined
  if (kilvishUserId) return kilvishUserId

  const phoneNumber = friendData?.phoneNumber as string | undefined
  if (!phoneNumber) return

  const userQuery = await kilvishDb
    .collection("Users")
    .where("phone", "==", phoneNumber)
    .limit(1)
    .get()

  if (!userQuery.empty) {
    kilvishUserId = userQuery.docs[0].id
  } else {
    const newDoc = await kilvishDb.collection("Users").add({
      phone: phoneNumber,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      accessibleTagIds: [],
    })
    kilvishUserId = newDoc.id
  }

  await kilvishDb
    .collection("Users")
    .doc(ownerId)
    .collection("Friends")
    .doc(friendId)
    .update({ kilvishUserId, updatedAt: admin.firestore.FieldValue.serverTimestamp() })

  return kilvishUserId
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

// Cloud Tasks handler: fires 1 minute after the last expense update for a given expenseId.
// Checks the eTag stored on the expense doc — drops if stale (a newer update superseded this one).
export const sendExpenseMemberFCMTask = onTaskDispatched(
  {
    retryConfig: { maxAttempts: 1 },
    rateLimits: { maxConcurrentDispatches: 20 },
    region: "asia-south1",
  },
  async (req) => {
    const { expenseId, tagId, eTag } = req.data as {
      expenseId: string
      tagId: string
      eTag: string
    }
    console.log(`sendExpenseMemberFCMTask: expenseId=${expenseId} tagId=${tagId}`)

    const expenseRef = kilvishDb
      .collection("Tags")
      .doc(tagId)
      .collection("Expenses")
      .doc(expenseId)
    const expenseDoc = await expenseRef.get()

    if (!expenseDoc.exists) {
      console.log(`sendExpenseMemberFCMTask: expense ${expenseId} deleted — skipping`)
      return
    }

    const expenseData = expenseDoc.data()!
    if (expenseData.fcmETag !== eTag) {
      console.log(`sendExpenseMemberFCMTask: stale eTag for expense ${expenseId} — dropping`)
      return
    }

    const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
    if (!tagDoc.exists) return
    const tagName: string = tagDoc.data()?.name ?? tagId

    const { kilvishId: ownerKilvishId } = await _parseUpdatedBy(expenseData.updatedBy)
    const amount: number = expenseData.expenseAmount ?? expenseData.amount

    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
    if (!userTokens || userTokens.members.length === 0) return

    const body = `@${ownerKilvishId} updated expense of ₹${amount}`
    await sendMulticastFCM(userTokens.members, {
      notification: { title: `Tag: ${tagName}`, body },
      data: { type: "expense_updated", tagId, expenseId },
      apns: {
        headers: { "apns-priority": "10" },
        payload: { aps: { "content-available": 1, sound: "default" } },
      },
      android: { priority: "high" },
    })
    console.log(
      `sendExpenseMemberFCMTask: sent to ${userTokens.members.length} member(s) — "${body}"`
    )
  }
)
