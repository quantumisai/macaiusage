#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

# Some Command Line Tools releases include Swift Testing but do not add their
# framework and runtime directories to SwiftPM's default search paths.
developer_dir="$(xcode-select --print-path)"
frameworks_dir="$developer_dir/Library/Developer/Frameworks"
runtime_dir="$developer_dir/Library/Developer/usr/lib"
if [[ "$developer_dir" == */CommandLineTools && -d "$frameworks_dir/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks_dir" \
        -Xlinker "-F$frameworks_dir" \
        -Xlinker -rpath -Xlinker "$frameworks_dir" \
        -Xlinker -rpath -Xlinker "$runtime_dir" \
        "$@"
fi

exec swift test "$@"
