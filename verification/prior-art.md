# OrderKey 同类能力对照

首轮复查使用 GitHub 和 Mooncakes 的复合键、memcomparable、索引契约、分页、reindex 和 index migration 等关键词。

| 项目 | 输入与输出 | 与本项目的关系 |
|---|---|---|
| [FoundationDB Tuple Layer](https://apple.github.io/foundationdb/data-modeling.html#tuples) | 元组到可排序字节键和前缀区间 | 有序复合键的已有先例 |
| [Flock](https://www.npmjs.com/package/@loro-dev/flock) | 可比较的键部件到有序键，支持范围扫描 | MoonBit 生态里的直接编码先例 |
| [MoonKV](https://mooncakes.io/docs/wallll-wal6/moonkv@0.1.3) | 键前缀、游标与限制条数到下一页 | 已有键值引擎分页 |
| [MigrationLens](https://mooncakes.io/docs/cn-xjr/migration_lens) | PostgreSQL DDL 与执行上下文到迁移审查报告 | 已有面向 SQL 的审查流程 |
| [MoonLSM](https://mooncakes.io/docs/PingGuoMiaoMiao/moonlsm@0.3.2) / [MoonFST](https://mooncakes.io/docs/starAndHonor/fst@0.1.1) | 排序字节键到可变存储或可重载的只读索引 | 本项目的两个验证目标 |

OrderKey 的差异是用显式字段身份与代次约束索引和游标，对冻结记录做重排重编码，再以 SQLite 独立核对重开后的索引。公开查重覆盖已索引的资料。

封版前复查了 Flock 的 memcomparable 键与范围、MoonKV 分页、MigrationLens 的 PostgreSQL 离线审查。在本轮公开检索里，最接近的能力分别来自这些项目。v0.0.8 复验同类型字段交换、旧游标拒绝、离线重建及双引擎和 SQLite 的逐条结果。
