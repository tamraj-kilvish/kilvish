const { ImageAnalysisClient } = require("@azure-rest/ai-vision-image-analysis")
const createClient = require("@azure-rest/ai-vision-image-analysis").default
const { AzureKeyCredential } = require("@azure/core-auth")

// Load the .env file if it exists
// require("dotenv").config();

const endpoint = process.env["AZURE_VISION_ENDPOINT"]
const key = process.env["AZURE_VISION_KEY"]

const credential = new AzureKeyCredential(key)
const client = createClient(endpoint, credential)

const features = [
  //'Caption',
  "Read",
]

console.log("executing script")

const imageUrl = "https://github.com/tamraj-kilvish/kilvish/blob/ocr-azure-vision/assets/images/receipt.jpeg?raw=true"
//const imageUrl = "https://firebasestorage.googleapis.com/v0/b/tamraj-kilvish.firebasestorage.app/o/receipts%2Fdpuxymx146RtRjEXTqsK_LeiKAAb7nUQLrK9wwQyO.png?alt=media&token=9cfcecd8-673a-4fdb-9b8f-fda3b2715ff8";

async function analyzeImageFromUrl() {
  const result = await client.path("/imageanalysis:analyze").post({
    body: {
      url: imageUrl,
    },
    queryParameters: {
      features: features,
    },
    contentType: "application/json",
  })
  //console.log(result)

  const iaResult = result.body

  // if (iaResult.captionResult) {
  //   console.log(`Caption: ${iaResult.captionResult.text} (confidence: ${iaResult.captionResult.confidence})`);
  // }
  if (iaResult.readResult) {
    iaResult.readResult.blocks.forEach((block) => block.lines.forEach((line) => console.log(`${line.text}`)))
  }
}

analyzeImageFromUrl()
