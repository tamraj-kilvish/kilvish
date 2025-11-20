const { ImageAnalysisClient } = require("@azure-rest/ai-vision-image-analysis")
const createClient = require("@azure-rest/ai-vision-image-analysis").default
const { AzureKeyCredential } = require("@azure/core-auth")

// Load the .env file if it exists
// require("dotenv").config();

const endpoint = process.env["VISION_ENDPOINT"]
const key = process.env["VISION_KEY"]

const credential = new AzureKeyCredential(key)
const client = createClient(endpoint, credential)

const features = [
  //'Caption',
  "Read",
]

console.log("executing script")

const imageUrl = "https://github.com/tamraj-kilvish/kilvish/blob/ocr-azure-vision/assets/images/receipt.jpeg?raw=true"

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
