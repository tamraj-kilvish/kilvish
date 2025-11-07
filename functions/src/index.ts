import { onCall, HttpsError } from "firebase-functions/v2/https"
import {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
  FirestoreEvent,
} from "firebase-functions/v2/firestore"
import * as admin from "firebase-admin"
import { FieldValue } from "firebase-admin/firestore"

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
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          lastLogin: admin.firestore.FieldValue.serverTimestamp(),
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
        lastLogin: admin.firestore.FieldValue.serverTimestamp(),
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

/**
 * Helper: Get FCM tokens for tag users (excluding a specific user)
 */
async function getTagUserTokens(tagId: string, excludeUserId?: string): Promise<string[]> {
  const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
  if (!tagDoc.exists) return []

  const tagData = tagDoc.data()
  if (!tagData) return []

  const userIds = ((tagData.sharedWith as string[]) || []).filter((id) => id && id.trim())
  userIds.push(tagData.ownerId)

  if (userIds.length === 0) return []

  const usersSnapshot = await kilvishDb.collection("Users").where("__name__", "in", userIds).get()

  const tokens: string[] = []
  usersSnapshot.forEach((doc) => {
    const userData = doc.data()
    if (doc.id !== excludeUserId && userData.fcmToken) {
      tokens.push(userData.fcmToken)
    }
  })

  return tokens
}

async function handleExpenseModify(event: FirestoreEvent<any>, eventType: string) {
  try {
    const { tagId, expenseId } = event.params
    const expenseData =
      eventType === "expense_updated"
        ? event.data?.after.data() // For updates, get 'after' data
        : event.data?.data() // For create/delete, use regular data

    if (!expenseData) return

    const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()
    if (!tagDoc.exists) return
    const tagData = tagDoc.data()
    if (!tagData) return

    const fcmTokens = await getTagUserTokens(tagId, expenseData.ownerId)
    if (fcmTokens.length === 0) return

    let message: any = {
      data: {
        type: eventType,
        tagId,
        expenseId,
        tagName: tagData.name || "Unknown",
      },
      notification: {
        title: tagData.name,
        body: `${eventType} - ₹${expenseData.amount || 0} to ${expenseData.to || "unknown"}`,
      },
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
    await handleExpenseModify(event, "expense_created")
  }
)

/**
 * Notify when expense is UPDATED
 */
export const onExpenseUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    await handleExpenseModify(event, "expense_updated")
  }
)

/**
 * Notify when expense is DELETED
 */
export const onExpenseDeleted = onDocumentDeleted(
  { document: "Tags/{tagId}/Expenses/{expenseId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    await handleExpenseModify(event, "expense_deleted")
  }
)

async function createUserAndUpdateSharedWith(userId: string, tagId: string, updatedSharedWith: Array<string>) {
  console.log(`User ${userId} not found, attempting to create from phone number`)

  if (userId.length == 10) {
    userId = "+91" + userId
  }
  // Check if userId is actually a phone number format
  if (userId.startsWith("+")) {
    try {
      // Create a new user document for this phone number
      const newUserData = {
        phone: userId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        accessibleTagIds: [tagId],
        unseenExpenseIds: [],
      }

      const newUserRef = kilvishDb.collection("Users").doc()
      await newUserRef.set(newUserData)

      console.log(`Created new user document ${newUserRef.id} for phone ${userId}`)

      // Update the tag's sharedWith to use the new user ID instead of phone
      updatedSharedWith = updatedSharedWith.map((id) => (id === userId ? newUserRef.id : id))
      console.log(`updatedSharedWith ${updatedSharedWith}`)

      return newUserRef.id

      //   await kilvishDb.collection("Tags").doc(tagId).update({
      //     sharedWith: updatedSharedWith,
      //   })
      // console.log(`Updated tag ${tagId} sharedWith to use user ID ${newUserRef.id}`)
    } catch (createError) {
      console.error(`Failed to create user for phone ${userId}:`, createError)
      return null
    }
  } else {
    console.warn(`User ${userId} not found and not a phone number format`)
    return null
  }
}

/**
 * Handle TAG updates - notify users when added/removed from sharedWith
 */
export const onTagUpdated = onDocumentUpdated(
  { document: "Tags/{tagId}", region: "asia-south1", database: "kilvish" },
  async (event) => {
    try {
      const tagId = event.params.tagId
      const beforeData = event.data?.before.data()
      const afterData = event.data?.after.data()

      if (!beforeData || !afterData) return

      if (beforeData.doNotProcess != null || afterData.doNotProcess != null) {
        if (afterData.doNotProcess != null) {
          console.log(`afterData has doNotProcess, skipping`)
          await kilvishDb.collection("Tags").doc(tagId).update({
            doNotProcess: FieldValue.delete(),
          })
        } else {
          console.log(`beforeData has doNotProcess .. skipping`)
        }
        return
      }

      const beforeSharedWith = (beforeData.sharedWith as string[]) || []
      const afterSharedWith = (afterData.sharedWith as string[]) || []

      // Find newly added users
      const addedUsers = afterSharedWith.filter(
        (userId) => !beforeSharedWith.includes(userId) && userId && userId.trim()
      )

      // Find removed users
      const removedUsers = beforeSharedWith.filter(
        (userId) => !afterSharedWith.includes(userId) && userId && userId.trim()
      )

      const tagName = afterData.name || "Unknown"

      // use this variable to update the Tag sharedWith at the end
      const updatedSharedWith: string[] = [...afterSharedWith]
      let isSharedWithUpdated: boolean = false

      // Notify newly added users
      if (addedUsers.length > 0) {
        console.log(`Users added to tag ${tagId}:`, addedUsers)

        for (const userId of addedUsers) {
          let userDoc = await kilvishDb.collection("Users").doc(userId).get()

          // If user doesn't exist, this might be a phone number - try to create user
          if (!userDoc.exists) {
            const newUserId = await createUserAndUpdateSharedWith(userId, tagId, updatedSharedWith)
            if (newUserId != null) {
              userDoc = await kilvishDb.collection("Users").doc(newUserId).get()
              isSharedWithUpdated = true
            }
          }

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
      if (removedUsers.length > 0) {
        console.log(`Users removed from tag ${tagId}:`, removedUsers)

        for (const userId of removedUsers) {
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

      if (isSharedWithUpdated) {
        await kilvishDb.collection("Tags").doc(tagId).update({
          sharedWith: updatedSharedWith,
          doNotProcess: true,
        })
        console.log(`Updated tag ${tagId} sharedWith to ${updatedSharedWith}`)
      }

      return { success: true, addedUsers: addedUsers.length, removedUsers: removedUsers.length }
    } catch (error) {
      console.error("Error in onTagUpdated:", error)
      throw error
    }
  }
)
