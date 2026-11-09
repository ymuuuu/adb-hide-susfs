#!/bin/sh
# zips ../module into a flashable module zip, skips nothing, expects
# magisk/kernelsu zip layout: module.prop at zip root
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^version=//p' module/module.prop)
NAME="adb-hide-susfs-${VERSION}"
cd module
zip -rX "../${NAME}.zip" . -x "*.DS_Store"
cd ..
ls -la "${NAME}.zip"
