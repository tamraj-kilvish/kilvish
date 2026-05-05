import * as admin from "firebase-admin"
import { onDocumentDeleted } from "firebase-functions/v2/firestore"
import { kilvishDb } from "./common"
import { _notifyUserOfTagShared } from "./fcm_notification"

async function _deleteSubcollection(collectionRef: FirebaseFirestore.CollectionReference) {
  const snapshot = await collectionRef.get()
  const batch = kilvishDb.batch()
  snapshot.docs.forEach((doc) => batch.delete(doc.ref))
  if (!snapshot.empty) await batch.commit()
}

async function _stripTagFromUserExpenseDoc(ownerId: string, expenseId: string, tagId: string) {
  try {
    const expRef = kilvishDb.collection("Users").doc(ownerId).collection("Expenses").doc(expenseId)
    const expDoc = await expRef.get()
    if (!expDoc.exists) return

    const tagsJson: string = expDoc.data()?.tags || "[]"
    const tags: Array<{ id: string }> = JSON.parse(tagsJson)
    const filtered = tags.filter((t) => t.id !== tagId)
    if (filtered.length === tags.length) return

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

    if (expOwnerId && expOwnerId !== deletedUserId) {
      await _stripTagFromUserExpenseDoc(expOwnerId, expDoc.id, tagId)
    }

    await expDoc.ref.delete()
    console.log(`Deleted expense ${expDoc.id} from tag "${tagName}"`)
  }

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
  }
)
