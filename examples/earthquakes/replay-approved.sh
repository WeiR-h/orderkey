#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:-approved-replay}
fixture=examples/earthquakes
train=$fixture/training
mkdir -- "$out"
approved=$(tr -d '\r\n' < "$fixture/approved.sha256")
./orderkey compare-layouts --input "$train/input.jsonl" --source-contract "$train/source.json" \
    --queries "$train/layout-workload.json" --candidate "$train/target.json" \
    --out "$out/selection" > "$out/comparison.stdout"
for batch in late near; do
    ./orderkey build --input "$fixture/$batch/input.jsonl" \
        --source-contract "$fixture/$batch/source.json" \
        --target-contract "$out/selection/target.contract" --out "$out/$batch-index" \
        > "$out/$batch-build.stdout"
done
gate() {
    ./orderkey gate-batch --selection "$out/selection" --selection-sha256 "$approved" \
        --batches "$fixture/late.json" --batch-id late --delivery "$out/late-index" \
        --scan-mode "$1" --out "$out/$1" > "$out/$1.stdout"
}
status=0
gate single || status=$?
[ "$status" -eq 1 ]
printf 'Single range rejected. See %s/single/batch-receipt.json\n' "$out"
gate segmented
printf 'Segmented scan approved. See %s/segmented/batch-receipt.json\n' "$out"
receipt=$out/segmented/batch-receipt.json
sum=$(sha256sum < "$receipt")
trusted=${sum%% *}
printf '%s\n' "$trusted" > "$out/receipt.sha256"
./approved-consumer "$out/late-index" "$receipt" "$trusted" > "$out/consumer.json"
if ./approved-consumer "$out/near-index" "$receipt" "$trusted" > "$out/wrong.stdout" 2> "$out/wrong.stderr"; then
    printf 'Unexpected approval of the near-batch snapshot\n' >&2
    exit 2
fi
grep -q 'snapshot manifest differs from batch receipt' "$out/wrong.stderr"
printf 'Approved 33-row read passed. Wrong snapshot rejected. Reports in %s\n' "$out"
