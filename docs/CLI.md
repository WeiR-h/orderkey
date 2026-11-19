> v0.1.0 提供布局比较、自动推荐和验收。 [布局选型指南](LAYOUTS.md) · [字段查询和快照 SDK](QUERIES.md)

# Native file tool

Download the matching Windows x64 or Linux x64 archive from GitHub Releases and unpack it. Windows uses orderkey.exe and Linux uses orderkey. The examples below use orderkey. Python is needed for the acceptance scripts, and Node.js for the historical JS fixtures.

Source builds use MoonBit, Python 3.10+, and an MSVC-compatible C toolchain on Windows or a C compiler on Linux.

~~~sh
moon update
python scripts/build.py
python scripts/verify_cli.py --report cli-report.json
python scripts/benchmark.py --report benchmark.json
~~~

## Export and contracts

Input is UTF-8 JSONL. Each row has two hexadecimal strings. All input keys must be complete keys under the source contract. Input order is arbitrary, while duplicate keys are rejected. The default maximum is 100,000 rows, 64 MiB per file, and 1 MiB per row. Empty exports are supported.

~~~json
{"key_hex":"6100008000000000000000","value_hex":"76616c7565"}
~~~

Contracts can be the existing binary OKC01 descriptors or JSON. JSON IDs are encoded as UTF-8 bytes. Generations use decimal strings to preserve all UInt64 values.

~~~json
{"index_id":"example","generation":"1","fields":[{"id":"name","kind":"bytes","direction":"asc"},{"id":"time","kind":"int64","direction":"asc"}]}
~~~

The target uses the same index ID and field ID/type set, and a newer generation. Reordering fields and changing directions are supported.

~~~sh
orderkey plan --input input.jsonl --source-contract source.json --target-contract target.json
orderkey build --input input.jsonl --source-contract source.json --target-contract target.json --out candidate
orderkey verify --out candidate
orderkey query --out candidate --limit 5
orderkey resume --out candidate
~~~

## Candidate files and queries

The directory contains source.contract, target.contract, db/, target.fst, records.jsonl, plan.json, checkpoint.json, manifest.json and report.json. The original input and contract paths are captured for verify and resume. Query can consume a copied candidate without the original input files.

The database stores a 01 data prefix. Exported records and FST keys keep the original v1 byte encoding. records.jsonl is in target key order and FST values are its zero-based ordinals.

Queries use optional --start-hex and --end-hex half-open byte bounds. An omitted end is infinite. --cursor accepts the previous response's cursor while keeping the original bounds. Cursor scopes include the target contract and the snapshot's input/key/value identity. Applications exposing cursors authenticate them.

Query checks the verified receipt and every candidate file digest before reading. Native engine verification uses a private database copy because opening MoonLSM can modify its metadata.

## Recovery and failure states

A job is locked for each operation. A second writer or reader of a busy job fails immediately. A new build requires a fresh directory. Resume checks the original input and contracts, then hashes the completed stage. An unfinished database stage is restarted, preserving the previous attempt in abandoned-db-N. An unfinished snapshot is regenerated. Verification runs again before ready becomes true.

Failures write ready=false and an error into report.json. Keep the original inputs available and frozen through build, verify and resume. A mismatch in an already checkpointed file is reported rather than overwritten.

The fault harness supports --fail-after writing|database|snapshot|verified|complete, --fail-io write|sync, and --pause-after with a stage name. A pause prints its stage and waits 30 seconds so the harness can terminate the real process. --fail-io invokes an actual failing write/sync inside the newly created database.

The recovery contract covers process interruption and explicit IO errors. It relies on the filesystem and storage engine for media durability.
