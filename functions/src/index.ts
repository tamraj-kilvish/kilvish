import { onCall, HttpsError } from "firebase-functions/v2/https"
//import {onDocumentCreated} from "firebase-functions/v2/firestore";
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
          isNewUser: true,
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
        isNewUser: false,
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

// // Firestore trigger to set custom claims when a new User is created
// export const setUserCustomClaims = onDocumentCreated(
//   {
//     document: "Users/{userId}",
//     database: "kilvish",
//     region: "asia-south1",
//   },
//   async (event) => {
//     const userId = event.params.userId;
//     const userData = event.data?.data();

//     if (!userData) {
//       console.error("No user data found");
//       return;
//     }

//     const authUid = userData.uid;

//     if (!authUid) {
//       console.error("No auth UID found in user document");
//       return;
//     }

//     try {
//       // Set custom claim with the User document ID
//       await admin.auth().setCustomUserClaims(authUid, {
//         userId: userId,
//       });

//       console.log(
//         `Custom claims set for auth UID ${authUid} with userId ${userId}`
//       );

//       // Mark that claims are set
//       await event.data?.ref.update({
//         customClaimsSet: true,
//         customClaimsSetAt: admin.firestore.FieldValue.serverTimestamp(),
//       });
//     } catch (error) {
//       console.error("Error setting custom claims:", error);
//     }
//   }
// );
