/** @type {import('ts-jest').JestConfigWithTsJest} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testMatch: ['**/tests/**/*.test.ts'], // Looks for .test.ts files in your tests/ folder
  transform: {
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        // 🟢 This line tells ts-jest to ignore compiler errors and just run the tests
        diagnostics: {
          ignoreCodes: [6133, 6192], // Ignores "declared but never used" errors
          warnOnly: true,            // Converts all other errors into warnings
        },
      },
    ],
  },
};