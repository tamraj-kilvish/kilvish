import * as admin from "firebase-admin"

// Initialize once
admin.initializeApp()
admin.firestore().settings({ databaseId: "kilvish" })

// Export shared instance
export const kilvishDb = admin.firestore()