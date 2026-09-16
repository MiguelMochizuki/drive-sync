#!/usr/bin/env bash
# test_helper.bash: shared setup and teardown helpers for all bats suites.
#
# Load from any *.bats file with:
#   load '../test_helper'
# This works for both tests/characterization/*.bats and tests/unit/*.bats,
# since both live two directories under the repo root.
#
# Each *.bats file defines its own setup()/teardown() that call
# common_setup/common_teardown. bats only honors one function named
# setup per file, so the shared logic cannot itself be named setup().

common_setup() {
    bats_require_minimum_version 1.5.0
    TEST_TMP_DIR="$(mktemp -d)"
    export HOME="$TEST_TMP_DIR/home"
    mkdir -p "$HOME"

    MOCK_STATE_DIR="$TEST_TMP_DIR/mock_state"
    mkdir -p "$MOCK_STATE_DIR"
    export MOCK_STATE_DIR

    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export REPO_ROOT

    export PATH="$REPO_ROOT/tests/mocks:$PATH"

    unset MOCK_RCLONE_EXIT_SEQUENCE MOCK_RCLONE_ABOUT_JSON \
          MOCK_RCLONE_ABOUT_EXIT MOCK_RCLONE_REMOTES MOCK_GS_BEHAVIOR
}

common_teardown() {
    rm -rf "$TEST_TMP_DIR"
}

# make_pdf_fixture <path> <size_bytes>
#
# Writes a dummy file of the given size at the given path. Content is
# irrelevant for tests since gs is mocked, only the byte size matters.
make_pdf_fixture() {
    local path="$1"
    local size="$2"
    head -c "$size" /dev/zero > "$path"
}
