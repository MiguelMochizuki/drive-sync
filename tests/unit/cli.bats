#!/usr/bin/env bats

load '../test_helper'

setup() {
    common_setup
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/cli.sh"
}

teardown() {
    common_teardown
}

@test "show_usage prints a short synopsis" {
    run show_usage
    [[ "$output" == *"USAGE:"* ]]
    [[ "$output" == *"drive-sync.sh [COMMAND] [OPTIONS]"* ]]
}

@test "show_usage is shorter than show_help" {
    usage_lines="$(show_usage | wc -l)"
    help_lines="$(show_help | wc -l)"
    [ "$usage_lines" -lt "$help_lines" ]
}

@test "show_help still lists every command" {
    run show_help
    [[ "$output" == *"push"* ]]
    [[ "$output" == *"pull"* ]]
    [[ "$output" == *"sync"* ]]
    [[ "$output" == *"status"* ]]
    [[ "$output" == *"ratelimit"* ]]
}

@test "show_help lists correct options with -v/-V" {
    run show_help
    [[ "$output" == *"-v, --verbose"* ]]
    [[ "$output" == *"-V, --version"* ]]
}
