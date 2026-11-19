# OrderKey snapshot reader

Native MoonBit reader for verified, portable OrderKey candidates. See [query and SDK guide](../docs/QUERIES.md) in the full repository.

Import `WeiR-h/orderkey_snapshot` and `WeiR-h/orderkey`. `Reader::open(directory)` validates and loads once. `Reader::query(QuerySpec, limit~, cursor~)` performs typed pagination with no further filesystem access. `Page` exposes rows, scanned and optional cursor. Data stays frozen for the session; new readers validate files again.

This module depends on MoonFST (MIT), async and sha256 (Apache-2.0). It does not open MoonLSM. The core module remains standard-library-only. MIT license; reference and dependency notices are in the repository THIRD_PARTY.md. No independent user adoption is claimed.
