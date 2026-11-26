# OrderKey v0.1.22 技术验收摘要

维护有序 KV 二级索引时，同一个业务查询可以继续返回完全相同的记录，扫描开销却突破预算。OrderKey 从冻结的查询和导出选型，重建候选，验收实际末批快照，再由独立消费方按批准回执读取。

## 从双预算选型到末批读取

Windows 解压后运行 `replay-bounded-selection.cmd`，Linux 运行 `sh replay-bounded-selection.sh`。
USGS 两周冻结训练集有 1,021 条记录，前三周末批有 1,516 条。两批锁定同一跨网络查询与 650 条扫描预算。
训练批按单段比较时，原布局需 1,021 条、候选需 1,011 条，判定无可行布局。

| 区间上限 | 训练批原布局 → 候选 | 末批原布局 → 候选 | 末批判定 |
|---:|---:|---:|---|
| 3 | 634 → 624 | 688 → 673 | 拒绝 |
| 4 | 623 → 613 | 661 → 646 | 通过 |

训练批经过真实进程中断，未完成业务验收的交付被拒绝。
按原 v2 选型恢复后，MoonLSM 与 MoonFST 均扫描 613 条，结果与干净重建一致。
末批重新规划区间，两引擎实测 673 和 646。独立消费端分 20 页读回 593 条，顺序和载荷与 SQLite 一致。
发布包包含测试、可复现演示及 SHA-256 校验值。 [双平台发行包与报告](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.22)

## v0.1.19 双预算回归

解压后运行 `replay-bounded.cmd` 或 `sh replay-bounded.sh`。冻结的 USGS 末批含 1,516 条记录。
按事件类型筛选并读取同一周的全球记录，单区间候选基线为 1,501，查询实际命中 593 条。

| 区间上限 | 独立穷举下界 | MoonLSM | MoonFST | 650 条预算 |
|---|---:|---:|---:|---|
| 3 | 673 | 673 | 673 | 拒绝 |
| 4 | 646 | 646 | 646 | 通过 |

先裁去首尾的未匹配键。额外的一个区间可以跳过一个连续空隙，选择最大的空隙即可使候选量最小。
预测以完整冻结键为依据。报告同时记录谓词检查的键数，区间预算按整次读取的不同逻辑区间计算。
SDK 校验 v2 回执后按已批准区间读出 20 页，顺序与载荷逐条对照 SQLite。
同一快照的第二份有效回执会拒绝第一份回执的游标。 [双平台程序与报告](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.19)

## v0.1.16 回归复验

解压发行包后，Windows 执行 `replay-approved.cmd`，Linux 执行 `sh replay-approved.sh`。结果保存在 `approved-replay`。 [下载程序、演示和双平台报告](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.16)

| 检查 | USGS ComCat 案例实测 | 证据 |
|---|---|---|
| 单段扫描 | 末批 1,516 条目录记录。原查询命中 33 条，双引擎扫描 71 条，超过 50 条预算 | `single/batch-receipt.json` |
| 分段扫描 | 同一候选和查询。预测、MoonLSM 和 MoonFST 均扫描 33 条，通过预算 | `segmented/batch-receipt.json` |
| 独立读取 | 使用绑定谓词、模式和页大小，返回 7、7、7、7、5 条。SQLite 对照载荷和返回次序 | `consumer.json`、`verification/approved-consumer-report.json` |
| 错发快照 | 近批常规查询也得到完全一致的 33 条。用末批回执打开时因清单摘要不一致而拒绝 | `wrong.stderr` |

回执绑定原选型、冻结输入、契约、查询和候选清单。SDK 校验从可信发布配置获得的回执 SHA-256。续页游标绑定回执、快照与查询。候选扫描量按引擎返回的候选记录数计算，报告用于冻结样本的离线复验，应用负责生产切换。 [数据来源](https://github.com/WeiR-h/orderkey/blob/v0.1.16/examples/earthquakes/SOURCE.md)

核心编码、查询和 SDK 使用 MoonBit，核心仅依赖标准库。验收保留四后端兼容、10 万条选型对照、文件恢复和历史回归。源码使用 MIT 许可证，发行包附第三方许可证和数据出处。
