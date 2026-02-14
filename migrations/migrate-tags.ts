import * as admin from "firebase-admin"
import { inspect } from "util"

// Initialize Firebase Admin with your service account
admin.initializeApp({
  credential: admin.credential.cert(require("../serviceAccountKey.json")),
})

admin.firestore().settings({ databaseId: "kilvish" })
const kilvishDb = admin.firestore()

async function migrateToTypedStructure() {
  console.log("Starting migration to typed structure (total + acrossUsers)...")

  try {
    const tagsSnapshot = await kilvishDb.collection("Tags").get()
    let processedCount = 0
    let updatedCount = 0
    let skippedCount = 0

    for (const tagDoc of tagsSnapshot.docs) {
      const tagData = tagDoc.data()
      const tagId = tagDoc.id

      if(tagId != "sMXFan8MwtPZ52N5wfox") continue;

      const updates: Record<string, any> = {}
      let needsUpdate = false

      console.log(`\n=== Processing Tag: ${tagId} (${tagData.name}) ===`)

      // Check if already migrated (has 'total' field with 'acrossUsers' key)
      if (tagData.total && tagData.total.acrossUsers) {
        console.log(`  ⏭️  Already migrated, skipping`)
        skippedCount++
        processedCount++
        continue
      }

      // 1. Migrate totalTillDate + userWiseTotal -> total
      if (tagData.totalTillDate || tagData.userWiseTotal) {
        const newTotal: Record<string, any> = {}

        // Add acrossUsers summary
        if (tagData.totalTillDate) {
          newTotal.acrossUsers = {
            expense: tagData.totalTillDate.expense || 0,
            recovery: tagData.totalTillDate.recovery || 0,
          }
        } else {
          newTotal.acrossUsers = { expense: 0, recovery: 0 }
        }

        // Add user summaries
        if (tagData.userWiseTotal) {
          for (const [userId, amounts] of Object.entries(tagData.userWiseTotal)) {
            if (typeof amounts === "object" && amounts !== null) {
              newTotal[userId] = {
                expense: (amounts as any).expense || 0,
                recovery: (amounts as any).recovery || 0,
              }
            }
          }
        }

        updates.total = newTotal
        needsUpdate = true
        console.log(`  Migrating total structure (acrossUsers + ${Object.keys(newTotal).length - 1} users)`)
      }

      // 2. Migrate monthWiseTotal structure (add acrossUsers to each month)
      if (tagData.monthWiseTotal && Object.keys(tagData.monthWiseTotal).length > 0) {
        const newMonthWiseTotal: Record<string, any> = {}
        let hasOldStructure = false

        for (const [monthKey, monthData] of Object.entries(tagData.monthWiseTotal)) {
          if (typeof monthData === "object" && monthData !== null) {
            const typedMonthData = monthData as Record<string, any>

            // Check if old structure (has 'expense' and 'recovery' as direct keys)
            if (typedMonthData.expense !== undefined || typedMonthData.recovery !== undefined) {
              hasOldStructure = true

              const newMonthData: Record<string, any> = {
                acrossUsers: {
                  expense: typedMonthData.expense || 0,
                  recovery: typedMonthData.recovery || 0,
                },
              }

              // Copy user data
              for (const [key, value] of Object.entries(typedMonthData)) {
                if (key !== "expense" && key !== "recovery" && typeof value === "object" && value !== null) {
                  newMonthData[key] = value
                }
              }

              newMonthWiseTotal[monthKey] = newMonthData
            } else {
              // Already has correct structure, keep as-is
              newMonthWiseTotal[monthKey] = monthData
            }
          }
        }

        if (hasOldStructure) {
          updates.monthWiseTotal = newMonthWiseTotal
          needsUpdate = true
          console.log(`  Migrating monthWiseTotal structure (${Object.keys(newMonthWiseTotal).length} months)`)
        }
      }

      // Perform update if needed
      if (needsUpdate) {
        await kilvishDb.collection("Tags").doc(tagId).update(updates)
        console.log(`  ✅ Updated tag ${tagId}`)
        updatedCount++
      } else {
        console.log(`  ⏭️  No updates needed`)
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
migrateToTypedStructure()
  .then(() => {
    console.log("\n✅ Done!")
    process.exit(0)
  })
  .catch((error) => {
    console.error("\n❌ Migration failed:", error)
    process.exit(1)
  })