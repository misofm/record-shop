#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

check_failure() {
    fixture=$1
    expected=$2
    output_file=$(mktemp)

    if sui move build --path "$repo_dir/fixtures/privacy/$fixture" >"$output_file" 2>&1; then
        echo "error: privacy fixture '$fixture' unexpectedly compiled" >&2
        rm -f "$output_file"
        return 1
    fi

    if ! grep -F "$expected" "$output_file" >/dev/null; then
        echo "error: privacy fixture '$fixture' failed for an unexpected reason" >&2
        sed -n '1,160p' "$output_file" >&2
        rm -f "$output_file"
        return 1
    fi

    rm -f "$output_file"
    echo "ok: external $fixture construction is rejected"
}

check_failure pack "Struct 'miso_record_shop::witness::Witness' can only be instantiated within its defining module"
check_failure new "Invalid call to 'public(package)' visible function 'miso_record_shop::witness::new'"
