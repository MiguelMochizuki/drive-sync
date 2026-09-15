#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/logging.sh"
    source "$REPO_ROOT/lib/storage.sh"
    LOG_FILE="$TEST_TMP_DIR/test.log"
}

teardown() {
    common_teardown
}

@test "show_storage_usage prints used and total in binary units" {
    export MOCK_RCLONE_ABOUT_JSON='{"used":536870912,"total":1073741824}'
    run show_storage_usage "$LOG_FILE" "drive:"
    [[ "$output" =~ 512(\.00)?\ MiB\ /\ 1(\.00)?\ GiB ]]
}

@test "show_storage_usage prints nothing when total is 0" {
    export MOCK_RCLONE_ABOUT_JSON='{"used":0,"total":0}'
    run show_storage_usage "$LOG_FILE" "drive:"
    [[ "$output" != *"Drive:"* ]]
}

@test "show_storage_usage warns when rclone about fails" {
    export MOCK_RCLONE_ABOUT_EXIT=1
    run show_storage_usage "$LOG_FILE" "drive:"
    [[ "$output" == *"Could not retrieve storage information"* ]]
}
