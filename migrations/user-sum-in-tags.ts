import * as admin from "firebase-admin"
import { inspect } from "util"

// Initialize Firebase Admin with your service account
admin.initializeApp({
  credential: admin.credential.cert(require("../serviceAccountKey.json")),
})

admin.firestore().settings({ databaseId: "kilvish" })
const kilvishDb = admin.firestore()

// interface UserMonthlyTotal {
//   [userId: string]: number
// }

interface MonthDataKeyValue {
  [key: string]: number
}

interface MonthData {
  [month: number]:  MonthDataKeyValue
}

interface YearData {
  [year: number]: MonthData
}

async function migrateTagData() {
  console.log("Starting migration...")

  try {
    // Get all tags
    const tagsSnapshot = await kilvishDb.collection("Tags").get()
    console.log(`Found ${tagsSnapshot.size} tags to migrate`)

    for (const tagDoc of tagsSnapshot.docs) {
      const tagId = tagDoc.id
      const tagData = tagDoc.data()

      if (tagData.ownerId != "7TdNPvIAQ4pKw1rUUmoK" || tagId == "O3Zr9mcvZLyp1bOhmBCJ" || tagId == "kjM85gXHnxnnWIp4dLE4") continue
      
      console.log(`\nProcessing tag: ${tagId} - ${tagData.name}`)

      // Get all expenses for this tag
      const expensesSnapshot = await kilvishDb
        .collection("Tags")
        .doc(tagId)
        .collection("Expenses")
        .get()

      if (expensesSnapshot.empty) {
        console.log(`  No expenses found for tag ${tagId}`)
        continue
      }

      console.log(`  Found ${expensesSnapshot.size} expenses`)

      // Calculate totals
      const monthWiseTotal: YearData = {}
      let totalAmountTillDate = 0
      const userWiseTotal: MonthDataKeyValue = {}

      for (const expenseDoc of expensesSnapshot.docs) {
        const expense = expenseDoc.data()
        const amount = Math.round(expense.amount) || 0
        const ownerId = expense.ownerId
        const timestamp = expense.timeOfTransaction as admin.firestore.Timestamp

        if (!timestamp) {
          console.log(`  Skipping expense ${expenseDoc.id} - no timestamp`)
          continue
        }

        const date = timestamp.toDate()
        const year = date.getFullYear()
        const month = date.getMonth() + 1

        // Initialize year if needed
        if (!monthWiseTotal[year]) {
          monthWiseTotal[year] = {}
        }

        // Initialize month total if needed
        if (!monthWiseTotal[year][month]) {
          monthWiseTotal[year][month] = {total: 0}
        }

        // Add to month total
        monthWiseTotal[year][month].total += amount

        // Initialize users object for this year if needed
        if (!monthWiseTotal[year][month]) {
          monthWiseTotal[year][month] = {}
        }

        // Initialize user total for this month if needed
        if (!monthWiseTotal[year][month][ownerId]) {
          monthWiseTotal[year][month][ownerId] = 0
        }

        // Add to user's month total
        monthWiseTotal[year][month][ownerId] += amount

     
        // Add to overall total
        totalAmountTillDate += amount
        
        if (!userWiseTotal[ownerId]) {
          userWiseTotal[ownerId] = 0;
        }
        userWiseTotal[ownerId] += amount

      }

      // Update the tag document
      const updateData: any = {
        monthWiseTotal: monthWiseTotal,
        totalAmountTillDate: totalAmountTillDate,
        userWiseTotalTillDate: userWiseTotal,
      }

      await kilvishDb.collection("Tags").doc(tagId).update(updateData)

      console.log(`  ✓ Updated tag ${tagId} ${tagData['name']}`)
      console.log(`    Total: ${totalAmountTillDate}`)
      console.log(`    UserWise Total: `, inspect(userWiseTotal))
      console.log(`    MonthWiseTotal:`, inspect(monthWiseTotal,  { depth: null }))
    }

    console.log("\n✓ Migration completed successfully!")
  } catch (error) {
    console.error("Error during migration:", error)
    throw error
  }
}

// Run the migration
migrateTagData()
  .then(() => {
    console.log("Done!")
    process.exit(0)
  })
  .catch((error) => {
    console.error("Migration failed:", error)
    process.exit(1)
  })