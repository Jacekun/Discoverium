#!/bin/bash
# Convenience script

CURR_DIR="$(pwd)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
trap "cd \"$CURR_DIR\"" EXIT
cd "$SCRIPT_DIR"

if [ -z "$1" ]; then
    git fetch && git merge origin/main && git push # Typically run after a PR to main, so bring dev up to date
fi

# Update local Flutter
git submodule update --remote
cd .flutter
git fetch
git checkout stable
git pull
FLUTTER_GIT_URL="https://github.com/flutter/flutter/" flutter upgrade
cd ..

# Keep global Flutter, if any, in sync
if [ -f ~/flutter/bin/flutter ]; then
    cd ~/flutter
    ./bin/flutter channel stable
    ./bin/flutter upgrade
    cd "$SCRIPT_DIR"
fi

if [ -z "$(which flutter)" ]; then
    export PATH="$PATH:$SCRIPT_DIR/.flutter/bin"
fi

# flutter pub upgrade --tighten --major-versions

rm ./build/app/outputs/flutter-apk/* 2>/dev/null                                       # Get rid of older builds if any
flutter build apk --flavor normal
