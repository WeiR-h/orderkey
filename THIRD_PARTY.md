# Third-party code and data

OrderKey core is an independent MIT-licensed implementation. Design references are [FoundationDB Tuple Layer](https://apple.github.io/foundationdb/data-modeling.html) (FoundationDB source is Apache-2.0) and [Google orderedcode](https://github.com/google/orderedcode) (Apache-2.0). Their wire formats are separate from OrderKey v1.

The native tool and examples reuse the following packages.

| Package | Version | License | Purpose |
| --- | --- | --- | --- |
| [MoonLSM](https://github.com/PingGuoMiaoMiao/moonlsm) | 0.3.2 | MIT | NativeStorage, WAL and sorted tables |
| [MoonFST](https://github.com/starAndHonor/moonfst) | 0.1.1 | MIT | Immutable ordered-key snapshots |
| [MoonBit async](https://github.com/moonbitlang/async) | 0.22.9 | Apache-2.0 | File operations and process locks |
| [SHA-256](https://github.com/gmlewis/moonbit-sha256) | 0.18.2 | Apache-2.0 | Incremental checksums |
| [base64](https://github.com/gmlewis/moonbit-base64) | 0.16.14 | Apache-2.0 | Transitive SHA-256 dependency |

MoonLSM and MoonFST are dependencies and their implementation remains attributed to their authors. The small UTF-8 working-directory bridge is OrderKey code used only around synchronous MoonLSM operations.

SQLite and Python are independent verification tools. NOAA GHCNd observations are distributed under the [NCEI open data policy](https://www.ncei.noaa.gov/sites/default/files/2023-12/NCEI%20PD-10-2-02%20-%20Open%20Data%20Policy%20Signed.pdf). The original CSV, endpoint and checksum are described in README.md.

Release packaging copies the actual dependency license files into the third-party-licenses directory. MoonBit's bundled runtime and standard library retain the toolchain's license notices.
