#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:-gate-replay}
case_dir=examples/earthquakes
train=$case_dir/training
mkdir "$out"
approved=$(tr -d '\r\n' < "$case_dir/approved.sha256")
./orderkey compare-layouts --input "$train/input.jsonl" --source-contract "$train/source.json" \
    --queries "$train/layout-workload.json" --candidate "$train/target.json" \
    --out "$out/selection" > "$out/comparison.stdout"
./orderkey build-selected --input "$train/input.jsonl" --source-contract "$train/source.json" \
    --queries "$train/layout-workload.json" --selection "$out/selection" \
    --out "$out/delivery" > "$out/build.stdout"
./orderkey gate-selected --selection "$out/selection" --selection-sha256 "$approved" \
    --batches "$case_dir/near.json" --delivery "$out/delivery" --out "$out/near"
status=0
./orderkey gate-selected --selection "$out/selection" --selection-sha256 "$approved" \
    --batches "$case_dir/late.json" --delivery "$out/delivery" --out "$out/late" || status=$?
test "$status" -eq 1
./orderkey verify-delivery --out "$out/delivery" --selection-sha256 "$approved" > "$out/delivery-open.json"
printf 'Replay complete. Reports in %s\n' "$out"
