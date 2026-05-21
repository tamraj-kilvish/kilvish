#!/bin/bash

flutter build web --base-href /app/
cp -r build/web/* ../tamraj-kilvish.github.io/app/
cd ../tamraj-kilvish.github.io
cp app/index.html 404.html
git commit -am "updating to latest kilvish app"
git push origin main
cd -