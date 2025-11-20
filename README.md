# Building the app

Create `.env` file with following entries

```
export CHROME_EXECUTABLE="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" #change the path if you have different browser
export AZURE_VISION_ENDPOINT=https://xxxx.cognitiveservices.azure.com/ # xxxx is kilvish specific url
export AZURE_VISION_KEY=xxxx # replace xxxx with the Azure key
```

## Testing on web

```
source .env # to load all the env variables
flutter run -d chrome --dart-define=AZURE_VISION_ENDPOINT=$AZURE_VISION_ENDPOINT --dart-define=AZURE_VISION_KEY=$AZURE_VISION_KEY
```

## Building & installing app

```
source .env
flutter build apk/ipa --debug --dart-define=AZURE_VISION_ENDPOINT=$AZURE_VISION_ENDPOINT --dart-define=AZURE_VISION_KEY=$AZURE_VISION_KEY
flutter install apk/ipa --debug
```
