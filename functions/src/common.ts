import * as admin from "firebase-admin"

// Initialize once
admin.initializeApp()
admin.firestore().settings({ databaseId: "kilvish" })

// Export shared instance
export const kilvishDb = admin.firestore()

// Data interfaces for new monetary summary structure
export interface UserMonetaryData {
  expense: number
  recovery: number
}

export interface MonthlyMonetaryData {
  acrossUsers: UserMonetaryData
  [userId: string]: UserMonetaryData // Dynamic user IDs
}

export interface Tag {
  name: string
  ownerId: string
  sharedWith: string[]
  sharedWithFriends: string[]
  isRecoveryExpense?: boolean
  total: MonthlyMonetaryData
  monthWiseTotal: { [monthKey: string]: MonthlyMonetaryData } // "YYYY-MM"
}

export interface Expense {
  to: string
  amount: number
  timeOfTransaction: admin.firestore.Timestamp
  createdAt: admin.firestore.Timestamp
  updatedAt: admin.firestore.Timestamp
  notes?: string
  receiptUrl?: string
  txId: string
  ownerId: string
  recoveryAmount?: number
}

export interface WIPExpense {
  to?: string
  amount?: number
  timeOfTransaction?: admin.firestore.Timestamp
  createdAt: admin.firestore.Timestamp
  updatedAt: admin.firestore.Timestamp
  notes?: string
  receiptUrl?: string
  status: string
  tags?: string
  settlements?: Array<{ to: string; month: number; year: number; tagId: string }>
  isRecoveryExpense?: boolean
  recoveryAmount?: number
}