import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import * as Busboy from "busboy";
import * as path from "path";
import * as os from "os";
import * as fs from "fs";
import { kilvishDb } from "./common"
import { getDownloadURL } from "firebase-admin/storage";

admin.initializeApp();

export const uploadReceiptApi = functions.https.onRequest({
    region: "asia-south1",
    cors: true,
  },
  async (req, res) => {
  // 1. Only allow POST requests
  if (req.method !== "POST") {
    res.status(405).send("Method Not Allowed");
    return;
  }

  // 2. Authentication Check
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).send("Unauthorized: No token provided");
    return;
  }

  const idToken = authHeader.split("Bearer ")[1];

  try {
     await admin.auth().verifyIdToken(idToken);
  } catch (error) {
    console.error("Token verification failed:", error);
    res.status(401).send("Unauthorized: Invalid token");
    return;
  }

  // 3. Setup Busboy for file parsing
  const busboy = Busboy({ headers: req.headers });
  const tmpdir = os.tmpdir();
  const fields: { [key: string]: string } = {};
  const fileWrites: Promise<void>[] = [];

  let tmpFilePath: string = "";
  let filenameGlobal: string = "";

  busboy.on("field", (key, val) => {
    fields[key] = val;
  });

  busboy.on("file", (fieldname, file, info) => {
    const { filename } = info;
    filenameGlobal = filename;
    console.log(`Request received for ${filenameGlobal}`);

    tmpFilePath = path.join(tmpdir, filenameGlobal);
    const writeStream = fs.createWriteStream(tmpFilePath);
    file.pipe(writeStream);

    const promise = new Promise<void>((resolve, reject) => {
      writeStream.on("finish", resolve);
      writeStream.on("error", reject);
    });
    fileWrites.push(promise);
  });

  busboy.on("finish", async () => {
    console.log(`${filenameGlobal} upload complete. Persisting to Firebase Storage...`);

    try {
      await Promise.all(fileWrites);

      const bucket = admin.storage().bucket('gs://tamraj-kilvish.firebasestorage.app');
      const fileExt = path.extname(filenameGlobal);

      // ── Additional receipt (no OCR) ──────────────────────────────────────────
      if (fields.isAdditionalReceipt === 'true') {
        const { userId, expenseId, collectionType, arrayIndex } = fields;
        if (!userId || !expenseId || !collectionType || arrayIndex === undefined) {
          res.status(400).send({ error: "Missing required fields for additional receipt" });
          return;
        }

        const destination = `receipts/${userId}_${expenseId}_extra_${arrayIndex}${fileExt}`;
        const [uploadedFile] = await bucket.upload(tmpFilePath, {
          destination,
          metadata: { contentType: 'image/jpeg' },
        });
        const downloadUrl = await getDownloadURL(uploadedFile);

        const docRef = kilvishDb.collection('Users').doc(userId).collection(collectionType).doc(expenseId);
        const doc = await docRef.get();

        // Replace local path placeholder with Firebase URL at the same index
        const urls: string[] = ((doc.data()?.otherReceiptUrls ?? []) as string[]);
        urls[parseInt(arrayIndex)] = downloadUrl;

        await docRef.update({ otherReceiptUrls: urls, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
        console.log(`Additional receipt saved: ${destination}`);

        if (fs.existsSync(tmpFilePath)) fs.unlinkSync(tmpFilePath);

        res.status(200).send({ success: true, downloadUrl });
        return;
      }

      // ── Main receipt (new: wipExpenseId path — find-or-create WIPExpense) ──────
      if (fields.wipExpenseId) {
        const { wipExpenseId, userId, collectionType } = fields;
        if (!userId || !collectionType) {
          throw new Error("Missing userId or collectionType for wipExpenseId path");
        }

        const destination = `receipts/${userId}_${wipExpenseId}${fileExt}`;
        const [uploadedFile] = await bucket.upload(tmpFilePath, {
          destination,
          metadata: { contentType: 'image/jpeg' },
        });
        const downloadUrl = await getDownloadURL(uploadedFile);
        console.log(`${filenameGlobal} written to ${destination}`);

        const wipRef = kilvishDb.collection("Users").doc(userId).collection(collectionType).doc(wipExpenseId);
        const snap = await wipRef.get();

        // Two-step write: create first (without receiptUrl), then update with receiptUrl.
        // This is intentional — processWIPExpenseReceipt listens to onDocumentUpdated, which
        // does not fire on document creation. The separate update triggers OCR processing.
        if (!snap.exists) {
          const tagIds = fields.tagId ? [fields.tagId] : [];
          // tagLinks mirrors the structure written by createWIPExpense() on the client:
          // [{ tagId }]. The client reads tagLinks (not tagIds) to hydrate wipExpense.tagLinks,
          // which drives tag attachment when the user saves the expense.
          const tagLinks = fields.tagId ? [{ tagId: fields.tagId }] : [];
          const isLoanPayback = fields.isLoanPayback === 'true';
          const createdAt = fields.createdAt
            ? new Date(parseInt(fields.createdAt))
            : new Date();
          await wipRef.set({
            status: 'waitingToStartProcessing',
            createdAt: admin.firestore.Timestamp.fromDate(createdAt),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            tagIds,
            tagLinks,
            ...(isLoanPayback ? { loanPaybackTagName: '' } : {}),
          });
          console.log(`WIPExpense ${wipExpenseId} created`);
        }

        await wipRef.update({
          receiptUrl: downloadUrl,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`WIPExpense ${wipExpenseId} receiptUrl attached — OCR trigger will fire`);

        if (fs.existsSync(tmpFilePath)) fs.unlinkSync(tmpFilePath);
        res.status(200).send({ success: true, downloadUrl });
        return;
      }

      // ── Main receipt (legacy: expenseId path — update existing doc) ─────────
      const { expenseId, collectionType } = fields;
      if (!expenseId || !collectionType) {
        throw new Error("Missing expenseId or collectionType");
      }

      const destination = `receipts/${fields.userId}_${expenseId}${fileExt}`;
      const [uploadedFile] = await bucket.upload(tmpFilePath, {
        destination,
        metadata: { contentType: 'image/jpeg' },
      });
      const downloadUrl = await getDownloadURL(uploadedFile);

      console.log(`${filenameGlobal} successfully written to ${destination}`);

      const doc = kilvishDb.collection("Users").doc(fields.userId).collection(collectionType).doc(expenseId);
      await doc.update({
        receiptUrl: downloadUrl,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`DB updated for ${filenameGlobal}. Extraction of data should trigger now`);

      if (fs.existsSync(tmpFilePath)) fs.unlinkSync(tmpFilePath);
      res.status(200).send({ success: true, downloadUrl });
    } catch (err: any) {
      console.error("Processing error:", err);
      res.status(500).send({ error: err.message });
    }
  });

  // Critical for Cloud Functions: pass the raw body buffer to busboy
  busboy.end(req.rawBody);
});
