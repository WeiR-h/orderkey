#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:-batch-selection-replay}
fixture=examples/batch-selection
inputs=$out/inputs
train=$inputs/training
mkdir -- "$out"
mkdir -- "$inputs"
cp -R -- "$fixture/training" "$fixture/middle" "$inputs"
cp -- "$fixture/assessment-3.json" "$fixture/assessment-4.json" "$inputs"
chmod u+x ./orderkey ./approved-consumer

./orderkey compare-layouts --input "$train/input.jsonl" --source-contract "$train/source.json" \
    --queries "$train/workload-4.json" --candidate "$train/target.json" --scan-mode bounded \
    --out "$out/first-week" > "$out/first-week.stdout"
for cap in 3 4; do
    ./orderkey compare-batches --batches "$inputs/assessment-$cap.json" --anchor middle \
        --candidate "$train/target.json" --out "$out/selection-$cap" > "$out/selection-$cap.stdout"
done
printf 'Compared one week and two assessed batches. The third-week export is still withheld.\n'

approved() {
    tr -d '\r\n' < "$fixture/approved-$1-$2.sha256"
}
build_anchor() {
    exec ./orderkey build-selected --input "$inputs/middle/input.jsonl" --source-contract "$train/source.json" \
        --queries "$train/workload-4.json" --selection "$out/selection-4" \
        --assessment-batches "$inputs/assessment-4.json" --assessment-sha256 "$(approved assessment 4)" \
        --out "$out/anchor-index" "$@"
}
(build_anchor --pause-after selected-workload) > "$out/interruption.stdout" 2> "$out/interruption.stderr" &
child=$!
trap 'kill -KILL "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :' 0
ticks=0
until grep -qx 'paused selected-workload' "$out/interruption.stdout"; do
    if ! kill -0 "$child" 2>/dev/null || [ "$ticks" -ge 30 ]; then
        printf 'Anchor build did not reach the workload checkpoint\n' >&2
        exit 2
    fi
    sleep 1
    ticks=$((ticks + 1))
done
kill -KILL "$child"
if wait "$child" 2>/dev/null; then exit 2; fi
trap - 0
if ./orderkey verify-delivery --out "$out/anchor-index" --selection-sha256 "$(approved selection 4)" \
    > "$out/incomplete.stdout"; then
    printf 'Incomplete delivery was accepted\n' >&2
    exit 2
fi
(build_anchor --resume) > "$out/resume.stdout"
./orderkey verify-delivery --out "$out/anchor-index" --selection-sha256 "$(approved selection 4)" \
    > "$out/anchor-ready.json"
printf 'Terminated the anchor build, rejected the incomplete delivery, then resumed the approved layout.\n'

mkdir -- "$inputs/late"
cp -- "$fixture/withheld/input.jsonl" "$inputs/late/input.jsonl"
cp -- "$fixture/holdout-3.json" "$fixture/holdout-4.json" "$inputs"
./orderkey build --input "$inputs/late/input.jsonl" --source-contract "$train/source.json" \
    --target-contract "$out/selection-4/target.contract" --out "$out/late-index" > "$out/build.stdout"
gate() {
    ./orderkey gate-batch --selection "$out/selection-$1" --selection-sha256 "$(approved selection "$1")" \
        --assessment-sha256 "$(approved assessment "$1")" --batches "$inputs/holdout-$1.json" \
        --batch-id late --delivery "$out/late-index" --scan-mode bounded --out "$out/$2" > "$out/$2.stdout"
}
status=0
gate 3 cap-3 || status=$?
[ "$status" -eq 1 ]
gate 4 cap-4
gate 4 other-approval
receipt="$out/cap-4/batch-receipt.json"
other="$out/other-approval/batch-receipt.json"
hash=$(sha256sum < "$receipt")
other_hash=$(sha256sum < "$other")
printf '%s\n' "${hash%% *}" > "$out/receipt.sha256"
printf '%s\n' "${other_hash%% *}" > "$out/other.sha256"
./approved-consumer "$out/late-index" "$receipt" "${hash%% *}" bounded \
    "$other" "${other_hash%% *}" > "$out/consumer.json"
printf 'The holdout was rejected at 3 ranges and approved at 4 ranges. Reports in %s\n' "$out"
