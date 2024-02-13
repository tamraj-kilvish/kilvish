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
    kilvishId1: {
      kilvishId: "kilvishId1",
      name: "Radhey",
      email: "radheyit@gmail.com",
      phone: "8983026208",
    },
    kilvishId2: {
      kilvishId: "KilvishId2",
      name: "dummy Name",
      email: "adminji@yopmail.com",
      phone: "8208567820",
    },
  })
  console.log(request.params);
  const snapshot = await db.ref("users/kilvishId1").get()
  response.send(snapshot.val())
})

export const verifyOtp = functions.https.onRequest(async (request, response) => {
  const reqBody = JSON.stringify(request.body);
  const data = JSON.parse(reqBody)['data'];

  const kilvishId = data["kilvishId"];
  const phoneOtp = data["phoneOtp"];
  const emailOtp = data["emailOtp"];

  const snapshot = await db.ref(`users/${kilvishId}`).get()
  if (snapshot != null && snapshot.val()) {
    if (snapshot.val()["verifyPhone"] == false && snapshot.val()["verifyEmail"] == false) {
      if (phoneOtp == "1234" && emailOtp == "5678") {
        response.send({ "data": { "success": true } })
      }
    } else {
      if (phoneOtp == "0000" && emailOtp == "0000") {
        response.send({ "data": { "success": true } })
      }
    }
  }
  response.send({ 'data': { "success": false } })
})


export const login = functions.https.onRequest(async (request, response) => {
  const reqBody = JSON.stringify(request.body);
  const data = JSON.parse(reqBody)['data'];

  const kilvishId = data["kilvishId"];
  const email = data["email"];
  const phone = data["phone"];

  const userInfo = { kilvishId: { "kilvishId": kilvishId, "email": email, "phone": phone, "verifyPhone": false, "verifyEmail": false } };

  const snapshot = await db.ref(`users/${kilvishId}`).get()
  if (snapshot != null && snapshot.val()) {
    if (snapshot.val()["email"] == email && snapshot.val()["phone"] == phone) {
      /// Logic for send OTP
      response.send({ "data": { "success": true } })
    } else {
      response.send({ "data": { "success": false, "message": "Wrong email phone number please enter correct correct" } })
    }
  } else {
    const usersRef = db.ref("users");
    await usersRef.update(userInfo)
    /// Logic for send OTP
    response.send({ 'data': { "success": true, "userInfo": { "kilvishId": kilvishId, "email": email, "phone": phone } } })
  }
})
