import { onCall, HttpsError } from "firebase-functions/v2/https"
import {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
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
  let expenseOwnerToken: string | undefined = undefined

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


async function _updateTagMonetarySummaryStatsDueToExpense(
  event: FirestoreEvent<any>,
  eventType: string
): Promise<string | undefined> /*Promise<TagMonetaryUpdate | undefined>*/ {
  const { tagId } = event.params
  const expenseData =
    eventType === "expense_updated"
      ? event.data?.before.data() // For updates, get 'before' data
      : event.data?.data() // For create/delete, use regular data
  if (!expenseData) return

  let tagData: admin.firestore.DocumentData | undefined = undefined

  const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
  let tagDoc = await tagDocRef.get()
  if (!tagDoc.exists) throw new Error(`No tag document exist with ${tagId}`)
  tagData = tagDoc.data()
  if (!tagData) throw new Error(`Tag document ${tagId} has no data`)
 

  const timeOfTransaction: admin.firestore.Timestamp = expenseData.timeOfTransaction
  const timeOfTransactionInDate: Date = timeOfTransaction.toDate()
  const year: number = timeOfTransactionInDate.getFullYear()
  const month: number = timeOfTransactionInDate.getMonth() + 1
  const monthKey = `${year}-${String(month).padStart(2, '0')}`

  const ownerId: string = expenseData.ownerId

  let diff: number = 0
  let recoveryDiff: number = 0
  
  switch (eventType) {
    
    case "expense_created":
      diff = expenseData.amount
      recoveryDiff = expenseData.recoveryAmount || 0
      break

    case "expense_updated":
      const expenseDataAfter = event.data?.after.data()
      diff = expenseDataAfter.amount - expenseData.amount
      recoveryDiff = (expenseDataAfter.recoveryAmount || 0) - (expenseData.recoveryAmount || 0)

      let tagDocUpdate: admin.firestore.DocumentData = {}

      if (diff != 0) {
          tagDocUpdate["totalTillDate.expense"] = admin.firestore.FieldValue.increment(diff)
          tagDocUpdate[`userWiseTotal.${ownerId}.expense`] = admin.firestore.FieldValue.increment(diff)
      }
      
      if (recoveryDiff != 0 && tagData.allowRecovery) {
          tagDocUpdate["totalTillDate.recovery"] = admin.firestore.FieldValue.increment(recoveryDiff)
          tagDocUpdate[`userWiseTotal.${ownerId}.recovery`] = admin.firestore.FieldValue.increment(recoveryDiff)
      }
      
      //check if the date/time of the expense is updated 
      const newTimeOfTransaction = expenseDataAfter.timeOfTransaction as admin.firestore.Timestamp
      if (!newTimeOfTransaction.isEqual(timeOfTransaction)) {
        const newTimeOfTransactionInDate: Date =  newTimeOfTransaction.toDate()
        const newYear = newTimeOfTransactionInDate.getFullYear()
        const newMonth: number = newTimeOfTransactionInDate.getMonth() + 1
        const newMonthKey = `${newYear}-${String(newMonth).padStart(2, '0')}`

        tagDocUpdate[`monthWiseTotal.${newMonthKey}.expense`] = admin.firestore.FieldValue.increment(expenseDataAfter.amount)
        tagDocUpdate[`monthWiseTotal.${newMonthKey}.${ownerId}.expense`] = admin.firestore.FieldValue.increment(expenseDataAfter.amount)
        
        tagDocUpdate[`monthWiseTotal.${monthKey}.expense`] = admin.firestore.FieldValue.increment(expenseData.amount * -1)
        tagDocUpdate[`monthWiseTotal.${monthKey}.${ownerId}.expense`] = admin.firestore.FieldValue.increment(expenseData.amount * -1)
        
        if (tagData.allowRecovery) {
          tagDocUpdate[`monthWiseTotal.${newMonthKey}.recovery`] = admin.firestore.FieldValue.increment(expenseDataAfter.recoveryAmount || 0)
          tagDocUpdate[`monthWiseTotal.${newMonthKey}.${ownerId}.recovery`] = admin.firestore.FieldValue.increment(expenseDataAfter.recoveryAmount || 0)
          
          tagDocUpdate[`monthWiseTotal.${monthKey}.recovery`] = admin.firestore.FieldValue.increment((expenseData.recoveryAmount || 0) * -1)
          tagDocUpdate[`monthWiseTotal.${monthKey}.${ownerId}.recovery`] = admin.firestore.FieldValue.increment((expenseData.recoveryAmount || 0) * -1)
        }
      }
      await tagDocRef.update(tagDocUpdate)
      return tagData!.name
      break
    case "expense_deleted":
      diff = expenseData.amount * -1
      recoveryDiff = (expenseData.recoveryAmount || 0) * -1
      break
  }


  const updateData: admin.firestore.DocumentData = {
    "totalTillDate.expense": admin.firestore.FieldValue.increment(diff),
    [`userWiseTotal.${ownerId}.expense`]: admin.firestore.FieldValue.increment(diff),
    [`monthWiseTotal.${monthKey}.expense`]: admin.firestore.FieldValue.increment(diff),
    [`monthWiseTotal.${monthKey}.${ownerId}.expense`]: admin.firestore.FieldValue.increment(diff),
  }
  
  // Add recovery tracking if tag has allowRecovery enabled
  if (tagData.allowRecovery && recoveryDiff !== 0) {
    updateData["totalTillDate.recovery"] = admin.firestore.FieldValue.increment(recoveryDiff)
    updateData[`userWiseTotal.${ownerId}.recovery`] = admin.firestore.FieldValue.increment(recoveryDiff)
    updateData[`monthWiseTotal.${monthKey}.recovery`] = admin.firestore.FieldValue.increment(recoveryDiff)
    updateData[`monthWiseTotal.${monthKey}.${ownerId}.recovery`] = admin.firestore.FieldValue.increment(recoveryDiff)
  }
  
  await tagDocRef.update(updateData)
  return tagData!.name
 
}

async function _updateTagMonetarySummaryStatsDueToSettlement(
  event: FirestoreEvent<any>,
  eventType: string
): Promise<string | undefined> {
  const expenseData =
    eventType === "settlement_updated"
      ? event.data?.before.data()
      : event.data?.data()
  if (!expenseData) return

  const settlementData = expenseData.settlements[0]
  if (!settlementData) {
    console.log("settlementData empty .. returning")
    return
  }

  const tagDocRef = kilvishDb.collection("Tags").doc(settlementData.tagId)
  let tagDoc = await tagDocRef.get()
  if (!tagDoc.exists) throw new Error(`No tag document exist with ${settlementData.tagId}`)
  const tagData = tagDoc.data()
  if (!tagData) throw new Error(`Tag document ${settlementData.tagId} has no data`)

  const year: number = settlementData.year
  const month: number = settlementData.month
  const monthKey = `${year}-${String(month).padStart(2, '0')}`
  const ownerId: string = expenseData.ownerId
  const recipientId: string = settlementData.to

  let diff: number = 0
  
  switch (eventType) {
    case "settlement_created":
      diff = expenseData.amount
      break

    case "settlement_updated":
      const expenseDataAfter = event.data?.after.data()
      diff = expenseDataAfter.amount - expenseData.amount

      const settlementDataAfter = expenseDataAfter.settlements[0]

      let tagDocUpdate: admin.firestore.DocumentData = {}

      if (diff != 0) {
        tagDocUpdate["totalTillDate.expense"] = admin.firestore.FieldValue.increment(diff)
        tagDocUpdate[`userWiseTotal.${ownerId}.expense`] = admin.firestore.FieldValue.increment(diff)
        
        // For settlement, recipient's recovery decreases (they're being paid)
        if (tagData.allowRecovery) {
          tagDocUpdate["totalTillDate.recovery"] = admin.firestore.FieldValue.increment(-diff)
          tagDocUpdate[`userWiseTotal.${recipientId}.recovery`] = admin.firestore.FieldValue.increment(-diff)
        }
      }
      
      // Check if settlement period changed
      if (settlementDataAfter.year !== year || settlementDataAfter.month !== month) {
        const newYear = settlementDataAfter.year
        const newMonth = settlementDataAfter.month
        const newMonthKey = `${newYear}-${String(newMonth).padStart(2, '0')}`

        tagDocUpdate[`monthWiseTotal.${newMonthKey}.expense`] = admin.firestore.FieldValue.increment(expenseDataAfter.amount)
        tagDocUpdate[`monthWiseTotal.${newMonthKey}.${ownerId}.expense`] = admin.firestore.FieldValue.increment(expenseDataAfter.amount)
        
        tagDocUpdate[`monthWiseTotal.${monthKey}.expense`] = admin.firestore.FieldValue.increment(-expenseData.amount)
        tagDocUpdate[`monthWiseTotal.${monthKey}.${ownerId}.expense`] = admin.firestore.FieldValue.increment(-expenseData.amount)
        
        if (tagData.allowRecovery) {
          tagDocUpdate[`monthWiseTotal.${newMonthKey}.recovery`] = admin.firestore.FieldValue.increment(-expenseDataAfter.amount)
          tagDocUpdate[`monthWiseTotal.${newMonthKey}.${recipientId}.recovery`] = admin.firestore.FieldValue.increment(-expenseDataAfter.amount)
          
          tagDocUpdate[`monthWiseTotal.${monthKey}.recovery`] = admin.firestore.FieldValue.increment(expenseData.amount)
          tagDocUpdate[`monthWiseTotal.${monthKey}.${recipientId}.recovery`] = admin.firestore.FieldValue.increment(expenseData.amount)
        }
      }
      
      await tagDocRef.update(tagDocUpdate)
      return tagData.name
      
    case "settlement_deleted":
      diff = expenseData.amount * -1
      break
  }

  // For create/delete: increment payer's expense, decrement recipient's recovery
  const updateData: admin.firestore.DocumentData = {
    "totalTillDate.expense": admin.firestore.FieldValue.increment(diff),
    [`userWiseTotal.${ownerId}.expense`]: admin.firestore.FieldValue.increment(diff),
    [`monthWiseTotal.${monthKey}.expense`]: admin.firestore.FieldValue.increment(diff),
    [`monthWiseTotal.${monthKey}.${ownerId}.expense`]: admin.firestore.FieldValue.increment(diff),
  }
  
  if (tagData.allowRecovery) {
    updateData["totalTillDate.recovery"] = admin.firestore.FieldValue.increment(-diff)
    updateData[`userWiseTotal.${recipientId}.recovery`] = admin.firestore.FieldValue.increment(-diff)
    updateData[`monthWiseTotal.${monthKey}.recovery`] = admin.firestore.FieldValue.increment(-diff)
    updateData[`monthWiseTotal.${monthKey}.${recipientId}.recovery`] = admin.firestore.FieldValue.increment(-diff)
  }
  
  await tagDocRef.update(updateData)
  
  return tagData.name
}

export async function notifyUserOfExpenseUpdateInTag(
  event: FirestoreEvent<any, Record<string, any>>,
  eventType: string,
  tagName: string
) {
  console.log(`Entering _notifyUserOfExpenseUpdateInTag for eventType ${eventType} & tag - ${inspect(tagName)}`)
  try {
    const { tagId, expenseId } = event.params
    const expenseData =
      eventType.includes("updated")
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

    message = {
      ...message,
      android: {
        notification: {
          tag: `tag_${tagId}`,  // Deduplicate by tag
        }
      },
      apns : {
        headers: {
          'apns-collapse-id': `tag_${tagId}`,  // Same collapse ID = notifications replace each other
        },
      },
      notification : {
        title: tagName,
        body: `${eventType} - ₹${expenseData.amount || 0} to ${expenseData.to || "unknown"}`,
      }
    }

    if (!eventType.includes("deleted")) {
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
    if(tagName) await notifyUserOfExpenseUpdateInTag(event, "expense_created", tagName)
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
    if (tagName != null) await notifyUserOfExpenseUpdateInTag(event, "expense_updated", tagName)
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
    if (tagName != null) await notifyUserOfExpenseUpdateInTag(event, "expense_deleted", tagName)
  }
)

/**
 * Notify when settlement is CREATED
 */
export const onSettlementCreated = onDocumentCreated(
  { document: "Tags/{tagId}/Settlements/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onSettlementCreated for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToSettlement(event, "settlement_created")
    if (tagName) await notifyUserOfExpenseUpdateInTag(event, "settlement_created", tagName)
  }
)

/**
 * Notify when settlement is UPDATED
 */
export const onSettlementUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}/Settlements/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onSettlementUpdated for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToSettlement(event, "settlement_updated")
    if (tagName != null) await notifyUserOfExpenseUpdateInTag(event, "settlement_updated", tagName)
  }
)

/**
 * Notify when settlement is DELETED
 */
export const onSettlementDeleted = onDocumentDeleted(
  { document: "Tags/{tagId}/Settlements/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onSettlementDeleted for tagId ${inspect(event.params)}`)
    const tagName = await _updateTagMonetarySummaryStatsDueToSettlement(event, "settlement_deleted")
    if (tagName != null) await notifyUserOfExpenseUpdateInTag(event, "settlement_deleted", tagName)
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

    if(type == "tag_shared") {
      await kilvishDb
        .collection("Users")
        .doc(userId)
        .update({
          accessibleTagIds:
            admin.firestore.FieldValue.arrayUnion(tagId)
        })
      console.log(`Added ${tagId} to ${userId} document`)
    }
    // for tag removed case, removal of tagId is handled in _removeTagFromUserExpenses

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

async function _removeTagFromUserExpenses(userId: string, tagId: string) {
  console.log(`Entering _removeTagFromUserExpenses with userId ${userId} & tagId ${tagId}`)
  
  // Get all expenses for this user
  const userExpensesSnapshot = await kilvishDb
    .collection("Users")
    .doc(userId)
    .collection("Expenses")
    .get()

  const batch = kilvishDb.batch()

  batch.update(kilvishDb.collection("Users").doc(userId), {
    accessibleTagIds: admin.firestore.FieldValue.arrayRemove(tagId)
  })
  console.log(`${tagId} will be removed from ${userId} document after this batch operation completes`)
  
  for (const expenseDoc of userExpensesSnapshot.docs) {
    const expenseData = expenseDoc.data()
    let needsUpdate = false
    const updates: admin.firestore.DocumentData = {}

    // Check if expense has this tagId
    const tagIds = (expenseData.tagIds as string[]) || []
    if (tagIds.includes(tagId)) {
      updates.tagIds = admin.firestore.FieldValue.arrayRemove(tagId)
      console.log(`${tagId} scheduled to remove from tagIds array of ${expenseDoc.id} document for user ${userId}`)
      needsUpdate = true
    }

    // Check if expense has settlement for this tag
    const settlements = (expenseData.settlements as any[]) || []
    const filteredSettlements = settlements.filter((s) => s.tagId !== tagId)
    if (filteredSettlements.length !== settlements.length) {
      updates.settlements = filteredSettlements
      needsUpdate = true
      console.log(`${tagId} scheduled to remove from settlements array of ${expenseDoc.id} document for user ${userId}`)
    }

    if (needsUpdate) {
      batch.update(expenseDoc.ref, updates)
    }
  }

  await batch.commit()
  console.log(`Cleaned up expenses for user ${userId} after tag ${tagId} deletion`)
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
      
      const tagName = data.name || "Unknown"
      const sharedWith = (data.sharedWith as string[]) || []     
      for (const userId of sharedWith) {
        await _removeTagFromUserExpenses(userId, tagId)
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

      const tagName = afterData.name || "Unknown"

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
          await _removeTagFromUserExpenses(userId, tagId)  // ADD THIS LINE
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