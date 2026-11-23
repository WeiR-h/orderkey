# OrderKey v0.1.16 技术验收摘要

维护有序 KV 二级索引时，同一个业务查询可以继续返回完全相同的记录，扫描开销却突破预算。OrderKey 从冻结的查询和导出选型，重建候选，验收实际末批快照，再由独立消费方按批准回执读取。

## 一键复验

解压发行包后，Windows 执行 `replay-approved.cmd`，Linux 执行 `sh replay-approved.sh`。结果保存在 `approved-replay`。 [下载程序、演示和双平台报告](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.16)

| 检查 | USGS ComCat 案例实测 | 证据 |
|---|---|---|
| 单段扫描 | 末批 1,516 条目录记录。原查询命中 33 条，双引擎扫描 71 条，超过 50 条预算 | `single/batch-receipt.json` |
| 分段扫描 | 同一候选和查询。预测、MoonLSM 和 MoonFST 均扫描 33 条，通过预算 | `segmented/batch-receipt.json` |
| 独立读取 | 使用绑定谓词、模式和页大小，返回 7、7、7、7、5 条。SQLite 对照载荷和返回次序 | `consumer.json`、`verification/approved-consumer-report.json` |
| 错发快照 | 近批常规查询也得到完全一致的 33 条。用末批回执打开时因清单摘要不一致而拒绝 | `wrong.stderr` |

回执绑定原选型、冻结输入、契约、查询和候选清单。SDK 校验从可信发布配置获得的回执 SHA-256。续页游标绑定回执、快照与查询。候选扫描量按引擎返回的候选记录数计算，报告用于冻结样本的离线复验，应用负责生产切换。 [数据来源](https://github.com/WeiR-h/orderkey/blob/v0.1.16/examples/earthquakes/SOURCE.md)

核心编码、查询和 SDK 使用 MoonBit，核心仅依赖标准库。验收保留四后端兼容、10 万条选型对照、文件恢复和历史回归。源码使用 MIT 许可证，发行包附第三方许可证和数据出处。
