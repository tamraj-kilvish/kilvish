import { onCall, HttpsError } from "firebase-functions/v2/https"
import { onDocumentCreated } from "firebase-functions/v2/firestore"
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
    invoker: "public", // Allow public invocation but still check auth inside the function
    cors: true,
  },
  async (request) => {
    // Verify user is authenticated
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "User must be authenticated to call this function.")
    }

    const { phoneNumber } = request.data
    const uid = request.auth.uid

    // Validate input
    if (!phoneNumber) {
      throw new HttpsError("invalid-argument", "Phone number is required.")
    }

    try {
      // Query Users collection by phone number
      const userQuery = await kilvishDb.collection("Users").where("phone", "==", phoneNumber).limit(1).get()

      // If user doesn't exist, create new user document
      if (userQuery.empty) {
        console.log(`Creating new user for phone ${phoneNumber}`)

        // Security check: Only allow if phone matches authenticated user's phone
        const authUser = await admin.auth().getUser(uid)
        if (authUser.phoneNumber !== phoneNumber) {
          throw new HttpsError("permission-denied", "You can only create your own user data.")
        }

        // Create new user document
        const newUserRef = kilvishDb.collection("Users").doc()
        const newUserData = {
          uid: uid,
          phone: phoneNumber,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          lastLogin: admin.firestore.FieldValue.serverTimestamp(),
        }

        await newUserRef.set(newUserData)

        // Set custom claims for new user
        await admin.auth().setCustomUserClaims(uid, {
          userId: newUserRef.id,
        })

        console.log(`New user created with ID ${newUserRef.id} and custom claims set`)

        return {
          success: true,
          user: {
            id: newUserRef.id,
            ...newUserData,
          },
        }
      }

      // Existing user found
      const userDoc = userQuery.docs[0]
      const userData = userDoc.data()
      const userDocId = userDoc.id

      // Security check: Only allow access if phone matches authenticated user's phone
      const authUser = await admin.auth().getUser(uid)
      if (authUser.phoneNumber !== phoneNumber) {
        throw new HttpsError("permission-denied", "You can only access your own user data.")
      }

      // Update the user document with the UID and add to authUids if not present
      const updateData: any = {
        lastLogin: admin.firestore.FieldValue.serverTimestamp(),
      }

      // Always update uid to current auth uid
      updateData.uid = uid

      await kilvishDb.collection("Users").doc(userDocId).update(updateData)

      // Set custom claims
      await admin.auth().setCustomUserClaims(uid, {
        userId: userDocId,
      })

      console.log(`Custom claims set for user ${uid} with userId ${userDocId}`)

      return {
        success: true,
        user: {
          id: userDocId,
          ...userData,
          uid: uid,
        },
      }
    } catch (error) {
      console.error("Error in getUserByPhone:", error)

      if (error instanceof HttpsError) {
        throw error
      }

      throw new HttpsError("internal", "An internal error occurred while processing your request.")
    }
  }
)

/**
 * Send FCM notifications when a new expense is created in a tag
 * Only notifies users who didn't create the expense
 */
export const onExpenseCreated = onDocumentCreated(
  {
    document: "Tags/{tagId}/Expenses/{expenseId}",
    region: "asia-south1",
    database: "kilvish",
  },
  async (event) => {
    try {
      const tagId = event.params.tagId
      const expenseId = event.params.expenseId
      const expenseData = event.data?.data()

      if (!expenseData) {
        console.log("No expense data found")
        return
      }

      console.log(`New expense created: ${expenseId} in tag: ${tagId}`)

      // Get the tag document to find tag name and verify it exists
      const tagDoc = await kilvishDb.collection("Tags").doc(tagId).get()

      if (!tagDoc.exists) {
        console.log("Tag not found")
        return
      }

      const tagData = tagDoc.data()
      if (tagData == undefined) {
        console.log("tagData is undefined")
        return
      }

      const userIds = ((tagData.sharedWith as Array<string>) || []).filter((id) => id && id.trim().length > 0) // Remove empty strings
      userIds.push(tagData.ownerId)
      console.log(userIds)

      const expenseCreatorId = expenseData.ownerId as string | undefined

      // Get all users who have access to this tag (excluding the creator)

      const usersSnapshot = await kilvishDb.collection("Users").where("__name__", "in", userIds).get()

      if (usersSnapshot.empty) {
        console.log("No users with access to this tag")
        return
      }

      // Collect FCM tokens for users who didn't create this expense
      const fcmTokens: string[] = []
      usersSnapshot.forEach((doc) => {
        console.log(`Collecting fcm token for userId ${doc.id}`)

        const userData = doc.data()
        // Only notify users who didn't create this expense
        if (doc.id !== expenseCreatorId && userData.fcmToken) {
          fcmTokens.push(userData.fcmToken as string)
        }
      })

      if (fcmTokens.length === 0) {
        console.log("No FCM tokens found for notification")
        return
      }

      // Prepare expense data for FCM payload
      const expensePayload = {
        id: expenseId,
        txId: expenseData.txId || "",
        ownerId: expenseData.ownerId || "",
        to: expenseData.to || "",
        amount: (expenseData.amount || 0).toString(),
        timeOfTransaction: expenseData.timeOfTransaction?.toDate
          ? expenseData.timeOfTransaction.toDate().toISOString()
          : new Date().toISOString(),
        updatedAt: expenseData.updatedAt?.toDate
          ? expenseData.updatedAt.toDate().toISOString()
          : new Date().toISOString(),
        notes: expenseData.notes || null,
        receiptUrl: expenseData.receiptUrl || null,
      }

      // Prepare FCM message
      const message = {
        data: {
          type: "new_expense",
          tagId: tagId,
          expenseId: expenseId,
          tagName: tagData?.name || "Unknown",
          expense: JSON.stringify(expensePayload),
        },
        notification: {
          title: `New expense in ${tagData?.name || "tag"}`,
          body: `₹${expenseData.amount || 0} to ${expenseData.to || "unknown"}`,
        },
      }

      // Send FCM to all relevant users
      const messaging = admin.messaging()
      const response = await messaging.sendEachForMulticast({
        tokens: fcmTokens,
        ...message,
      })

      console.log(`FCM sent: ${response.successCount} succeeded, ${response.failureCount} failed`)

      // Clean up invalid tokens
      if (response.failureCount > 0) {
        const tokensToRemove: string[] = []
        response.responses.forEach((resp, idx) => {
          if (
            !resp.success &&
            (resp.error?.code === "messaging/invalid-registration-token" ||
              resp.error?.code === "messaging/registration-token-not-registered")
          ) {
            tokensToRemove.push(fcmTokens[idx])
          }
        })

        // Remove invalid tokens from user documents
        if (tokensToRemove.length > 0) {
          console.log(`Removing ${tokensToRemove.length} invalid tokens`)
          const batch = kilvishDb.batch()

          //for (const token of tokensToRemove) {
          const userSnapshot = await kilvishDb.collection("Users").where("fcmToken", "in", tokensToRemove).get()

          userSnapshot.forEach((doc) => {
            batch.update(doc.ref, { fcmToken: admin.firestore.FieldValue.delete() })
          })
          //}

          await batch.commit()
        }
      }

      return { success: true, notificationsSent: response.successCount }
    } catch (error) {
      console.error("Error sending FCM notification:", error)
      throw error
    }
  }
)
