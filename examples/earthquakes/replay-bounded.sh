#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:-bounded-replay}
fixture=examples/bounded
train=$fixture/training
late=$fixture/late
mkdir -- "$out"
for cap in 3 4; do
    ./orderkey compare-layouts --input "$train/input.jsonl" --source-contract "$train/source.json" \
        --queries "$train/workload-$cap.json" --candidate "$train/target.json" \
        --out "$out/selection-$cap" > "$out/selection-$cap.stdout"
done
./orderkey build --input "$late/input.jsonl" --source-contract "$late/source.json" \
    --target-contract "$out/selection-4/target.contract" --out "$out/late-index" > "$out/build.stdout"
gate() {
    cap=$1
    approval=$(tr -d '\r\n' < "$fixture/approved-$cap.sha256")
    ./orderkey gate-batch --selection "$out/selection-$cap" --selection-sha256 "$approval" \
        --batches "$fixture/batches-$cap.json" --batch-id late --delivery "$out/late-index" \
        --scan-mode bounded --out "$out/$2" > "$out/$2.stdout"
}
status=0
gate 3 cap-3 || status=$?
[ "$status" -eq 1 ]
printf 'Three-window plan rejected. See %s/cap-3/batch-receipt.json\n' "$out"
gate 4 cap-4
gate 4 other-approval
receipt=$out/cap-4/batch-receipt.json
other=$out/other-approval/batch-receipt.json
hash=$(sha256sum < "$receipt")
other_hash=$(sha256sum < "$other")
printf '%s\n' "${hash%% *}" > "$out/receipt.sha256"
./approved-consumer "$out/late-index" "$receipt" "${hash%% *}" bounded \
    "$other" "${other_hash%% *}" > "$out/consumer.json"
printf 'Four-window plan approved. Read 593 rows and rejected a cross-receipt cursor. Reports in %s\n' "$out"
