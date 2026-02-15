/**
 * Migration Script: Convert Tag Monetary Summary from Old to New Schema
 * 
 * OLD SCHEMA:
 * - totalAmountTillDate: number
 * - userWiseTotalTillDate: { [userId]: number }
 * - monthWiseTotal: { [year]: { [month]: { total: number, [userId]: number } } }
 * 
 * NEW SCHEMA:
 * - total: { acrossUsers: { expense: number, recovery: number }, [userId]: { expense: number, recovery: number } }
 * - monthWiseTotal: { "YYYY-MM": { acrossUsers: { expense: number, recovery: number }, [userId]: { expense: number, recovery: number } } }
 */

import * as admin from "firebase-admin"

// Initialize Firebase Admin with your service account
admin.initializeApp({
  credential: admin.credential.cert(require("../serviceAccountKey.json")),
})

admin.firestore().settings({ databaseId: "kilvish" })
const kilvishDb = admin.firestore()

interface OldMonthData {
  total?: number
  [userId: string]: number | undefined
}

interface OldTagData {
  totalAmountTillDate?: number
  userWiseTotalTillDate?: { [userId: string]: number }
  monthWiseTotal?: { [year: string]: { [month: string]: OldMonthData } }
}

interface UserMonetaryData {
  expense: number
  recovery: number
}

interface MonthlyMonetaryData {
  acrossUsers: UserMonetaryData
  [userId: string]: UserMonetaryData
}

async function migrateTagMonetarySummary() {
  console.log("Starting migration of Tag monetary summary...")

  try {
    const tagsSnapshot = await kilvishDb.collection("Tags").get()
    console.log(`Found ${tagsSnapshot.size} tags to migrate`)

    let migratedCount = 0
    let skippedCount = 0
    let errorCount = 0

    const batch = kilvishDb.batch()
    let batchCount = 0
    const BATCH_SIZE = 500

    for (const tagDoc of tagsSnapshot.docs) {
      try {
        const tagId = tagDoc.id
        if(tagId != "sgxbIcIR8FgcS1mbACws") continue; 

        const oldData = tagDoc.data() as OldTagData

        // Check if already migrated (has new schema)
        if (oldData.hasOwnProperty('total') ) {
          console.log(`Tag ${tagId} already migrated, skipping...`)
          skippedCount++
          continue
        }

        // Build new total structure
        const newTotal: MonthlyMonetaryData = {
          acrossUsers: { expense: 0, recovery: 0 }
        }

        // Migrate userWiseTotalTillDate to total
        const userWiseTotalTillDate = oldData.userWiseTotalTillDate || {}
        let totalExpense = 0

        for (const [userId, amount] of Object.entries(userWiseTotalTillDate)) {
          if (typeof amount === 'number') {
            newTotal[userId] = { expense: amount, recovery: 0 }
            totalExpense += amount
          }
        }

        newTotal.acrossUsers.expense = totalExpense

        // Build new monthWiseTotal structure
        const newMonthWiseTotal: { [monthKey: string]: MonthlyMonetaryData } = {}
        const oldMonthWiseTotal = oldData.monthWiseTotal || {}

        for (const [year, monthsData] of Object.entries(oldMonthWiseTotal)) {
          for (const [month, monthData] of Object.entries(monthsData)) {
            const monthKey = `${year}-${month.padStart(2, '0')}`
            
            const monthlyData: MonthlyMonetaryData = {
              acrossUsers: { expense: 0, recovery: 0 }
            }

            let monthTotal = 0
            for (const [key, value] of Object.entries(monthData)) {
              if (key === 'total') {
                monthTotal = value as number
              } else if (typeof value === 'number') {
                monthlyData[key] = { expense: value, recovery: 0 }
              }
            }

            monthlyData.acrossUsers.expense = monthTotal
            newMonthWiseTotal[monthKey] = monthlyData
          }
        }

        // Update tag with new schema
        const updateData: any = {
          total: newTotal,
          monthWiseTotal: newMonthWiseTotal,
        }

        // Delete old fields
        updateData.totalAmountTillDate = admin.firestore.FieldValue.delete()
        updateData.userWiseTotalTillDate = admin.firestore.FieldValue.delete()

        batch.update(tagDoc.ref, updateData)
        batchCount++
        migratedCount++

        // Commit batch if it reaches the limit
        if (batchCount >= BATCH_SIZE) {
          await batch.commit()
          console.log(`Committed batch of ${batchCount} tags`)
          batchCount = 0
        }

      } catch (error) {
        console.error(`Error migrating tag ${tagDoc.id}:`, error)
        errorCount++
      }
    }

    // Commit remaining tags
    if (batchCount > 0) {
      await batch.commit()
      console.log(`Committed final batch of ${batchCount} tags`)
    }

    console.log("\n=== Migration Summary ===")
    console.log(`Total tags: ${tagsSnapshot.size}`)
    console.log(`Migrated: ${migratedCount}`)
    console.log(`Skipped (already migrated): ${skippedCount}`)
    console.log(`Errors: ${errorCount}`)
    console.log("Migration completed successfully!")

  } catch (error) {
    console.error("Fatal error during migration:", error)
    throw error
  }
}

// Run migration
migrateTagMonetarySummary()
  .then(() => {
    console.log("Migration script finished")
    process.exit(0)
  })
  .catch((error) => {
    console.error("Migration script failed:", error)
    process.exit(1)
  })