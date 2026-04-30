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
          unseenExpenseIds: [],

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

/**
 * Helper: Get FCM tokens for tag users (excluding a specific user)
 */
async function _getTagUserTokens(
  tagId: string,
  expenseOwnerId: string
): Promise<{ tokens: string[]; expenseOwnerToken: string | undefined } | undefined> {
  console.log(`Entering _getTagUserTokens for tagId - ${tagId}, expenseOwnerId ${expenseOwnerId}`)

  const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
  if (!tagDoc.exists) return

  const tagData = tagDoc.data()
  if (!tagData) return

  const friendIds = ((tagData.sharedWith as string[]) || []).filter((id) => id && id.trim())

  //if (friendIds.length === 0) return { tokens: [], ownerToken: undefined }

  const userIdsToNotify: string[] = [tagData.ownerId, ...friendIds]

  const usersSnapshot = await kilvishDb.collection("Users").where("__name__", "in", userIdsToNotify).get()

  const tokens: string[] = []
  let expenseOwnerToken = undefined

  usersSnapshot.forEach((doc) => {
    const userData = doc.data()
    if (doc.id == expenseOwnerId && userData.fcmToken) {
      expenseOwnerToken = userData.fcmToken
    }
    if (doc.id !== expenseOwnerId && userData.fcmToken) {
      tokens.push(userData.fcmToken)
    }
  })

  return { tokens: tokens, expenseOwnerToken: expenseOwnerToken }
}

function _monthKey(date: Date): string {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  return `${year}-${month}`
}

interface UserStats {
  expense: number
  recovery: number
}

interface TagTotal {
  [userId: string]: UserStats
  acrossUsers: UserStats
}

interface TagMonthWiseTotal {
  [monthKey: string]: TagTotal
}

// Accumulates atomic Firestore increments for a single Tag doc and commits them in one update.
// Pass "acrossUsers" as userId for the aggregate row.
class TagStatsUpdate {
  private data: Record<string, any> = {}

  applyDelta(userId: string, monthKey: string, field: "expense" | "recovery", delta: number): this {
    const other = field === "expense" ? "recovery" : "expense"
    this.data[`total.${userId}.${field}`] = admin.firestore.FieldValue.increment(delta)
    this.data[`monthWiseTotal.${monthKey}.${userId}.${field}`] = admin.firestore.FieldValue.increment(delta)
    this.data[`monthWiseTotal.${monthKey}.${userId}.${other}`] ??= admin.firestore.FieldValue.increment(0)
    return this
  }

  set(key: string, value: any): this {
    this.data[key] = value
    return this
  }

  isEmpty(): boolean {
    return Object.keys(this.data).length === 0
  }

  async commit(tagDocRef: admin.firestore.DocumentReference): Promise<void> {
    if (!this.isEmpty()) await tagDocRef.update(this.data)
  }
}

function _hasSignificantExpenseChange(before: Record<string, any>, after: Record<string, any>): boolean {
  const beforeMonth = _monthKey((before.timeOfTransaction as admin.firestore.Timestamp).toDate())
  const afterMonth = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())
  return (
    before.amount !== after.amount ||
    beforeMonth !== afterMonth ||
    (before.totalOutstandingAmount || 0) !== (after.totalOutstandingAmount || 0)
  )
}

async function _recalculateUserWiseRecovery(
  tagId: string,
  tagDocRef: admin.firestore.DocumentReference
): Promise<void> {
  const [expensesSnapshot, tagDoc] = await Promise.all([
    kilvishDb.collection("Tags").doc(tagId).collection("Expenses").get(),
    tagDocRef.get(),
  ])

  const tagData = tagDoc.data() || {}
  // Flat structure: all keys under total except 'acrossUsers' are userIds
  const totalData: Record<string, any> = tagData.total || {}
  const currentUserIds = Object.keys(totalData).filter((k) => k !== "acrossUsers")
  const currentMonthWise: Record<string, any> = tagData.monthWiseTotal || {}

  let totalRecovery = 0
  const userRecovery: Record<string, number> = {}
  const monthUserRecovery: Record<string, Record<string, number>> = {}

  for (const doc of expensesSnapshot.docs) {
    const data = doc.data()
    const ownerId: string = data.ownerId || ""
    const outstanding = (data.totalOutstandingAmount as number) || 0
    const recipients: Array<{ userId: string; amount: number }> = data.recipients || []
    if (outstanding <= 0 || !ownerId) continue

    const txTimestamp = data.timeOfTransaction as admin.firestore.Timestamp
    const monthKey = txTimestamp ? _monthKey(txTimestamp.toDate()) : null

    totalRecovery += outstanding

    // Owner is owed the outstanding amount (positive recovery)
    userRecovery[ownerId] = (userRecovery[ownerId] || 0) + outstanding
    if (monthKey) {
      if (!monthUserRecovery[monthKey]) monthUserRecovery[monthKey] = {}
      monthUserRecovery[monthKey][ownerId] = (monthUserRecovery[monthKey][ownerId] || 0) + outstanding
    }

    // Each recipient owes their portion (negative recovery = they owe)
    for (const r of recipients) {
      if (!r.userId) continue
      userRecovery[r.userId] = (userRecovery[r.userId] || 0) - r.amount
      if (monthKey) {
        if (!monthUserRecovery[monthKey]) monthUserRecovery[monthKey] = {}
        monthUserRecovery[monthKey][r.userId] = (monthUserRecovery[monthKey][r.userId] || 0) - r.amount
      }
    }
  }

  const updateData: Record<string, any> = {
    "total.acrossUsers.recovery": totalRecovery,
  }

  // Flat: total.{userId}.recovery  — also initialise expense: 0 for brand-new entries (recipients)
  const allUserIds = new Set([...currentUserIds, ...Object.keys(userRecovery)])
  for (const userId of allUserIds) {
    updateData[`total.${userId}.recovery`] = userRecovery[userId] ?? 0
    if (!currentUserIds.includes(userId)) {
      updateData[`total.${userId}.expense`] = 0
    }
  }

  // Month-wise: monthWiseTotal.{key}.{userId}.recovery
  for (const [monthKey, monthRecovery] of Object.entries(monthUserRecovery)) {
    const currentMonthData: Record<string, any> = currentMonthWise[monthKey] || {}
    const currentMonthUserIds = Object.keys(currentMonthData).filter((k) => k !== "acrossUsers")
    const positiveRecovery = Object.values(monthRecovery).filter((v) => v > 0).reduce((s, v) => s + v, 0)
    updateData[`monthWiseTotal.${monthKey}.acrossUsers.recovery`] = positiveRecovery

    const allMonthUserIds = new Set([...currentMonthUserIds, ...Object.keys(monthRecovery)])
    for (const userId of allMonthUserIds) {
      updateData[`monthWiseTotal.${monthKey}.${userId}.recovery`] = monthRecovery[userId] ?? 0
      if (!currentMonthUserIds.includes(userId)) {
        updateData[`monthWiseTotal.${monthKey}.${userId}.expense`] = 0
      }
    }
  }

  await tagDocRef.update(updateData)
  console.log(`_recalculateUserWiseRecovery tag ${tagId}: total=${totalRecovery}, perUser=${JSON.stringify(userRecovery)}`)
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

  const ownerId: string = before.ownerId
  const txTimestamp = before.timeOfTransaction as admin.firestore.Timestamp
  const monthKey = _monthKey(txTimestamp.toDate())
  const update = new TagStatsUpdate()

  if (eventType === "expense_created") {
    update
      .applyDelta(ownerId, monthKey, "expense", before.amount)
      .applyDelta("acrossUsers", monthKey, "expense", before.amount)
    const outstanding: number = before.totalOutstandingAmount || 0
    if (outstanding > 0) {
      update
        .applyDelta(ownerId, monthKey, "recovery", outstanding)
        .applyDelta("acrossUsers", monthKey, "recovery", outstanding)
    }
  } else if (eventType === "expense_deleted") {
    update
      .applyDelta(ownerId, monthKey, "expense", -before.amount)
      .applyDelta("acrossUsers", monthKey, "expense", -before.amount)
    const outstanding: number = before.totalOutstandingAmount || 0
    if (outstanding > 0) {
      update
        .applyDelta(ownerId, monthKey, "recovery", -outstanding)
        .applyDelta("acrossUsers", monthKey, "recovery", -outstanding)
    }
  } else {
    // expense_updated
    const after = event.data?.after.data()!
    const newMonthKey = _monthKey((after.timeOfTransaction as admin.firestore.Timestamp).toDate())
    const amountDiff: number = after.amount - before.amount
    const outstandingDiff: number = (after.totalOutstandingAmount || 0) - (before.totalOutstandingAmount || 0)

    if (monthKey !== newMonthKey) {
      // Move expense from old to new month; total changes only by diff
      update
        .set(`monthWiseTotal.${monthKey}.${ownerId}.expense`, admin.firestore.FieldValue.increment(-before.amount))
        .set(`monthWiseTotal.${monthKey}.acrossUsers.expense`, admin.firestore.FieldValue.increment(-before.amount))
        .set(`monthWiseTotal.${newMonthKey}.${ownerId}.expense`, admin.firestore.FieldValue.increment(after.amount))
        .set(`monthWiseTotal.${newMonthKey}.acrossUsers.expense`, admin.firestore.FieldValue.increment(after.amount))
      if (amountDiff !== 0) {
        update
          .set(`total.${ownerId}.expense`, admin.firestore.FieldValue.increment(amountDiff))
          .set(`total.acrossUsers.expense`, admin.firestore.FieldValue.increment(amountDiff))
      }

      // Move recovery from old to new month
      const oldOutstanding: number = before.totalOutstandingAmount || 0
      const newOutstanding: number = after.totalOutstandingAmount || 0
      if (oldOutstanding > 0) {
        update
          .set(`monthWiseTotal.${monthKey}.${ownerId}.recovery`, admin.firestore.FieldValue.increment(-oldOutstanding))
          .set(`monthWiseTotal.${monthKey}.acrossUsers.recovery`, admin.firestore.FieldValue.increment(-oldOutstanding))
      }
      if (newOutstanding > 0) {
        update
          .set(`monthWiseTotal.${newMonthKey}.${ownerId}.recovery`, admin.firestore.FieldValue.increment(newOutstanding))
          .set(`monthWiseTotal.${newMonthKey}.acrossUsers.recovery`, admin.firestore.FieldValue.increment(newOutstanding))
      }
      if (outstandingDiff !== 0) {
        update
          .set(`total.${ownerId}.recovery`, admin.firestore.FieldValue.increment(outstandingDiff))
          .set(`total.acrossUsers.recovery`, admin.firestore.FieldValue.increment(outstandingDiff))
      }

      // Move recipients' recovery between months (their total.{userId}.recovery unchanged)
      const recipientsSnap = await kilvishDb
        .collection("Tags").doc(tagId)
        .collection("Expenses").doc(expenseId)
        .collection("Recipients").get()
      for (const doc of recipientsSnap.docs) {
        const recipientId = doc.id
        const amount: number = (doc.data().amount as number) || 0
        update
          .set(`monthWiseTotal.${monthKey}.${recipientId}.recovery`, admin.firestore.FieldValue.increment(amount))
          .set(`monthWiseTotal.${newMonthKey}.${recipientId}.recovery`, admin.firestore.FieldValue.increment(-amount))
      }
    } else {
      // Same month — simple increments
      if (amountDiff !== 0) {
        update
          .applyDelta(ownerId, monthKey, "expense", amountDiff)
          .applyDelta("acrossUsers", monthKey, "expense", amountDiff)
      }
      if (outstandingDiff !== 0) {
        update
          .applyDelta(ownerId, monthKey, "recovery", outstandingDiff)
          .applyDelta("acrossUsers", monthKey, "recovery", outstandingDiff)
      }
    }
  }

  await update.commit(tagDocRef)
  return tagName
}

async function _notifyUserOfExpenseUpdateInTag(
  event: FirestoreEvent<any>,
  eventType: string,
  tagName: string
) {
  console.log(`Entering _notifyUserOfExpenseUpdateInTag for eventType ${eventType} & tag - ${inspect(tagName)}`)
  try {
    const { tagId, expenseId } = event.params
    const expenseData =
      eventType === "expense_updated"
        ? event.data?.after.data() // For updates, get 'after' data
        : event.data?.data() // For create/delete, use regular data

    if (!expenseData) return

    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
    console.log(`Tokens to be notified ${inspect(userTokens)}`)
    if (!userTokens) return

    const { tokens: fcmTokens, expenseOwnerToken } = userTokens

    let message: any = {
      data: {
        type: eventType,
        tagId,
        expenseId,
      },
    }
    //push tag update to expense owner without notification, no need of sending expense data
    if (expenseOwnerToken != null) {
      const response = await admin.messaging().send({ token: expenseOwnerToken, ...message })
      console.log(`Sent updated tag monetary status info to owner with ${response}`)
    }

    //notify rest of entire payload with notification
    if (fcmTokens.length === 0) return

    message.notification = {
      title: tagName,
      body: `${eventType} - ₹${expenseData.amount || 0} to ${expenseData.to || "unknown"}`,
    }

    if (eventType != "expense_deleted") {
      message.data.expense = JSON.stringify({
        id: expenseId,
        to: expenseData.to || "",
        amount: (expenseData.amount || 0).toString(),
        timeOfTransaction: expenseData.timeOfTransaction?.toDate?.().toISOString() || new Date().toISOString(),
        updatedAt: expenseData.updatedAt?.toDate?.().toISOString() || new Date().toISOString(),
        notes: expenseData.notes || null,
        receiptUrl: expenseData.receiptUrl || null,
      })
    }

    const response = await admin.messaging().sendEachForMulticast({ tokens: fcmTokens, ...message })
    console.log(`${eventType} FCM: sent to ${response.successCount} users`)
  } catch (error) {
    console.error(`Error in ${eventType} handling:`, error)
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
    if(tagName) await _notifyUserOfExpenseUpdateInTag(event, "expense_created", tagName)
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
    if (tagName != null) await _notifyUserOfExpenseUpdateInTag(event, "expense_updated", tagName)
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
    if (tagName != null) await _notifyUserOfExpenseUpdateInTag(event, "expense_deleted", tagName)
  }
)

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

    const amountDelta: number = (after?.amount || 0) - (before?.amount || 0)
    if (amountDelta === 0) return

    const expenseDoc = await kilvishDb
      .collection("Tags").doc(tagId)
      .collection("Expenses").doc(expenseId).get()
    if (!expenseDoc.exists) return

    const txTimestamp = expenseDoc.data()!.timeOfTransaction as admin.firestore.Timestamp
    const monthKey = _monthKey(txTimestamp.toDate())

    await new TagStatsUpdate()
      .applyDelta(recipientId, monthKey, "recovery", -amountDelta)
      .commit(kilvishDb.collection("Tags").doc(tagId))
    console.log(`onRecipientWritten: ${recipientId} recovery updated by ${-amountDelta} in tag ${tagId}`)
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

async function _notifyUserOfTagShared(userId: string, tagId: string, tagName: string, type: string) {
  console.log(`Inside _notifyUserOfTagShared userId ${userId} tagName ${tagName}`)
  try {
    let userDoc = await kilvishDb.collection("Users").doc(userId).get()
    if (!userDoc.exists) return

    const userData = userDoc.data()
    if (!userData) return

    const fcmToken = userData.fcmToken as string | undefined

    // Update user's accessibleTagIds
    //const accessibleTagIds = (userData.accessibleTagIds as string[]) || []
    //if (!accessibleTagIds.includes(tagId)) {
    await kilvishDb
      .collection("Users")
      .doc(userId)
      .update({
        accessibleTagIds:
          type == "tag_shared"
            ? admin.firestore.FieldValue.arrayUnion(tagId)
            : admin.firestore.FieldValue.arrayRemove(tagId),
      })
    if (type == "tag_shared") {
      console.log(`Added tag ${tagId} to user ${userId}'s accessibleTagIds`)
    } else {
      console.log(`Removed tag ${tagId} from user ${userId}'s accessibleTagIds`)
    }
    //}

    // Send notification only if they have FCM token
    if (fcmToken) {
      await admin.messaging().send({
        data: { type: type, tagId, tagName },
        notification: {
          title: type == "tag_shared" ? `New tag shared with you` : `Tag access removed`,
          body:
            type == "tag_shared" ? `${tagName} has been shared with you` : `You no longer have access to ${tagName}`,
        },
        token: fcmToken,
      })

      if (type == "tag_shared") {
        console.log(`Tag share notification sent to user: ${userId}`)
      } else {
        console.log(`Tag removal notification sent to user: ${userId}`)
      }
    }
  } catch (error) {
    console.error(`Error in _notifyUserOfTagShared ${error}`)
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
      console.log(`Users removed from tag ${tagName}:`, removedUserIds)

      for (const userId of removedUserIds) {
        await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed")
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
      console.log(`Users added to tag ${tagName}:`, addedUserIds)

      for (const userId of addedUserIds) {
        await _notifyUserOfTagShared(userId, tagId, tagName, "tag_shared")
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
        for (const userId of addedUserIds) {
          init
            .set(`total.${userId}.expense`, admin.firestore.FieldValue.increment(0))
            .set(`total.${userId}.recovery`, admin.firestore.FieldValue.increment(0))
        }
        await init.commit(kilvishDb.collection("Tags").doc(tagId))
      }

      const tagName = afterData.name || "Unknown"

      // Notify tag owner so their cache refreshes with updated sharedWith
      await _sendTagUpdatedToOwner(tagId, beforeData.ownerId, tagName)

      // Notify newly added users
      if (addedUserIds.length > 0) {
        console.log(`Users added to tag ${tagId}:`, addedUserIds)

        for (const userId of addedUserIds) {
          await _notifyUserOfTagShared(userId, tagId, tagName, "tag_shared")
        }
      }

      // Notify removed users
      if (removedUserIds.length > 0) {
        console.log(`Users removed from tag ${tagId}:`, removedUserIds)

        for (const userId of removedUserIds) {
          //TODO - check if the await can be removed
          await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed")
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
      unseenExpenseIds: [],
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
