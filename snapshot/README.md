# OrderKey snapshot reader

Native MoonBit reader for verified, portable OrderKey candidates. The full repository includes docs/QUERIES.md with query and SDK examples. Package using `python scripts/package_snapshot.py` from the repository root: the parent module excludes snapshot/ from the core package, so SDK packaging uses an isolated stage.

Import `WeiR-h/orderkey_snapshot` and `WeiR-h/orderkey`. `Reader::open(directory)` validates and loads once. `Reader::query(QuerySpec, limit~, cursor~)` performs typed pagination with no further filesystem access. `Page` exposes rows, scanned and optional cursor. Data stays frozen for the session; new readers validate files again.

Use `Reader::open_selected(directory, expected_selection_sha256=...)` to verify a selected training delivery. A bounded delivery carries its original v2 `selection.json` and measured rank ranges. The reader checks the selection digest, scan mode, budgets and ranges against the delivery.

A cross-batch rebuild carries `assessment.json`. The reader checks the copy against the assessment digest in the job receipt. A holdout receipt from `gate-batch` carries the approved assessment and holdout key-set digests and can be read through the existing approved reader.

Use `ApprovedReader::open(directory, receipt, expected_sha256)` for a snapshot approved by `gate-batch`. Supply the receipt digest from trusted release configuration. Call `reader.query(id, predicate, cursor~)` with the approved query ID and typed predicate. The receipt supplies the scan mode and page size. The example in `examples/approved` reads an approved USGS snapshot after the original exports have been removed.

This module depends on MoonFST (MIT), async and sha256 (Apache-2.0). It does not open MoonLSM. The core module remains standard-library-only. MIT license; reference and dependency notices are in the repository THIRD_PARTY.md. No independent user adoption is claimed.
