import { onCall, HttpsError } from "firebase-functions/v2/https"
import * as admin from "firebase-admin"
import { kilvishDb } from "./common"

export { processWIPExpenseReceipt } from "./wipExpense"
export {
  onExpenseCreated,
  onExpenseUpdated,
  onExpenseDeleted,
  onRecipientWritten,
  handleTagSharingOnTagCreate,
  handleTagUpdate,
  joinTag,
  removeTagMember,
  sendExpenseMemberFCMTask,
} from "./main"
export { onUserDeleted } from "./userDelete"
export { uploadReceiptApi } from "./uploadReceipt"

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
      const userQuery = await kilvishDb
        .collection("Users")
        .where("phone", "==", phoneNumber)
        .limit(1)
        .get()

      if (userQuery.empty) {
        console.log(`Creating new user for phone ${phoneNumber}`)
        const authUser = await admin.auth().getUser(uid)
        if (authUser.phoneNumber !== phoneNumber) {
          throw new HttpsError("permission-denied", "You can only create your own user data.")
        }

        const newUserRef = kilvishDb.collection("Users").doc()
        const newUserData = { uid, phone: phoneNumber, accessibleTagIds: [] }
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

      await kilvishDb.collection("Users").doc(userDocId).update({ uid })
      await admin.auth().setCustomUserClaims(uid, { userId: userDocId })

      return { success: true, user: { id: userDocId, ...userData, uid } }
    } catch (error) {
      console.error("Error in getUserByPhone:", error)
      if (error instanceof HttpsError) throw error
      throw new HttpsError("internal", "An internal error occurred.")
    }
  }
)
