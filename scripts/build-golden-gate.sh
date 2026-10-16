#!/bin/zsh
# Builds Golden Gate's gg-stack-tool and gg-coap-client for macOS into vendor/bin.
#
# Source: the fitbit-air-notification-bridge fork of Fitbit's Golden Gate (Apache-2.0),
# pinned to the commit this project was tested with. Needs git, cmake and ninja
# (brew install cmake ninja) and the Xcode Command Line Tools. No full Xcode needed.
set -eu
ROOT="${0:A:h:h}"
REPO_URL="https://github.com/paceaitian/fitbit-air-notification-bridge.git"
COMMIT="6fec57fafc68e03904f49d823248e38b07a54478"
SRC="$ROOT/vendor/golden-gate-src"
OUT="$ROOT/vendor/bin"

if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none "$REPO_URL" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$COMMIT" || true
git -C "$SRC" checkout --quiet "$COMMIT"
git -C "$SRC" submodule update --init --depth 1 external/lwip external/mbedtls-3

# Embed an Info.plist so macOS allows the tools to use Bluetooth
cmake -GNinja -H"$SRC/xp" -B"$SRC/xp/build/cmake/native" \
  -C"$SRC/xp/config/profiles/macOS_cmdline.cmake" \
  -DGG_ENABLE_UNIT_TESTS=FALSE -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-sectcreate,__TEXT,__info_plist,$ROOT/spike/Info.plist"
cmake --build "$SRC/xp/build/cmake/native" --target gg-stack-tool gg-coap-client

mkdir -p "$OUT"
cp "$SRC/xp/build/cmake/native/apps/stack-tool/gg-stack-tool" \
   "$SRC/xp/build/cmake/native/apps/coap-client/gg-coap-client" "$OUT/"
echo "Built $OUT/gg-stack-tool and $OUT/gg-coap-client"
