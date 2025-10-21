const firebase = require("@firebase/rules-unit-testing")
const fs = require("fs")

const PROJECT_ID = "test-project"
const RULES_FILE = "./firestore.rules"

// Test data
const mockUsers = {
  user1: { id: "user1-id", uid: "user1-uid", phone: "+1234567890" },
  user2: { id: "user2-id", uid: "user2-uid", phone: "+0987654321" },
  user3: { id: "user3-id", uid: "user3-uid", phone: "+1122334455" },
}

const mockTag = {
  name: "Groceries",
  ownerId: "user1-id",
  userIds: ["user2-id"], // user1 is owner, user2 has access, user3 doesn't
}

const mockExpense = {
  txId: "tx123",
  to: "Store ABC",
  timeOfTransaction: new Date(),
  updatedAt: new Date(),
  amount: 50.0,
}

describe("Firestore Security Rules Tests", () => {
  let testEnv

  beforeAll(async () => {
    // Load rules
    const rules = fs.readFileSync(RULES_FILE, "utf8")

    // Create test environment
    testEnv = await firebase.initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        host: "127.0.0.1",
        port: 8080,
        rules: rules,
      },
    })
  })

  afterAll(async () => {
    await testEnv.cleanup()
  })

  beforeEach(async () => {
    await testEnv.clearFirestore()
  })

  describe("Tag Expenses Access Rules", () => {
    test("Tag owner can read tag expenses", async () => {
      const user1Db = testEnv.authenticatedContext("user1-uid", { userId: "user1-id" }).firestore()

      // Setup: Create tag and expense as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
        await db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1").set(mockExpense)
      })

      // Test: Owner should be able to read expenses
      const expenseRef = user1Db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1")
      await firebase.assertSucceeds(expenseRef.get())
    })

    test("User in userIds array can read tag expenses", async () => {
      const user2Db = testEnv.authenticatedContext("user2-uid", { userId: "user2-id" }).firestore()

      // Setup: Create tag and expense as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
        await db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1").set(mockExpense)
      })

      // Test: User2 (in userIds) should be able to read expenses
      const expenseRef = user2Db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1")
      await firebase.assertSucceeds(expenseRef.get())
    })

    test("User NOT in userIds array cannot read tag expenses", async () => {
      const user3Db = testEnv.authenticatedContext("user3-uid", { userId: "user3-id" }).firestore()

      // Setup: Create tag and expense as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
        await db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1").set(mockExpense)
      })

      // Test: User3 (NOT in userIds) should NOT be able to read expenses
      const expenseRef = user3Db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1")
      await firebase.assertFails(expenseRef.get())
    })

    test("Unauthenticated user cannot read tag expenses", async () => {
      const unauthDb = testEnv.unauthenticatedContext().firestore()

      // Setup: Create tag and expense as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
        await db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1").set(mockExpense)
      })

      // Test: Unauthenticated user should NOT be able to read expenses
      const expenseRef = unauthDb.collection("Tags").doc("tag1").collection("Expenses").doc("expense1")
      await firebase.assertFails(expenseRef.get())
    })

    test("Only tag owner can write expenses", async () => {
      const user1Db = testEnv.authenticatedContext("user1-uid", { userId: "user1-id" }).firestore()
      const user2Db = testEnv.authenticatedContext("user2-uid", { userId: "user2-id" }).firestore()

      // Setup: Create tag as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
      })

      // Test: Owner can write expenses
      const ownerExpenseRef = user1Db.collection("Tags").doc("tag1").collection("Expenses").doc("expense1")
      await firebase.assertSucceeds(ownerExpenseRef.set(mockExpense))

      // Test: User in userIds (but not owner) cannot write expenses
      const userExpenseRef = user2Db.collection("Tags").doc("tag1").collection("Expenses").doc("expense2")
      await firebase.assertFails(userExpenseRef.set(mockExpense))
    })
  })

  describe("Tag Access Rules", () => {
    test("Tag owner can read tag", async () => {
      const user1Db = testEnv.authenticatedContext("user1-uid", { userId: "user1-id" }).firestore()

      // Setup: Create tag as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
      })

      // Test: Owner should be able to read tag
      const tagRef = user1Db.collection("Tags").doc("tag1")
      await firebase.assertSucceeds(tagRef.get())
    })

    test("User in userIds can read tag", async () => {
      const user2Db = testEnv.authenticatedContext("user2-uid", { userId: "user2-id" }).firestore()

      // Setup: Create tag as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
      })

      // Test: User2 (in userIds) should be able to read tag
      const tagRef = user2Db.collection("Tags").doc("tag1")
      await firebase.assertSucceeds(tagRef.get())
    })

    test("User NOT in userIds cannot read tag", async () => {
      const user3Db = testEnv.authenticatedContext("user3-uid", { userId: "user3-id" }).firestore()

      // Setup: Create tag as admin
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore()
        await db.collection("Tags").doc("tag1").set(mockTag)
      })

      // Test: User3 (NOT in userIds) should NOT be able to read tag
      const tagRef = user3Db.collection("Tags").doc("tag1")
      await firebase.assertFails(tagRef.get())
    })
  })
})
