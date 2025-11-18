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
admin.initializeApp()

admin.firestore().settings({
  databaseId: "kilvish",
})

// Get Firestore instance with specific database 'kilvish'
const kilvishDb = admin.firestore()

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

interface TagMonetaryUpdate {
  name: string
  totalAmountTillDate: number
  monthWiseTotal: {
    [year: number]: {
      [month: number]: number
    }
  }
}

async function _updateTagMonetarySummaryStatsDueToExpense(
  event: FirestoreEvent<any>,
  eventType: string
): Promise<TagMonetaryUpdate | undefined> {
  const { tagId } = event.params
  const expenseData =
    eventType === "expense_updated"
      ? event.data?.before.data() // For updates, get 'after' data
      : event.data?.data() // For create/delete, use regular data
  if (!expenseData) return

  console.log(
    `Entering _updateTagMonetarySummaryStatsDueToExpense for tagId ${tagId}, expenseData ${inspect(expenseData)}`
  )

  const timeOfTransaction: admin.firestore.Timestamp = expenseData.timeOfTransaction
  const timeOfTransactionInDate: Date = timeOfTransaction.toDate()
  const year: number = timeOfTransactionInDate.getFullYear()
  const month: number = timeOfTransactionInDate.getMonth()

  let diff: number = 0
  switch (eventType) {
    case "expense_created":
      diff = expenseData.amount
      break
    case "expense_updated":
      const expenseDataAfter = event.data?.after.data()
      diff = expenseDataAfter.amount - expenseData.amount
      break
    case "expense_deleted":
      diff = expenseData.amount * -1
      break
  }

  let tagData: admin.firestore.DocumentData | undefined = undefined

  const tagDocRef = kilvishDb.collection("Tags").doc(tagId)
  let tagDoc = await tagDocRef.get()
  if (!tagDoc.exists) throw new Error(`No tag document exist with ${tagId}`)
  tagData = tagDoc.data()
  if (!tagData) throw new Error(`Tag document ${tagId} has no data`)

  await tagDocRef.update({
    totalAmountTillDate: admin.firestore.FieldValue.increment(diff),
    [`monthWiseTotal.${year}.${month}`]: admin.firestore.FieldValue.increment(diff),
  })

  tagDoc = await tagDocRef.get()
  tagData = tagDoc.data()

  return {
    name: tagData!.name,
    totalAmountTillDate: tagData!.totalAmountTillDate,
    monthWiseTotal: {
      [year]: {
        [month]: tagData!.monthWiseTotal[year][month],
      },
    },
  }
}

async function _notifyUserOfExpenseUpdateInTag(
  event: FirestoreEvent<any>,
  eventType: string,
  tagData: TagMonetaryUpdate
) {
  console.log(`Entering _notifyUserOfExpenseUpdateInTag for eventType ${eventType} & tagData ${inspect(tagData)}`)
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
        tag: JSON.stringify(tagData),
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
      title: tagData.name,
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
    const updatedTagData = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_created")
    if (updatedTagData != undefined) await _notifyUserOfExpenseUpdateInTag(event, "expense_created", updatedTagData)
  }
)

/**
 * Notify when expense is UPDATED
 */
export const onExpenseUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseUpdated for tagId ${inspect(event.params)}`)
    const updatedTagData = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_updated")
    if (updatedTagData != null) await _notifyUserOfExpenseUpdateInTag(event, "expense_updated", updatedTagData)
  }
)

/**
 * Notify when expense is DELETED
 */
export const onExpenseDeleted = onDocumentDeleted(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Inside onExpenseDeleted for tagId ${inspect(event.params)}`)
    const updatedTagData = await _updateTagMonetarySummaryStatsDueToExpense(event, "expense_deleted")
    if (updatedTagData != null) await _notifyUserOfExpenseUpdateInTag(event, "expense_deleted", updatedTagData)
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
    console.error(`Error ${e}`)
  }
}

/**
 * Handle TAG updates - notify users when added/removed from sharedWith
 */
export const intimateUsersOfTagSharedWithThem = onDocumentUpdated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    console.log(`Entering intimateUsersOfTagSharedWithThem event params ${inspect(event.params)}`)
    try {
      const tagId = event.params.tagId
      const beforeData = event.data?.before.data()
      const afterData = event.data?.after.data()

      console.log(`Entering intimateUsersOfTagSharedWithThem for ${tagId}`)

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
        const friendKilvishId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(beforeData.ownerId, friendId)
        if (friendKilvishId) addedUserIds.push(friendKilvishId)
      }

      // Find removed users
      const removedUserFriends = beforeSharedWithFriends.filter(
        (userId) => !afterSharedWithFriends.includes(userId) && userId && userId.trim()
      )

      const removedUserIds: string[] = []
      for (const friendId of removedUserFriends) {
        const friendKilvishId = await _registerFriendAsKilvishUserAndReturnKilvishUserId(beforeData.ownerId, friendId)
        if (friendKilvishId) removedUserIds.push(friendKilvishId)
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
          //ToDo - check if the await can be removed
          await _notifyUserOfTagShared(userId, tagId, tagName, "tag_removed")
        }
      }

      return { success: true, addedUsers: addedUserIds.length, removedUsers: removedUserIds.length }
    } catch (error) {
      console.error("Error in onTagUpdated:", error)
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
