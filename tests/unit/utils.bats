#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/utils.sh"
}

teardown() {
    common_teardown
}

@test "format_size below 1024 bytes uses the B unit" {
    result="$(format_size 999)"
    [ "$result" = "999 B" ]
}

@test "format_size at an exact multiple uses the KiB unit" {
    result="$(format_size 2048)"
    [[ "$result" =~ ^2(\.00)?\ KiB$ ]]
}

@test "format_size at an exact multiple uses the MiB unit" {
    result="$(format_size 3145728)"
    [[ "$result" =~ ^3(\.00)?\ MiB$ ]]
}

@test "format_size at an exact multiple uses the GiB unit" {
    result="$(format_size 2147483648)"
    [[ "$result" =~ ^2(\.00)?\ GiB$ ]]
}
