import * as functions from "firebase-functions"
import * as admin from "firebase-admin"

// Initialize Firebase Admin
admin.initializeApp()

admin.firestore().settings({
  databaseId: "kilvish",
})

// Get Firestore instance with specific database 'kilvish'
const kilvishDb = admin.firestore()
// Using the named database 'kilvish' with Firebase Admin SDK v12 syntax
// Using the named database 'kilvish' with Firebase Admin SDK v12 syntax
// or use environment configuration to specify the database

export const getUserByPhone = functions.https.onCall(async (data, context) => {
  // Verify user is authenticated
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "User must be authenticated to call this function.")
  }

  const { phoneNumber } = data
  const uid = context.auth.uid

  // Validate input
  if (!phoneNumber) {
    throw new functions.https.HttpsError("invalid-argument", "Phone number is required.")
  }

  try {
    // Query User collection by phone number
    const userQuery = await kilvishDb.collection("User").where("phone", "==", phoneNumber).limit(1).get()

    if (userQuery.empty) {
      throw new functions.https.HttpsError("not-found", "No user found with this phone number.")
    }

    const userDoc = userQuery.docs[0]
    const userData = userDoc.data()
    const userDocId = userDoc.id

    // Security check: Only allow access if phone matches authenticated user's phone
    // This ensures user can only access their own data
    const authUser = await admin.auth().getUser(uid)
    if (authUser.phoneNumber !== phoneNumber) {
      throw new functions.https.HttpsError("permission-denied", "You can only access your own user data.")
    }

    // Update the user document with the UID
    await kilvishDb.collection("User").doc(userDocId).update({
      uid: uid,
      lastLogin: admin.firestore.FieldValue.serverTimestamp(),
    })

    // Return user data with document ID
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

    if (error instanceof functions.https.HttpsError) {
      throw error
    }

    throw new functions.https.HttpsError("internal", "An internal error occurred while processing your request.")
  }
})
