import * as admin from "firebase-admin"
import { inspect } from "util"

// Initialize Firebase Admin with your service account
admin.initializeApp({
  credential: admin.credential.cert(require("../serviceAccountKey.json")),
})

admin.firestore().settings({ databaseId: "kilvish" })
const kilvishDb = admin.firestore()

async function registerFriendAsKilvishUserAndReturnKilvishUserId(
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

async function populateSharedWithOfTagsFromSharedWithFriends() {
    console.log("Starting migration...")

    try {
      console.log("Starting migration of sharedWithFriends to sharedWith")

      const tagsSnapshot = await kilvishDb.collection("Tags").get()
      let processedCount = 0
      let updatedCount = 0

      for (const tagDoc of tagsSnapshot.docs) {
        const tagData = tagDoc.data()
        const tagId = tagDoc.id
        const sharedWithFriends = (tagData.sharedWithFriends as string[]) || []
        const sharedWith = (tagData.sharedWith as string[]) || []

        // Skip if no sharedWithFriends or already has sharedWith populated
        if (sharedWithFriends.length === 0) {
          continue
        }

        console.log(`Processing tag ${tagId}: ${sharedWithFriends.length} friends, ${sharedWith.length} users`)

        const userIds: string[] = [...sharedWith] // Keep existing
        for (const friendId of sharedWithFriends) {
          const userId = await registerFriendAsKilvishUserAndReturnKilvishUserId(tagData.ownerId, friendId)
          if (userId && !userIds.includes(userId)) {
            userIds.push(userId)
          }
        }

        // Update if there are new userIds
        if (userIds.length > sharedWith.length) {
          await kilvishDb.collection("Tags").doc(tagId).update({
            sharedWith: userIds
          })
          console.log(`Updated tag ${tagId}: ${inspect(userIds)} in sharedWith array`)

          for (const userId of userIds) {
            await kilvishDb
            .collection("Users")
            .doc(userId)
            .update({
              accessibleTagIds:
                admin.firestore.FieldValue.arrayUnion(tagId)
            })
            console.log(`Updated ${userId} doc accessibleTagIds, added tagId - ${tagId}`)
          }

          updatedCount++
        }

        processedCount++
      }

      const result = {
        success: true,
        processedTags: processedCount,
        updatedTags: updatedCount
      }

      console.log("Migration complete:", result)
    } catch (error) {
      console.error("Migration error:", error)
    }
  
}

// Run the migration
populateSharedWithOfTagsFromSharedWithFriends()
  .then(() => {
    console.log("Done!")
    process.exit(0)
  })
  .catch((error) => {
    console.error("Migration failed:", error)
    process.exit(1)
  })