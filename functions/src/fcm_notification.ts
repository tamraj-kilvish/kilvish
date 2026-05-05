import * as admin from "firebase-admin"
import { kilvishDb } from "./common"

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
      await admin.messaging().send({ token: expenseOwnerToken, data: baseData })
    }

    if (members.length === 0) return

    const body = `@${ownerKilvishId} ${action} expense of ₹${amount}`
    await admin.messaging().sendEachForMulticast({
      tokens: members.map((m) => m.token),
      notification: { title: `Tag: ${tagName}`, body },
      data: baseData,
    })
    console.log(`${eventType} FCM: sent to ${members.length} member(s)`)
  } catch (error) {
    console.error(`Error in ${eventType} notification:`, error)
  }
}

export async function _notifyUserOfTagShared(
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
    console.log(
      `${type === "tag_shared" ? "Added" : "Removed"} tag ${tagId} ${type === "tag_shared" ? "to" : "from"} user ${userId}'s accessibleTagIds`
    )

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
export async function _notifyOtherMembersOfTagChange(
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
        ? `@${ownerKilvishId} added @${affectedKilvishId}`
        : `@${ownerKilvishId} removed @${affectedKilvishId}`

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
