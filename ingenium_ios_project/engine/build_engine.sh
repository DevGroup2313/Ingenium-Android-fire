#!/bin/bash
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Builds engine/IngeniumEngine.xcframework (device + simulator) on a Mac.
#   engine/build_engine.sh <path to llama.cpp>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LLAMA_DIR="$(cd "${1:?usage: build_engine.sh <llama.cpp dir>}" && pwd)"
MIN_IOS=16.4
JOBS=$(sysctl -n hw.logicalcpu)

build() {   # $1 = build dir, $2 = sdk, $3 = architectures
    local dir="$HERE/$1"
    rm -rf "$dir"
    cmake -S "$HERE" -B "$dir" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$2" \
        -DCMAKE_OSX_ARCHITECTURES="$3" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
        -DCMAKE_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument" \
        -DCMAKE_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument" \
        -DLLAMA_DIR="$LLAMA_DIR"
    cmake --build "$dir" --config Release --target ingenium_engine -j "$JOBS"
    # one archive holding the engine and every llama.cpp library it uses
    find "$dir" -name '*.a' -not -name 'libingenium_all.a' -print > "$dir/libs.txt"
    echo "combining: $(wc -l < "$dir/libs.txt") libraries"
    xcrun libtool -static -o "$dir/libingenium_all.a" $(cat "$dir/libs.txt")
}

build build-ios-device iphoneos arm64
build build-ios-sim iphonesimulator arm64

mkdir -p "$HERE/include"
cp "$HERE/../../native/ingenium_engine.h" "$HERE/include/"
rm -rf "$HERE/IngeniumEngine.xcframework"
xcodebuild -create-xcframework \
    -library "$HERE/build-ios-device/libingenium_all.a" -headers "$HERE/include" \
    -library "$HERE/build-ios-sim/libingenium_all.a" -headers "$HERE/include" \
    -output "$HERE/IngeniumEngine.xcframework"
echo "Engine ready: $HERE/IngeniumEngine.xcframework"
