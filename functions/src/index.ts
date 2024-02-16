import * as functions from "firebase-functions"
import * as admin from "firebase-admin"
import { getAuth } from "firebase-admin/auth"

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
    const additionalInfo = {
      email: snapshot.val()["email"],
      phone: snapshot.val()["phone"],
    };
    if (snapshot.val()["verifyPhone"] && snapshot.val()["verifyEmail"]) {
      if (phoneOtp == "0000" && emailOtp == "0000") {
        const customToken = await getAuth().createCustomToken(kilvishId, additionalInfo);
        response.status(200).send({ "data": { "success": true, "token": customToken } })
      }
    } else {
      if (phoneOtp == "1234" && emailOtp == "5678") {
        const customToken = await getAuth().createCustomToken(kilvishId, additionalInfo);
        const usersRef = db.ref("users");
        const userInfo = { [kilvishId]: { "kilvishId": kilvishId, "email": snapshot.val()["email"], "phone": snapshot.val()["phone"], "verifyPhone": true, "verifyEmail": true } };
        await usersRef.update(userInfo)
        response.status(200).send({ "data": { "success": true, "token": customToken } })
      }
    }
  }
  response.status(400).send({ "data": { "success": false, "message": "User Not Found" } })
})

export const verifyUser = functions.https.onRequest(async (request, response) => {
  const reqBody = JSON.stringify(request.body);
  const data = JSON.parse(reqBody)['data'];

  const kilvishId = data["kilvishId"];
  const email = data["email"];
  const phone = data["phone"];

  const userInfo = { [kilvishId]: { "kilvishId": kilvishId, "email": email, "phone": phone } };
  const snapshot = await db.ref(`users/${kilvishId}`).get()
  if (snapshot != null && snapshot.val()) {
    if (snapshot.val()["email"] == email && snapshot.val()["phone"] == phone) {
      /// Logic for send OTP
      response.status(200).send({ "data": { "success": true } })
    } else {
      response.status(404).send({ "data": { "success": false, "message": "Wrong email phone number please enter correct correct" } })
    }
  } else {
    const usersRef = db.ref("users");
    await usersRef.update(userInfo)
    /// Logic for send OTP
    response.status(201).send({ 'data': { "success": true, "userInfo": { "kilvishId": kilvishId, "email": email, "phone": phone } } })
  }
})
