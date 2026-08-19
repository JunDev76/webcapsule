#!/usr/bin/env bash
set -euo pipefail

PACKAGE="com.webcapsule.reactnative.test"
RUNNER="androidx.test.runner.AndroidJUnitRunner"
CLASS="com.webcapsule.reactnative.runtime.AndroidProcessRestartAcceptanceTest#runPhase"

run_phase() {
  local scenario="$1"
  local phase="$2"
  adb shell am instrument -w -r \
    -e class "$CLASS" \
    -e scenario "$scenario" \
    -e phase "$phase" \
    "$PACKAGE/$RUNNER"
}

run_phase attempt1 prepare
run_phase attempt1 verify
run_phase attempt2 prepare
run_phase attempt2 verify
