import * as admin from "firebase-admin"
import { inspect } from "util"

// Initialize Firebase Admin with your service account
admin.initializeApp({
  credential: admin.credential.cert(require("../serviceAccountKey.json")),
})

admin.firestore().settings({ databaseId: "kilvish" })
const kilvishDb = admin.firestore()

async function migrateTagSchema() {
  console.log("Starting Tag schema migration...")

  try {
    const tagsSnapshot = await kilvishDb.collection("Tags").get()
    let processedCount = 0
    let updatedCount = 0
    let skippedCount = 0

    for (const tagDoc of tagsSnapshot.docs) {
      const tagData = tagDoc.data()
      const tagId = tagDoc.id

      const updates: Record<string, any> = {}
      let needsUpdate = false

      console.log(`\n=== Processing Tag: ${tagId} (${tagData.name}) ===`)

      // 1. Add new fields if missing
      if (tagData.allowRecovery === undefined) {
        updates.allowRecovery = false
        updates.isRecovery = false
        needsUpdate = true
        console.log(`  Adding allowRecovery and isRecovery fields`)
      }

      // 2. Migrate totalAmountTillDate -> totalTillDate
      if (tagData.totalAmountTillDate !== undefined && typeof tagData.totalAmountTillDate === "number") {
        updates.totalTillDate = {
          expense: tagData.totalAmountTillDate,
          recovery: 0,
        }
        needsUpdate = true
        console.log(`  Migrating totalAmountTillDate (${tagData.totalAmountTillDate}) -> totalTillDate`)
      } else if (!tagData.totalTillDate) {
        // No old or new field, initialize
        updates.totalTillDate = {
          expense: 0,
          recovery: 0,
        }
        needsUpdate = true
        console.log(`  Initializing totalTillDate`)
      }

      // 3. Migrate userWiseTotal structure
      if (tagData.userWiseTotal && Object.keys(tagData.userWiseTotal).length > 0) {
        const firstUserValue = Object.values(tagData.userWiseTotal)[0]

        // Check if old structure (direct number values)
        if (typeof firstUserValue === "number") {
          const newUserWiseTotal: Record<string, { expense: number; recovery: number }> = {}

          for (const [userId, amount] of Object.entries(tagData.userWiseTotal)) {
            newUserWiseTotal[userId] = {
              expense: amount as number,
              recovery: 0,
            }
          }

          updates.userWiseTotal = newUserWiseTotal
          needsUpdate = true
          console.log(`  Migrating userWiseTotal structure (${Object.keys(newUserWiseTotal).length} users)`)
        }
      } else if (!tagData.userWiseTotal) {
        // Initialize if missing
        updates.userWiseTotal = {}
        needsUpdate = true
        console.log(`  Initializing userWiseTotal`)
      }

      // 4. Migrate monthWiseTotal structure (nested year->month to flat YYYY-MM)
      if (tagData.monthWiseTotal && Object.keys(tagData.monthWiseTotal).length > 0) {
        const firstKey = Object.keys(tagData.monthWiseTotal)[0]
        const firstValue = tagData.monthWiseTotal[firstKey]

        // Check if old nested structure (year as key, and value contains month numbers)
        if (!isNaN(Number(firstKey)) && firstValue && typeof firstValue === "object") {
          const monthKeys = Object.keys(firstValue)
          if (monthKeys.length > 0 && !isNaN(Number(monthKeys[0]))) {
            // Old structure detected: {2024: {1: {...}, 2: {...}}}
            const newMonthWiseTotal: Record<string, any> = {}

            for (const [year, months] of Object.entries(tagData.monthWiseTotal)) {
              for (const [month, monthData] of Object.entries(months as Record<string, any>)) {
                const monthKey = `${year}-${String(month).padStart(2, "0")}`

                const newMonthData: Record<string, any> = {
                  expense: (monthData as any).total || 0,
                  recovery: 0,
                }

                // Migrate user amounts
                for (const [key, value] of Object.entries(monthData as Record<string, any>)) {
                  if (key !== "total") {
                    newMonthData[key] = {
                      expense: value as number,
                      recovery: 0,
                    }
                  }
                }

                newMonthWiseTotal[monthKey] = newMonthData
              }
            }

            updates.monthWiseTotal = newMonthWiseTotal
            needsUpdate = true
            console.log(`  Migrating monthWiseTotal structure (${Object.keys(newMonthWiseTotal).length} months)`)
            console.log(`  Sample: ${inspect(Object.keys(newMonthWiseTotal).slice(0, 3))}`)
          }
        }
      } else if (!tagData.monthWiseTotal) {
        // Initialize if missing
        updates.monthWiseTotal = {}
        needsUpdate = true
        console.log(`  Initializing monthWiseTotal`)
      }

      // Perform update if needed
      if (needsUpdate) {
        await kilvishDb.collection("Tags").doc(tagId).update(updates)
        console.log(`  ✅ Updated tag ${tagId}`)
        updatedCount++
      } else {
        console.log(`  ⏭️  Skipped (already migrated)`)
        skippedCount++
      }

      processedCount++
    }

    const result = {
      success: true,
      processedTags: processedCount,
      updatedTags: updatedCount,
      skippedTags: skippedCount,
    }

    console.log("\n=== Migration Complete ===")
    console.log(inspect(result))
    return result
  } catch (error) {
    console.error("Migration error:", error)
    throw error
  }
}

// Run the migration
migrateTagSchema()
  .then(() => {
    console.log("\n✅ Done!")
    process.exit(0)
  })
  .catch((error) => {
    console.error("\n❌ Migration failed:", error)
    process.exit(1)
  })