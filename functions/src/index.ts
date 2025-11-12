import { onCall, HttpsError } from "firebase-functions/v2/https"
import {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
  FirestoreEvent,
} from "firebase-functions/v2/firestore"
import * as admin from "firebase-admin"

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
          //   createdAt: admin.firestore.FieldValue.serverTimestamp(),
          //   lastLogin: admin.firestore.FieldValue.serverTimestamp(),
        }

        await newUserRef.set(newUserData)
        await admin.auth().setCustomUserClaims(uid, { userId: newUserRef.id })

        await kilvishDb.collection("PublicInfo").doc(newUserRef.id).set({
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          lastLogin: admin.firestore.FieldValue.serverTimestamp(),
        })

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

      const publicInfoDoc = await kilvishDb.collection("PublicInfo").doc(userDocId).get()
      if (publicInfoDoc.exists) {
        await kilvishDb.collection("PublicInfo").doc(userDocId).update({
          lastLogin: admin.firestore.FieldValue.serverTimestamp(),
        })
      } else {
        await kilvishDb.collection("PublicInfo").doc(userDocId).set({
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          lastLogin: admin.firestore.FieldValue.serverTimestamp(),
        })
      }

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
  const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
  if (!tagDoc.exists) return

  const tagData = tagDoc.data()
  if (!tagData) return

  const friendIds = ((tagData.sharedWith as string[]) || []).filter((id) => id && id.trim())
  friendIds.push(tagData.ownerId)

  //if (friendIds.length === 0) return { tokens: [], ownerToken: undefined }

  const friendsSnapshot = await kilvishDb
    .collection("Users")
    .doc(tagData.ownerId)
    .collection("Friends")
    .where("__name__", "in", friendIds)
    .get()

  const userIds: string[] = []
  for (const doc of friendsSnapshot.docs) {
    let kilvishUserId = doc.data().kilvishUserId
    if (!kilvishUserId) {
      kilvishUserId = await _getUserFromPhoneAndUpdateKilvishIdinFriend(tagData.ownerId, doc.id, doc.data())
    }
    if (kilvishUserId) userIds.push(kilvishUserId)
  }

  const usersSnapshot = await kilvishDb.collection("Users").where("__name__", "in", userIds).get()

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

  //   tagData.totalAmountTillDate = tagData.totalAmountTillDate || 0
  //   tagData[year] = tagData[year] || {}
  //   tagData[year][month] = tagData[year][month] || 0

  //   tagData.totalAmountTillDate += diff
  //   tagData[year][month] += diff

  //   await tagDocRef.update(tagData)
  // return tagData
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
  try {
    const { tagId, expenseId } = event.params
    const expenseData =
      eventType === "expense_updated"
        ? event.data?.after.data() // For updates, get 'after' data
        : event.data?.data() // For create/delete, use regular data

    if (!expenseData) return

    const userTokens = await _getTagUserTokens(tagId, expenseData.ownerId)
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
      const response = await admin.messaging().send(message)
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
    console.log(`${eventType} FCM: ${response.successCount} sent`)
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

/**
 * Handle TAG updates - notify users when added/removed from sharedWith
 */
export const intimateUsersOfTagSharedWithThem = onDocumentUpdated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    try {
      const tagId = event.params.tagId
      const beforeData = event.data?.before.data()
      const afterData = event.data?.after.data()

      if (!beforeData || !afterData) return

      //   if (beforeData.doNotProcess != null || afterData.doNotProcess != null) {
      //     if (afterData.doNotProcess != null) {
      //       console.log(`afterData has doNotProcess, skipping`)
      //       await kilvishDb.collection("Tags").doc(tagId).update({
      //         doNotProcess: FieldValue.delete(),
      //       })
      //     } else {
      //       console.log(`beforeData has doNotProcess .. skipping`)
      //     }
      //     return
      //   }

      const beforeSharedWith = (beforeData.sharedWith as string[]) || []
      const afterSharedWith = (afterData.sharedWith as string[]) || []

      // there is no change in users with whom the Tag is shared with
      if (_setsAreEqual(new Set(beforeSharedWith), new Set(afterSharedWith))) return

      // Find newly added users
      const addedUserFriends = afterSharedWith.filter(
        (userId) => !beforeSharedWith.includes(userId) && userId && userId.trim()
      )

      const addedUserIds: string[] = []
      var friendsSnapshot = await kilvishDb
        .collection("Users")
        .doc(beforeData.ownerId)
        .collection("Friends")
        .where("__name__", "in", addedUserFriends)
        .get()

      friendsSnapshot.forEach((doc) => {
        if (doc.data().kilvishUserId) addedUserIds.push(doc.data().kilvishUserId)
      })

      // Find removed users
      const removedUserFriends = beforeSharedWith.filter(
        (userId) => !afterSharedWith.includes(userId) && userId && userId.trim()
      )
      const removedUserIds: string[] = []
      friendsSnapshot = await kilvishDb
        .collection("Users")
        .doc(beforeData.ownerId)
        .collection("Friends")
        .where("__name__", "in", removedUserFriends)
        .get()

      friendsSnapshot.forEach((doc) => {
        if (doc.data().kilvishUserId) removedUserIds.push(doc.data().kilvishUserId)
      })

      const tagName = afterData.name || "Unknown"

      //   // use this variable to update the Tag sharedWith at the end
      //   const updatedSharedWith: string[] = [...afterSharedWith]
      //   let isSharedWithUpdated: boolean = false

      // Notify newly added users
      if (addedUserIds.length > 0) {
        console.log(`Users added to tag ${tagId}:`, addedUserIds)

        for (const userId of addedUserIds) {
          let userDoc = await kilvishDb.collection("Users").doc(userId).get()

          // If user doesn't exist, this might be a phone number - try to create user
          //   if (!userDoc.exists) {
          //     const newUserId = await createUserAndUpdateSharedWith(userId, tagId, updatedSharedWith)
          //     if (newUserId != null) {
          //       userDoc = await kilvishDb.collection("Users").doc(newUserId).get()
          //       isSharedWithUpdated = true
          //     }
          //   }

          if (!userDoc.exists) continue

          const userData = userDoc.data()
          if (!userData) continue

          const fcmToken = userData.fcmToken as string | undefined

          // Update user's accessibleTagIds
          const accessibleTagIds = (userData.accessibleTagIds as string[]) || []
          if (!accessibleTagIds.includes(tagId)) {
            await kilvishDb
              .collection("Users")
              .doc(userId)
              .update({
                accessibleTagIds: admin.firestore.FieldValue.arrayUnion(tagId),
              })
            console.log(`Added tag ${tagId} to user ${userId}'s accessibleTagIds`)
          }

          // Send notification only if they have FCM token
          if (fcmToken) {
            await admin.messaging().send({
              data: { type: "tag_shared", tagId, tagName },
              notification: {
                title: `New tag shared with you`,
                body: `${tagName} has been shared with you`,
              },
              token: fcmToken,
            })

            console.log(`Tag share notification sent to user: ${userId}`)
          }
        }
      }

      // Notify removed users
      if (removedUserIds.length > 0) {
        console.log(`Users removed from tag ${tagId}:`, removedUserIds)

        for (const userId of removedUserIds) {
          const userDoc = await kilvishDb.collection("Users").doc(userId).get()
          if (!userDoc.exists) continue

          const userData = userDoc.data()
          if (!userData) continue

          const fcmToken = userData.fcmToken as string | undefined

          // Update user's accessibleTagIds
          const accessibleTagIds = (userData.accessibleTagIds as string[]) || []
          if (accessibleTagIds.includes(tagId)) {
            await kilvishDb
              .collection("Users")
              .doc(userId)
              .update({
                accessibleTagIds: admin.firestore.FieldValue.arrayRemove(tagId),
              })
            console.log(`Removed tag ${tagId} from user ${userId}'s accessibleTagIds`)
          }

          // Send notification if they have FCM token
          if (fcmToken) {
            await admin.messaging().send({
              data: { type: "tag_removed", tagId, tagName },
              notification: {
                title: `Tag access removed`,
                body: `You no longer have access to ${tagName}`,
              },
              token: fcmToken,
            })

            console.log(`Tag removal notification sent to user: ${userId}`)
          }
        }
      }

      //   if (isSharedWithUpdated) {
      //     await kilvishDb.collection("Tags").doc(tagId).update({
      //       sharedWith: updatedSharedWith,
      //       doNotProcess: true,
      //     })
      //     console.log(`Updated tag ${tagId} sharedWith to ${updatedSharedWith}`)
      //   }

      return { success: true, addedUsers: addedUserIds.length, removedUsers: removedUserIds.length }
    } catch (error) {
      console.error("Error in onTagUpdated:", error)
      throw error
    }
  }
)

// Create User document if tag is shared with a user who has NOT signed up on Kilvish
// Also query & update kilvishId & other information of the user in Friend's doc
async function _getUserFromPhoneAndUpdateKilvishIdinFriend(
  ownerId: string,
  friendId: string,
  friendData: admin.firestore.DocumentData
): Promise<string | undefined> {
  let kilvishUserId = friendData.kilvishUserId as string | undefined
  if (kilvishUserId) {
    console.log(`kilvishUserId ${friendData.kilvishUserId} exist for ${friendId} .. exiting`)
    return
  }

  const phoneNumber = friendData.phoneNumber as string | undefined
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

    // const publicInfoDoc = await kilvishDb.collection("PublicInfo").doc(kilvishUserId).get()
    // const publicInfoData = publicInfoDoc.data()

    // const kilvishId = (publicInfoData?.kilvishId as string | undefined) || null

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
    //kilvishId: kilvishId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  })

  console.log(`Updated friend ${friendId} with kilvishUserId: ${kilvishUserId}`)
  return kilvishUserId
}

export const findOrCreateFriendWithPhoneNumberAndAddTheirKilvishId = onDocumentCreated(
  { document: "Users/{userId}/Friends/{friendId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    try {
      const { userId, friendId } = event.params
      const friendData = event.data?.data()
      if (!friendData) return

      await _getUserFromPhoneAndUpdateKilvishIdinFriend(userId, friendId, friendData)
    } catch (error) {
      console.error("Error in onUserFriendDocumentAdded:", error)
      throw error
    }
  }
)
