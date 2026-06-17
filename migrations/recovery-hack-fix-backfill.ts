import * as admin from "firebase-admin"

admin.initializeApp({
  credential: admin.credential.cert(require("../serviceAccountKey.json")),
})
admin.firestore().settings({ databaseId: "kilvish" })
const kilvishdb = admin.firestore()

function monthKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`
}

type UserData = { spent: number; myShare: number; received: number; paid: number }

async function backfill() {
  const tags = await kilvishdb.collection("Tags").get()
  console.log(`Processing ${tags.size} tags`)

  for (const tagDoc of tags.docs) {
    const tagId = tagDoc.id
    if(tagId !== "kjM85gXHnxnnWIp4dLE4") continue
    console.log(`Processing ${tagId}`)

    const tagData = tagDoc.data()
    const allMembers = new Set<string>([tagData.ownerId, ...(tagData.sharedWith ?? [])])

    const total: Record<string, UserData> = {}
    const monthWise: Record<string, Record<string, UserData>> = {}

    const init = (store: Record<string, UserData>, userId: string) => {
      store[userId] ??= { spent: 0, myShare: 0, received: 0, paid: 0 }
    }
    const add = (store: Record<string, UserData>, userId: string, field: keyof UserData, delta: number) => {
      init(store, userId)
      store[userId][field] += delta
    }
    const getMonth = (mk: string) => {
      monthWise[mk] ??= {}
      return monthWise[mk]
    }

    const expenses = await tagDoc.ref.collection("Expenses").get()

    for (const expenseDoc of expenses.docs) {
      const exp = expenseDoc.data()
      const expenseAmount = ((exp.expenseAmount ?? exp.amount) as number) || 0
      const ownerId = exp.ownerId as string
      const mk = monthKey((exp.timeOfTransaction as admin.firestore.Timestamp).toDate())

      const recipients = await expenseDoc.ref.collection("Recipients").get()
      const settlementDocs = recipients.docs.filter((r) => r.data().settlementMonth)
      const distributionDocs = recipients.docs.filter((r) => !r.data().settlementMonth)
      const isSettlementExpense = settlementDocs.length > 0 && distributionDocs.length === 0

      // spent: always add (mirrors onExpenseCreated).
      // For settlement expenses, settlement processing below subtracts it back (reclassify to paid).
      add(total, ownerId, "spent", expenseAmount)
      add(getMonth(mk), ownerId, "spent", expenseAmount)

      if (distributionDocs.length > 0) {
        // Advanced mode: explicit distribution for myShare
        for (const recipDoc of distributionDocs) {
          const r = recipDoc.data()
          const recipientId = recipDoc.id
          const amount = (r.amount as number) || 0
          add(total, recipientId, "myShare", amount)
          add(getMonth(mk), recipientId, "myShare", amount)
        }
        //await expenseDoc.ref.update({ isSimpleMode: false })
      } else if (!isSettlementExpense) {
        // Pure simple mode: no recipients at all → equal split
        const N = allMembers.size
        for (const memberId of allMembers) {
          add(total, memberId, "myShare", expenseAmount / N)
          add(getMonth(mk), memberId, "myShare", expenseAmount / N)
        }
        // await expenseDoc.ref.update({
        //   isSimpleMode: true,
        //   simpleParticipants: Array.from(allMembers),
        // })
      }
      // else: settlement expense — skip myShare entirely

      // Settlements: reclassify debtor's spent → paid, credit creditor's received
      for (const recipDoc of settlementDocs) {
        const r = recipDoc.data()
        const creditorId = recipDoc.id               // gets paid back
        const debtorId = r.expenseOwnerId as string  // filed the settlement expense
        const amount = (r.amount as number) || 0
        const smk = r.settlementMonth as string      // already "YYYY-MM"

        add(total, debtorId, "spent", -amount)
        add(getMonth(mk), debtorId, "spent", -amount)   // reverse in filing month, not settlementMonth
        add(total, debtorId, "paid", amount)
        add(getMonth(smk), debtorId, "paid", amount)
        add(total, creditorId, "received", amount)
        add(getMonth(smk), creditorId, "received", amount)
      }
    }

    if (Object.keys(total).length === 0) {
      console.log(`  (no expenses — skipping)`)
      continue
    }

    // --- Dry-run comparison: old stored vs. new computed ---
    const existingTotal = (tagData.total ?? {}) as Record<string, any>

    const col = (s: string | number, w: number) => String(s).padStart(w)
    const hdr = [
      "userId".padEnd(28),
      col("old_expense", 13), col("new_expense", 13),
      col("old_recovery", 14), col("new_outstanding", 16),
    ].join(" | ")

    const printTable = (
      newStore: Record<string, UserData>,
      oldStore: Record<string, any>,
      indent = ""
    ) => {
      const allUsers = new Set([
        ...Object.keys(newStore),
        ...Object.keys(oldStore).filter((k) => k !== "acrossUsers"),
      ])
      console.log(indent + hdr)
      console.log(indent + "-".repeat(hdr.length))
      for (const userId of allUsers) {
        const newData = newStore[userId] ?? { spent: 0, myShare: 0, received: 0, paid: 0 }
        const old = oldStore[userId] ?? {}
        const oldExpense     = (old.expense  ?? 0) as number
        const oldRecovery    = (old.recovery ?? 0) as number
        const newExpense     = newData.spent + newData.paid - newData.received
        const newOutstanding = newData.spent - newData.myShare - newData.received + newData.paid
        console.log(indent + [
          userId.padEnd(28),
          col(oldExpense.toFixed(2),     13), col(newExpense.toFixed(2),     13),
          col(oldRecovery.toFixed(2),    14), col(newOutstanding.toFixed(2), 16),
        ].join(" | "))
      }
    }

    // --- Month-wise comparison ---
    const existingMonthWise = (tagData.monthWiseTotal ?? {}) as Record<string, any>
    const allMonths = new Set([...Object.keys(monthWise), ...Object.keys(existingMonthWise)])

    console.log(`\n=== Tag: ${tagId} (${tagData.name ?? ""}) ===`)
    for (const mk of [...allMonths].sort()) {
      console.log(`\n  -- ${mk} --`)
      printTable(monthWise[mk] ?? {}, existingMonthWise[mk] ?? {}, "  ")
    }

    // --- Total summary ---
    console.log(`\n  -- TOTAL --`)
    printTable(total, existingTotal, "  ")

    // --- Write new fields alongside legacy expense/recovery for backward compatibility ---
    // const update: Record<string, any> = {}
    // for (const [userId, data] of Object.entries(total)) {
    //   const expense    = data.spent + data.paid - data.received
    //   const recovery   = data.spent - data.myShare - data.received + data.paid
    //   update[`total.${userId}.spent`]    = data.spent
    //   update[`total.${userId}.myShare`]  = data.myShare
    //   update[`total.${userId}.received`] = data.received
    //   update[`total.${userId}.paid`]     = data.paid
    //   update[`total.${userId}.expense`]  = expense
    //   update[`total.${userId}.recovery`] = recovery
    // }
    // for (const [mk, store] of Object.entries(monthWise)) {
    //   for (const [userId, data] of Object.entries(store)) {
    //     const expense    = data.spent + data.paid - data.received
    //     const recovery   = data.spent - data.myShare - data.received + data.paid
    //     update[`monthWiseTotal.${mk}.${userId}.spent`]    = data.spent
    //     update[`monthWiseTotal.${mk}.${userId}.myShare`]  = data.myShare
    //     update[`monthWiseTotal.${mk}.${userId}.received`] = data.received
    //     update[`monthWiseTotal.${mk}.${userId}.paid`]     = data.paid
    //     update[`monthWiseTotal.${mk}.${userId}.expense`]  = expense
    //     update[`monthWiseTotal.${mk}.${userId}.recovery`] = recovery
    //   }
    // }
    // await tagDoc.ref.update(update)

    console.log(`\n  ✓ ${tagId}`)
  }
  console.log("Backfill complete")
}

backfill().catch(console.error)
