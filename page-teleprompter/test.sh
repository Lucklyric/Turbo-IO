#!/bin/bash
# Host-only tests for the page-wise teleprompter core. Needs the Command Line
# Tools, not a full Xcode: nothing here touches UIKit or the iOS SDK.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
flags=(-fobjc-arc -fmodules -Wall -Wextra -framework Foundation)
[[ "${1:-}" == "--san" ]] && flags+=(-fsanitize=address,undefined -g)

run() {
    local name=$1; shift
    xcrun clang "${flags[@]}" "$@" -o "build/$name"
    "./build/$name"
}

run page-teleprompter-tests  TIOTokens.m PageTeleprompter.m PageTeleprompterTests.m
run manuscript-store-tests   ManuscriptStore.m TIOTokens.m PageTeleprompter.m ManuscriptStoreTests.m
run follow-session-tests     FollowSession.m TIOTokens.m PageTeleprompter.m FollowSessionTests.m
