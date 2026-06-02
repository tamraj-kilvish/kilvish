import * as admin from "firebase-admin"

admin.initializeApp()
const db = admin.firestore()

function monthKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`
}

type UserData = { spent: number; myShare: number; received: number; paid: number }

async function backfill() {
  const tags = await db.collection("Tags").get()
  console.log(`Processing ${tags.size} tags`)

  for (const tagDoc of tags.docs) {
    const tagId = tagDoc.id
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
        await expenseDoc.ref.update({ isSimpleMode: false })
      } else if (!isSettlementExpense) {
        // Pure simple mode: no recipients at all → equal split
        const N = allMembers.size
        for (const memberId of allMembers) {
          add(total, memberId, "myShare", expenseAmount / N)
          add(getMonth(mk), memberId, "myShare", expenseAmount / N)
        }
        await expenseDoc.ref.update({
          isSimpleMode: true,
          simpleParticipants: Array.from(allMembers),
        })
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
        add(getMonth(smk), debtorId, "spent", -amount)
        add(total, debtorId, "paid", amount)
        add(getMonth(smk), debtorId, "paid", amount)
        add(total, creditorId, "received", amount)
        add(getMonth(smk), creditorId, "received", amount)
      }
    }

    // Build Firestore update — write new fields alongside old ones for backward compatibility.
    // Old fields (expense, recovery, acrossUsers) are left untouched so old app versions
    // can still read them during the transition window before everyone has updated.
    const update: Record<string, any> = {}

    for (const [userId, data] of Object.entries(total)) {
      update[`total.${userId}.spent`] = data.spent
      update[`total.${userId}.myShare`] = data.myShare
      update[`total.${userId}.received`] = data.received
      update[`total.${userId}.paid`] = data.paid
    }

    for (const [mk, store] of Object.entries(monthWise)) {
      for (const [userId, data] of Object.entries(store)) {
        update[`monthWiseTotal.${mk}.${userId}.spent`] = data.spent
        update[`monthWiseTotal.${mk}.${userId}.myShare`] = data.myShare
        update[`monthWiseTotal.${mk}.${userId}.received`] = data.received
        update[`monthWiseTotal.${mk}.${userId}.paid`] = data.paid
      }
    }

    await tagDoc.ref.update(update)
    console.log(`  ✓ ${tagId}`)
  }
  console.log("Backfill complete")
}

backfill().catch(console.error)
