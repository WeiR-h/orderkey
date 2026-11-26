#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:-bounded-selection-replay}
fixture=examples/bounded-selection
train=$fixture/training
late=$fixture/late
mkdir -- "$out"

compare() {
    cap=$1
    result=$2
    shift 2
    ./orderkey compare-layouts --input "$train/input.jsonl" --source-contract "$train/source.json" \
        --queries "$train/workload-$cap.json" --candidate "$train/target.json" \
        --out "$out/$result" "$@" > "$out/$result.stdout"
}
compare 4 legacy
compare 3 selection-3 --scan-mode bounded
compare 4 selection-4 --scan-mode bounded
printf 'Compared the same layouts using the single range and both dual budgets.\n'

build_training() {
    exec ./orderkey build-selected --input "$train/input.jsonl" --source-contract "$train/source.json" \
        --queries "$train/workload-4.json" --selection "$out/selection-4" \
        --out "$out/training-index" "$@"
}
(
    build_training --pause-after selected-workload
) > "$out/interruption.stdout" 2> "$out/interruption.stderr" &
child=$!
trap 'kill -KILL "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :' 0
ticks=0
until grep -qx 'paused selected-workload' "$out/interruption.stdout"; do
    if ! kill -0 "$child" 2>/dev/null || [ "$ticks" -ge 30 ]; then
        printf 'Training build did not reach the workload checkpoint\n' >&2
        exit 2
    fi
    sleep 1
    ticks=$((ticks + 1))
done
kill -KILL "$child"
if wait "$child" 2>/dev/null; then
    printf 'Training build finished before interruption\n' >&2
    exit 2
fi
trap - 0
approved=$(tr -d '\r\n' < "$fixture/approved-4.sha256")
if ./orderkey verify-delivery --out "$out/training-index" --selection-sha256 "$approved" \
    > "$out/incomplete.stdout"; then
    printf 'Incomplete delivery was accepted\n' >&2
    exit 2
fi
(build_training --resume) > "$out/resume.stdout"
./orderkey verify-delivery --out "$out/training-index" --selection-sha256 "$approved" > "$out/training-ready.json"
printf 'Terminated the training build before workload verification, rejected it, then resumed it.\n'

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
gate 4 cap-4
gate 4 other-approval
receipt=$out/cap-4/batch-receipt.json
other=$out/other-approval/batch-receipt.json
hash=$(sha256sum < "$receipt")
other_hash=$(sha256sum < "$other")
printf '%s\n' "${hash%% *}" > "$out/receipt.sha256"
printf '%s\n' "${other_hash%% *}" > "$out/other.sha256"
./approved-consumer "$out/late-index" "$receipt" "${hash%% *}" bounded \
    "$other" "${other_hash%% *}" > "$out/consumer.json"
printf 'Late batch rejected at 3 ranges and approved at 4 ranges. Read 593 rows. Reports in %s\n' "$out"
