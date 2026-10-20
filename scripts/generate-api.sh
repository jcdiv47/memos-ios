#!/bin/sh
# Regenerates MemosKit/Sources/MemosAPI/Generated from proto/api/*.proto.
#
#   scripts/generate-api.sh            # regenerate from the vendored protos
#   scripts/generate-api.sh ~/memos    # copy protos from a memos checkout first
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -gt 0 ]; then
    upstream="$1"
    cp "$upstream"/proto/api/*.proto "$root/proto/api/"
    cp "$upstream"/proto/buf.yaml "$upstream"/proto/buf.lock "$root/proto/"
    git -C "$upstream" rev-parse HEAD > "$root/proto/UPSTREAM_COMMIT"
fi

rm -rf "$root/MemosKit/Sources/MemosAPI/Generated"
cd "$root/proto"
buf generate
