import * as functions from "firebase-functions"
import * as admin from "firebase-admin"

const app = admin.initializeApp({
  databaseURL: "https://kilvish-aa125-default-rtdb.asia-southeast1.firebasedatabase.app/",
})
const db = admin.database(app)

// Start writing Firebase Functions
// https://firebase.google.com/docs/functions/typescript

export const helloWorld = functions.https.onRequest(async (request, response) => {
  const usersRef = db.ref("users")
  await usersRef.update({
    alanisawesome: {
      nickname: "Alan The Machine",
    },
    gracehop: {
      nickname: "Amazing Grace",
    },
  })
  const snapshot = await db.ref("users/alanisawesome").get()
  response.send(snapshot.val())
})
