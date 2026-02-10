import * as functions from "firebase-functions/v2";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const db = getFirestore();

export const migrateRecoveryToTag = functions.https.onCall(
  async (request) => {
    // Extract data from request
    const { recoveryId, targetTagId } = request.data;

    // Check authentication
    if (!request.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "User must be authenticated"
      );
    }

    const userId = request.auth.uid;

    try {
      // 1. Get recovery and target tag
      const recoveryDoc = await db.collection("Tags").doc(recoveryId).get();
      const targetTagDoc = await db.collection("Tags").doc(targetTagId).get();

      if (!recoveryDoc.exists || !targetTagDoc.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Recovery or target tag not found"
        );
      }

      const recoveryData = recoveryDoc.data()!;
      const targetTagData = targetTagDoc.data()!;

      // Verify recovery is owned by user
      if (recoveryData.ownerId !== userId) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only owner can migrate recovery"
        );
      }

      // Verify recovery is actually a recovery
      if (!recoveryData.isRecovery) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Source must be a recovery tag"
        );
      }

      // Verify target allows recovery
      if (!targetTagData.allowRecovery) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Target tag must have allowRecovery enabled"
        );
      }

      const batch = db.batch();

      // 2. Get all expenses from recovery
      const expensesSnapshot = await db
        .collection("Tags")
        .doc(recoveryId)
        .collection("Expenses")
        .get();

      // 3. Copy expenses to target tag and update expense tags
      for (const expenseDoc of expensesSnapshot.docs) {
        const expenseData = expenseDoc.data();

        // Copy to target tag's expenses collection
        const targetExpenseRef = db
          .collection("Tags")
          .doc(targetTagId)
          .collection("Expenses")
          .doc(expenseDoc.id);
        batch.set(targetExpenseRef, expenseData);

        // Update expense in user's collection - replace recoveryId with targetTagId in tags
        const userExpenseRef = db
          .collection("Users")
          .doc(expenseData.ownerId)
          .collection("Expenses")
          .doc(expenseDoc.id);

        // Get current expense to update tags array
        const userExpenseDoc = await userExpenseRef.get();
        if (userExpenseDoc.exists) {
          const userData = userExpenseDoc.data()!;
          const tagIds = (userData.tagIds || []) as string[];

          // Replace recoveryId with targetTagId
          const updatedTagIds = tagIds.map((id: string) =>
            id === recoveryId ? targetTagId : id
          );

          batch.update(userExpenseRef, {
            tagIds: updatedTagIds,
            recoveryId: targetTagId, // Update recoveryId reference
          });
        }
      }

      // 4. Get all settlements from recovery
      const settlementsSnapshot = await db
        .collection("Tags")
        .doc(recoveryId)
        .collection("Settlements")
        .get();

      // 5. Copy settlements to target tag
      for (const settlementDoc of settlementsSnapshot.docs) {
        const settlementData = settlementDoc.data();

        const targetSettlementRef = db
          .collection("Tags")
          .doc(targetTagId)
          .collection("Settlements")
          .doc(settlementDoc.id);
        batch.set(targetSettlementRef, settlementData);
      }

      // 6. Merge monetary totals from recovery to target
      const recoveryTotalTillDate = recoveryData.totalTillDate || {
        expense: 0,
        recovery: 0,
      };

      batch.update(db.collection("Tags").doc(targetTagId), {
        "totalTillDate.expense": FieldValue.increment(
          recoveryTotalTillDate.expense || 0
        ),
        "totalTillDate.recovery": FieldValue.increment(
          recoveryTotalTillDate.recovery || 0
        ),
      });

      // 7. Update user's accessibleTagIds (remove recovery)
      const sharedUsers = recoveryData.sharedWith || [];
      for (const sharedUserId of sharedUsers) {
        const userRef = db.collection("Users").doc(sharedUserId);
        batch.update(userRef, {
          accessibleTagIds: FieldValue.arrayRemove(recoveryId),
        });
      }

      // 8. Delete recovery tag
      batch.delete(db.collection("Tags").doc(recoveryId));

      await batch.commit();

      return { success: true, message: "Migration completed successfully" };
    } catch (error) {
      console.error("Error migrating recovery:", error);
      throw new functions.https.HttpsError(
        "internal",
        "Failed to migrate recovery"
      );
    }
  }
);