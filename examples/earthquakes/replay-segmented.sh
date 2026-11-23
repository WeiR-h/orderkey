#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${1:-segmented-replay}
fixture=examples/earthquakes
late=$fixture/late
mkdir "$out"
sh replay-gate.sh "$out/baseline"
approved=$(tr -d '\r\n' < "$fixture/approved.sha256")
./orderkey explain --where "$late/where.json" --source-contract "$late/source.json" \
    --target-contract "$late/target.json" > "$out/diagnosis.json"
./orderkey gate-selected --selection "$out/baseline/selection" --selection-sha256 "$approved" \
    --batches "$fixture/late.json" --delivery "$out/baseline/delivery" \
    --scan-mode segmented --out "$out/repaired"
./orderkey build --input "$late/input.jsonl" --source-contract "$late/source.json" \
    --target-contract "$late/target.json" --out "$out/late-index" > "$out/build.stdout"
./orderkey check-queries --out "$out/late-index" --queries "$late/layout-workload.json" \
    --scan-mode segmented --report "$out/measured.json" > "$out/check.stdout"
./orderkey query --out "$out/late-index" --where "$late/where.json" \
    --scan-mode segmented --limit 50 > "$out/read.json"
printf 'Segmented replay complete. Reports in %s\n' "$out"
