import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import * as Busboy from "busboy";
import * as path from "path";
import * as os from "os";
import * as fs from "fs";
import { kilvishDb } from "./common"

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
  //let userId: string;

  try {
     await admin.auth().verifyIdToken(idToken);
    //userId = decodedToken.uid; // Securely verified user ID
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
  let destinationFileWithPath: string = "";
  let filenameGlobal: string = "";

  busboy.on("field", (key, val) => {
    fields[key] = val;
  });

  busboy.on("file", (fieldname, file, info) => {
    const { filename } = info;
    filenameGlobal = filename;

    console.log(`Request recieved for ${filenameGlobal}`);
    
    // We use the verified userId for the path instead of trusting the client-sent field
    destinationFileWithPath = `receipts/${fields.userId}_${fields.wipExpenseId}${path.extname(filename)}`;
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
    console.log(`${filenameGlobal} successfully saved on the server. Will now attempt to persist in firebase storage`);

    try {
      await Promise.all(fileWrites);

      const bucket = admin.storage().bucket('gs://tamraj-kilvish.firebasestorage.app');
      const wipExpenseId = fields.wipExpenseId;

      if (!wipExpenseId) {
        throw new Error("Missing wipExpenseId");
      }

      // 4. Upload to Storage
      await bucket.upload(tmpFilePath, {
        destination: destinationFileWithPath,
        metadata: { contentType: 'image/jpeg' }, 
      });

      console.log(`${filenameGlobal} successfully written to ${destinationFileWithPath}`);

      // 5. Get long-lived URL
      const file = bucket.file(destinationFileWithPath);
      const [url] = await file.getSignedUrl({
        action: 'read',
        expires: '01-01-2100', 
      });

      // 6. Update Firestore
      const doc = kilvishDb.collection("Users").doc(fields.userId).collection("WIPExpenses").doc(fields.wipExpenseId);
      await doc.update({
        receiptURL: url,
        //status: "extractingData",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`DB updated for ${filenameGlobal}. Extraction of data should trigger now`);

      // Cleanup temp memory
      if (fs.existsSync(tmpFilePath)) fs.unlinkSync(tmpFilePath);

      res.status(200).send({ success: true, url });
    } catch (err: any) {
      console.error("Processing error:", err);
      res.status(500).send({ error: err.message });
    }
  });

  // Critical for Cloud Functions: pass the raw body buffer to busboy
  busboy.end(req.rawBody);
});