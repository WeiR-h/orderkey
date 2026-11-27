# 约 90 秒演示

## v0.2.0 跨批选型与留出验收

解压发行包。Windows 运行 `replay-batch-selection.cmd`，Linux 运行 `sh replay-batch-selection.sh`。默认把结果写到 `batch-selection-replay`，也可传入一个新的输出目录。

| 时间 | 展示 | 现场证据 |
|---|---|---|
| 0–15 秒 | 首周两个布局都扫 593 条，单批选型保留源布局 | `first-week/comparison.json` |
| 15–35 秒 | 加入前两周的导出，4 区间时源布局最差 623 条，候选 613 条 | `selection-4/comparison-batches.json` |
| 35–55 秒 | 真实终止重建，拒绝未完成交付，按批准摘要恢复 | `interruption.stdout`、`incomplete.stdout`、`anchor-ready.json` |
| 55–75 秒 | 导入三周留出数据。3 区间实测 673 条超预算，4 区间实测 646 条通过 | 两份 `batch-receipt.json` |
| 75–90 秒 | SDK 分 20 页读出 593 条，跨回执续页被拒绝 | `consumer.json` |

演示使用随包分发的批准摘要。完整 SQLite 对照与异常验收见 `verification/batch-selection-report.json`。规模对照见 `verification/batch-layout-benchmark.json`。 [下载程序、报告及演示](https://github.com/WeiR-h/orderkey/releases/tag/v0.2.0)

## v0.1.22 从选型、恢复到批准读取

解压发行包后，Windows 运行 `replay-bounded-selection.cmd`，Linux 运行 `sh replay-bounded-selection.sh`。
默认输出到 `bounded-selection-replay`，可传入一个新目录名。

| 时间 | 展示 | 证据 |
|---|---|---|
| 0–15 秒 | 两周训练批中的单段选型报无可行布局 | `legacy/comparison.json` |
| 15–32 秒 | 相同数据按两个预算选型，4 区间候选扫描预测为 613 | `selection-4/selection.json` |
| 32–55 秒 | 终止重建进程，严格交付拒绝，使用同一选型恢复 | `interruption.stdout`、`incomplete.stdout`、`training-ready.json` |
| 55–75 秒 | 重建第三周末批，3 区间扫描 673 条超限，4 区间扫描 646 条通过 | 两份 `batch-receipt.json` |
| 75–90 秒 | SDK 分 20 页读取 593 条，与 SQLite 一致，跨回执续页被拒绝 | `consumer.json` |

发行包中的 `verification/bounded-selection-report.json` 含 SQLite 与双引擎结果以及恢复和异常检查。
演示使用发行包内预置的选型摘要。应用部署时通过可信配置交接摘要。 [下载与双平台报告](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.22)

## v0.1.19 在两个预算内读取同一快照

解压发行包，Windows 运行 `replay-bounded.cmd`，Linux 运行 `sh replay-bounded.sh`。
默认把证据写入 `bounded-replay`。可传入一个新目录名重新复验。

| 时间 | 展示 | 证据 |
|---|---|---|
| 0–18 秒 | 1,516 条冻结记录，跨网络查询命中 593 条，候选预算 650 条 | `late-index/manifest.json` |
| 18–36 秒 | 3 个逻辑区间至少扫描 673 条，MoonLSM 与 MoonFST 实测一致，验收拒绝 | `cap-3/batch-receipt.json` |
| 36–56 秒 | 4 个逻辑区间将候选降到 646 条，验收通过 | `cap-4/batch-receipt.json` |
| 56–74 秒 | SDK 从批准的区间读完 20 页，载荷和次序与 SQLite 一致 | `consumer.json` |
| 74–90 秒 | 用同一快照的另一份有效回执继续读第一页游标，SDK 拒绝 | `consumer.json` 中的 `cross_receipt_cursor_rejected` |

两份选型分别锁定 3 和 4 的区间预算。演示用本地计算的回执摘要交接。
实际发布时，由可信发布配置传递批准的 SHA-256。 [下载与双平台报告](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.19)

## v0.1.16 验收并读取同一份快照

解压对应平台 ZIP。Windows 运行 `replay-approved.cmd`，Linux 运行
`sh replay-approved.sh`。默认输出到 `approved-replay`，也可传入一个新的目录名。

| 时间 | 展示 | 复验证据 |
|---|---|---|
| 0–14 秒 | 从冻结输入重建 USGS 末批的 1,516 条记录 | `late-index/manifest.json` |
| 14–30 秒 | 单段扫描 71 条，超过 50 条预算，实际候选被拒绝 | `single/batch-receipt.json` |
| 30–48 秒 | 同一候选分段扫描 33 条，MoonLSM 和 MoonFST 与预测一致 | `segmented/batch-receipt.json` |
| 48–65 秒 | SDK 用回执绑定的页大小读完 33 条，SQLite 核对顺序和内容 | `consumer.json` |
| 65–80 秒 | 换入同样返回 33 条的近批快照，回执清单身份不匹配 | `wrong.stderr` |
| 80–90 秒 | 核对发布提交和两平台复验报告 | `verification/acceptance.json` |

`receipt.sha256` 让演示命令可以在本机交接回执。实际发布时，通过独立可信配置传递该摘要。
参见 [双平台程序、演示与校验值](https://github.com/WeiR-h/orderkey/releases/tag/v0.1.16)。

## v0.1.12 分段扫描复验

解压对应平台 ZIP 后，Windows 运行 `replay-segmented.cmd`，Linux 运行 `sh replay-segmented.sh`。
默认输出目录是 `segmented-replay`，也可传入一个新的目录名。

| 时间 | 展示 |
|---|---|
| 0–20 秒 | 原单段查询在末批读取 71 条，超过 50 条预算，发布判定返回退化。 |
| 20–40 秒 | `diagnosis.json` 指出事件类型列阻挡时间下推。 |
| 40–65 秒 | 在完整冻结键表中枚举可用类型前缀，逐段读取时间窗口，扫描降至 33。 |
| 65–90 秒 | 核对 `repaired/gate-report.json` 的预测和 `measured.json` 的双引擎实测。33 条记录的顺序与 SQLite 一致。 |

## v0.1.8 评审复验

解压对应平台 ZIP 后，在目录里运行 `replay-gate.cmd`（Windows）或 `sh replay-gate.sh`（Linux）。
可传入一个新的输出目录作为第一个参数，默认是 `gate-replay`。

| 时间 | 展示 |
|---|---|
| 0–20 秒 | 看初选报告，源扫描 599 条。换成网络前导布局后扫描 33 条。 |
| 20–45 秒 | 打开后续批次报告。查询和预算锁定，45 条扫描通过 50 条预算。 |
| 45–70 秒 | 后续一批命中仍为 33 条，扫描 71 条。展示拒绝报告和超预算 21 条。 |
| 70–90 秒 | 核对交付快照的严格打开结果，展示 MoonLSM、MoonFST、SQLite 的对照证据。 |

报告位于 `gate-replay/selection/comparison.json`、`gate-replay/near/gate-report.json` 和 `gate-replay/late/gate-report.json`。
严格交付复核写到 `gate-replay/delivery-open.json`。发行包内 `verification/earthquakes-report.json` 保存两引擎实测与结果序列摘要。

## v0.1.4 跨批审查演示

从 Windows 或 Linux 压缩包解压到新目录。用 [业务查询与跨批审查](WORKLOADS.md) 中的命令事先准备三个案例。报告与程序由同一源码提交生成。

| 时间 | 展示 |
|---|---|
| 0–20 秒 | 运行天气应用的真实查询入口。终端显示原始记录，查询记录交给 `collect-queries` 后得到谓词、扫描预算和调用频次。 |
| 20–45 秒 | 展示冻结批次的跨批审查。设备查询仍命中 180 条，扫描从 1,230 增至 1,590，超过 1,500 条预算。两个引擎与 SQLite 核对结果。 |
| 45–70 秒 | 打开验收中断后的快照，`verify-delivery` 拒绝。恢复并完成验收后，复制到新目录。天气应用从快照分五条一页查询出 29 条。 |
| 70–90 秒 | 展示两个 NOAA 批次的 31 条和 29 条结果，以及十万条、八候选、20 查询的逐查询报告。比较阶段 0 次重建，执行阶段 1 次。 |

源码完整复验运行 `python scripts/acceptance.py`，报告写入 `_build/acceptance`。演示中的实际进程中断和恢复由 `scripts/verify_delivery.py` 复现。Windows 和 Linux 上的解压复验覆盖天气采集、独立快照、后续批次与遥测回归。

## v0.1.0 布局选型演示

准备解压两组案例，终端 A 跑对比，终端 B 打开验收报告。命令在 [布局选型指南](LAYOUTS.md)。

| 时间 | 展示 |
|---|---|
| 0–15 秒 | 同一份遥测导出和固定的业务查询。当前布局的跨租户设备查询扫 9,840 条。 |
| 15–35 秒 | 运行 `compare-layouts --auto`。设备前置后预计扫描 1,230 条，保留查询顺序。 |
| 35–55 秒 | 替换为冲突查询集。分别显示源布局和设备前置布局违反的预算，目录只留下对照报告。 |
| 55–75 秒 | 对推荐方案运行 `build-selected`。验收报告对照 1,230 条实测、18 条历史命中与快照分页。 |
| 75–90 秒 | 展示天气快照的 29 条和十万条规模报告。用 8 次与 1 次重建说明对比放在前面的收益。 |

## v0.0.18 基线演示

提前构建，运行 `python scripts/demo_queries.py --out _build/query-demo`。演示报告位于该目录的 demo-report.json；目录必须是新的。恢复演示单独运行 `python scripts/demo.py --out _build/recovery-demo`。

| 时间 | 展示 | 说明 |
|---|---|---|
| 0–15 秒 | source.json / target.json | tenant、device 都是升序字节串，互换字段时类型布局仍一样；字段身份和代次必须另外保存。 |
| 15–30 秒 | 目标 query 的 18 条记录与游标 | 字段查询免去手写字节边界，分页结果经过 SQLite 独立复核。 |
| 30–50 秒 | rejected.json | 租户查询结果仍为 984 条，但扫描从 984 放大到 9840；预算为 1000，结果正确也不建议切换。 |
| 50–70 秒 | accepted.json | 新代次恢复 tenant 前导布局，扫描回到 984，查询集验收通过。旧代次游标续读被拒绝。 |
| 70–90 秒 | demo-report.json 和 snapshot-report.json | 原输入 SHA-256 前后一致；只读端无原始文件也能查询天气快照，单会话只打开、校验一次。 |

三个完整使用场景分别是设备历史索引换序、租户查询退化审查、天气快照分发。全部是离线演示，生产切换由调用方执行。

技术解释重点：字段身份与物理类型布局的区别；字节范围下推与剩余过滤；为什么源目标排序可能不同但逻辑记录必须一致；为什么验收正确性与扫描预算分开；快照会话和输入冻结边界。

天气应用和独立 SDK 项目提供可复跑的接入示例。
