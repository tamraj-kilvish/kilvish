import * as admin from "firebase-admin"
import { kilvishDb } from "./common"

async function _updateLastFCMSentAt(userIds: string[]): Promise<void> {
  if (userIds.length === 0) return
  const batch = kilvishDb.batch()
  for (const userId of userIds) {
    batch.update(kilvishDb.collection("Users").doc(userId), {
      lastFCMSentAt: admin.firestore.FieldValue.serverTimestamp(),
    })
  }
  await batch.commit()
}

/** Send a single FCM and stamp lastFCMSentAt on the user's doc. Never throws — logs on failure. */
export async function sendSingleFCM(
  userId: string,
  token: string,
  message: Omit<admin.messaging.Message, "token">
): Promise<void> {
  try {
    await admin.messaging().send({ ...message, token })
    await _updateLastFCMSentAt([userId])
  } catch (err: any) {
    console.error(`sendSingleFCM failed for userId=${userId} token=${token} code=${err?.errorInfo?.code ?? err?.code} message=${err?.message}`)
  }
}

/** Send a multicast FCM and stamp lastFCMSentAt on every notified user's doc. Never throws — logs per-token failures. */
export async function sendMulticastFCM(
  userTokenPairs: { userId: string; token: string }[],
  message: Omit<admin.messaging.MulticastMessage, "tokens">
): Promise<void> {
  if (userTokenPairs.length === 0) return
  try {
    const response = await admin.messaging().sendEachForMulticast({
      ...message,
      tokens: userTokenPairs.map((u) => u.token),
    })
    const successfulUserIds: string[] = []
    response.responses.forEach((r, i) => {
      if (r.success) {
        successfulUserIds.push(userTokenPairs[i].userId)
      } else {
        console.error(`sendMulticastFCM failed for userId=${userTokenPairs[i].userId} token=${userTokenPairs[i].token} code=${r.error?.code} message=${r.error?.message}`)
      }
    })
    if (successfulUserIds.length > 0) await _updateLastFCMSentAt(successfulUserIds)
  } catch (err: any) {
    console.error(`sendMulticastFCM failed entirely: code=${err?.errorInfo?.code ?? err?.code} message=${err?.message}`)
  }
}

export async function _getKilvishId(userId: string): Promise<string | undefined> {
  const doc = await kilvishDb.collection("PublicInfo").doc(userId).get()
  return doc.data()?.kilvishId as string | undefined
}

/**
 * Parse updatedBy field — supports both old string format and new {userId, kilvishId} map.
 * Falls back to PublicInfo lookup for the kilvishId when the string format is used.
 */
export async function _parseUpdatedBy(updatedBy: any): Promise<{ userId?: string; kilvishId?: string }> {
  if (!updatedBy) return {}
  if (typeof updatedBy === "string") {
    const kilvishId = await _getKilvishId(updatedBy)
    return { userId: updatedBy, kilvishId }
  }
  return { userId: updatedBy.userId, kilvishId: updatedBy.kilvishId }
}

/**
 * Get FCM tokens for tag users, split into expense-owner token and member tokens.
 */
export async function _getTagUserTokens(
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

/**
 * Single function for expense create/update/delete notifications.
 * Title: "Tag: <tagName>". Body: "@ownerKilvishId created/updated/deleted expense of ₹X".
 * Actor (owner) always gets a silent data-only FCM; other members get the notification banner.
 */
export async function _notifyExpenseAction(
  eventType: "expense_created" | "expense_updated" | "expense_deleted",
  params: { tagId: string; expenseId: string },
  expenseData: any,
  tagName: string
): Promise<void> {
  try {
    const { tagId, expenseId } = params
    const { userId: actorId, kilvishId: ownerKilvishId } = await _parseUpdatedBy(expenseData.updatedBy)
    const amount: number = expenseData.amount || 0
    const action =
      eventType === "expense_created" ? "created" : eventType === "expense_updated" ? "updated" : "deleted"

    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
    if (!userTokens) return

    const { members, expenseOwnerToken } = userTokens
    const baseData: Record<string, string> = {
      type: eventType,
      tagId,
      expenseId,
      ...(actorId && { actorId }),
      ...(ownerKilvishId && { actorKilvishId: ownerKilvishId }),
    }

    if (expenseOwnerToken) {
      await sendSingleFCM(expenseData.ownerId, expenseOwnerToken, { data: baseData })
    }

    if (members.length === 0) return

    const body = `@${ownerKilvishId} ${action} expense of ₹${amount}`
    await sendMulticastFCM(members, {
      notification: { title: `Tag: ${tagName}`, body },
      data: baseData,
      apns: {
        headers: { 'apns-priority': '10' },
        payload: { aps: { 'content-available': 1, sound: 'default' } },
      },
      android: { priority: 'high' },
    })
    console.log(`${eventType} FCM: sent to ${members.length} member(s)`)
  } catch (error) {
    console.error(`Error in ${eventType} notification:`, error)
  }
}

/** Notify all tag members except the actor when a participant joins or leaves. Pure FCM — no DB writes. */
export async function _notifyMembersOfTagMemberChange(
  tagId: string,
  tagName: string,
  ownerId: string,
  affectedUserId: string,
  affectedKilvishId: string,
  verb: "joined" | "left",
  actorId: string | undefined,
) {
  try {
    const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
    const sharedWith: string[] = tagDoc.data()?.sharedWith || []
    const recipientIds = [ownerId, ...sharedWith].filter((id) => id && id !== actorId)
    if (recipientIds.length === 0) return

    const usersSnap = await kilvishDb.collection("Users").where("__name__", "in", recipientIds).get()
    const usersWithTokens = usersSnap.docs
      .filter((d) => !!d.data().fcmToken)
      .map((d) => ({ userId: d.id, token: d.data().fcmToken as string }))
    if (usersWithTokens.length === 0) return

    await sendMulticastFCM(usersWithTokens, {
      notification: { title: tagName, body: `@${affectedKilvishId} ${verb} the tag` },
      data: { type: "tag_shared", tagId, tagName }, //type is tag_shared as it will lead users to refetch with updated pariticipants
      apns: {
        headers: { 'apns-priority': '10' },
        payload: { aps: { 'content-available': 1, sound: 'default' } },
      },
      android: { priority: 'high' },
    })
    console.log(`_notifyMembersOfTagMemberChange: @${affectedKilvishId} ${verb} — sent to ${usersWithTokens.length} member(s)`)
  } catch (error) {
    console.error(`Error in _notifyMembersOfTagMemberChange: ${error}`)
  }
}
