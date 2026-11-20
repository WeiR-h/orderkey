# OrderKey v0.1.8 技术验收摘要

面向维护有序 KV 二级索引的开发者。交换复合键中的业务字段后，返回的记录可以完全相同，扫描的候选记录却可能增多。OrderKey 用字段 ID、冻结查询和扫描预算给换序后的索引做离线发布判定。

| USGS 冻结导出 | 候选扫描 | 命中 | 发布判定 |
|---|---:|---:|---|
| 初选，599 条目录记录 | 33 | 33 | 选中网络前导布局 |
| 后续一，1,021 条目录记录 | 45 | 33 | 通过 50 条预算 |
| 后续二，1,516 条目录记录 | 71 | 33 | 超预算 21 条，拒绝 |

选型绑定键契约、查询文件和策略摘要。发布命令核对已批准的方案 SHA-256、可重开的交付快照及后续批次。它为业务退化和无效输入提供不同的退出码。后续批次扫描量由有序键范围计算，独立复验重建两批后用 MoonLSM 和 MoonFST 实测，再用 SQLite 核对命中、顺序和分页。

从 Release 下载对应 ZIP。Windows 运行 `replay-gate.cmd`，Linux 运行 `sh replay-gate.sh`。两份判定和快照验证结果位于 `gate-replay`。报告以冻结数据为范围，生产切换由调用方执行。 [发布下载](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.8) · [数据说明](https://github.com/WeiR-h/orderkey/blob/v0.1.8/examples/earthquakes/SOURCE.md)

核心编码和查询逻辑使用 MoonBit。快照 SDK 在独立项目从 Mooncakes 安装后分页读取 33 条。项目使用 MIT 许可证，发行包含依赖许可和数据来源。
