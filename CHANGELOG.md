# 版本记录

## v0.1.11

- 分段计划进入锁定审查、MoonLSM 与 MoonFST 实测以及发布判定。
- 同一冻结查询和 50 条预算下，末批由单段 71 条被拒绝变为分段 33 条通过。

## v0.1.10

- 快照 SDK 支持可复用的分段查询计划，CLI 用 `query --scan-mode segmented` 显式启用。

## v0.1.9

- 扫描解释列出前缀字段、阻挡区间下推的字段及剩余过滤条件。
- USGS 锁定审查复验末批扫描 71 条、过滤 38 条和超预算 21 条。

## v0.1.8

- 交付 Windows/Linux 一键复验入口、技术验收摘要及约 90 秒演示。
- 双平台从全新解包目录验证通过、拒绝和严格快照打开，记录用时。

## v0.1.7

- 交付 USGS 地震目录案例。固定查询命中 33 条，后续批次分别扫描 45 和 71 条，双引擎与 SQLite 核对一致。
- 增加独立 MoonBit 快照消费示例和数据来源记录。

## v0.1.6

- 新增 `gate-selected`，按已批准的方案摘要复核交付物与后续批次，输出 CI 可读取的发布判定。

## v0.1.5

- 跨批审查新增 `--locked`，按选型方案固定查询、扫描预算和排序策略。

## v0.1.4

- 在解压后的 Windows 和 Linux 发行包中复跑天气应用采集、跨月复核、离线交付及遥测扫描退化。
- 将十万条、八布局基准扩大到 20 个查询，逐条核对预测、两引擎实测及分页。
- 独立 MoonBit 消费者使用严格打开入口分页查询 NOAA 快照。

## v0.1.3

- 复用已选契约审查最多五个后续冻结批次，逐批报告预算或返回顺序退化，不构建数据库。
- 增加保持 180 条命中时扫描量从 1,230 增至 1,590 的回归，用 MoonLSM、MoonFST 和 SQLite 验证。

## v0.1.2

- 从本地业务查询记录生成现有选型格式，合并等价谓词与相同分页参数，保留严格预算和频次。
- 提供独立 NOAA 示例应用，导出观测数据、记录业务查询并重新打开选型快照。

## v0.1.1

- 增加严格交付校验命令和原生 SDK 入口，核对文件、选型任务与业务验收记录。
- 复现业务验收前的进程中断，拒绝未完成回执，验证恢复后可独立交付。

## v0.1.0

- 比较冻结 KV 导出上的源布局与最多八套候选，报告逐查询扫描预算与返回顺序。
- 根据查询生成候选，保留源布局参与排名。仅当新布局入选才生成选型方案。
- 按方案重建一个候选，支持恢复并重新验收。核对 MoonLSM 扫描数、记录及 MoonFST 分页。
- 增加遥测与天气对照、预算冲突案例、独立快照消费者及十万条八布局对照基准。

## v0.0.19–v0.0.20 开发里程碑

- v0.0.19 完成候选的键排序和逐查询扫描比较。
- v0.0.20 接入自动生成、方案绑定及单目标重建验收。

## v0.0.12

- 交付 Windows/Linux 原生 CLI 构建与跨进程验收流程。
- 固定种子的 10 万条数据独立核对及时间、峰值内存、磁盘指标。
- 补齐文件格式、恢复语义、第三方许可及可下载案例包。

## v0.0.11

- 新增阶段检查点、独占任务锁和 resume，逐文件核对已完成阶段。
- 实际终止写入进程后重建未完成阶段，保持源文件及已完成输出可核对。
- 覆盖写入/同步失败、坏快照、输入变化、空输入和中文目录。

## v0.0.10

- 新增原生 plan/build/verify/query 文件工具，支持 JSONL KV 与二进制/JSON 契约。
- 重开真实 MoonLSM 数据目录，持久化 MoonFST、记录表及逐文件 SHA-256 清单。
- 新进程 SQLite 对照覆盖 9,840 条遥测及 273 条 NOAA 记录。

## v0.0.9

- 修正示例存储命名空间，覆盖任意首字节及无穷上界。
- 报告启动时撤销旧成功状态，记录运行身份和失败阶段，并处理子进程超时。
- 回归 v0.0.1、v0.0.4 与 v0.0.8 的键字节。

## v0.0.8

- 重载 MoonFST，核对完整键序列、记录序号、范围载荷和分页。
- 发布可复跑命令与机器可读的迁移验收报告。

## v0.0.7

- 新增按字段身份转换冻结记录的重建计划，支持换位与翻转升降序。
- 在独立 MoonLSM 目标重开后以 SQLite 复核，记录源摘要、目标、范围和故障测试。

## v0.0.6

- 新增有序字段 ID、索引代次和版本化契约。
- 游标绑定索引、快照和原始区间，跨代次或跨区间续读返回错误。

## v0.0.5

- 统一源码与注册表坐标，补齐 GitHub 仓库链接及安装入口。
- 增加 Windows / Linux CI 和从 v0.0.4 标签重建的兼容性检查。

## v0.0.4

- 接入校验过的 NOAA GHCNd 原始 CSV，核对三个测站的 273 个真实观测键和单站闰年 2 月的 29 条查询结果。
- 扩展 SQLite 验证，核对真实数据、双引擎、JS 和 Wasm GC，并支持从干净目录重建 v0.0.1。
- v0.0.1 的 9,840 个合成键和 18 条 MoonLSM 查询结果与当前版本逐字节一致。

## v0.0.3

- 使用同一批编码后的键构建 MoonFST 0.1.1 只读索引，序列化后重新载入并核对记录序号。
- 前缀、双字段区间、时间范围和游标续读均与 MoonLSM 结果一致。
- SQLite 独立核对 9,840 个键和两个引擎各 18 条查询结果。JS 与 Wasm GC 的键和结果字节一致。

## v0.0.2

- 新增可保存和复核的布局描述符，能区分布局冲突、未知键格式和描述符损坏。
- 新增按索引顺序表达的多字段区间，支持在相同时间戳下按序号截取。既有单字段区间继续使用自然升序端点。
- MoonLSM 重开后校验布局，复合区间得到 4 条预期记录。Wasm、Wasm GC 和 JS 每个后端通过 14 项测试。SQLite 对照继续通过。

## v0.0.1

- 复合键编码、逐字段升降序、前缀范围、单字段区间和排他游标。
- MoonLSM 0.3.2 接入和 SQLite 对照。重开数据库后，三条扫描路径与分页返回相同记录。
- 本地初始版本号调整为 v0.0.1，键字节格式仍为 v1。
# 0.0.13–0.0.18 implementation candidate (unreleased)

- Project-scoped stable toolchain installer, explicit compiler/core pin, build identity and release guard. Official stable 0.10.21+06da1ed44 installed from the official CN mirror; archive SHA-256 verified. The 0.10.20 baseline is retained.
- Typed field-identity queries, canonical predicate-scoped cursors and source/target access explanations.
- Workload checks replay frozen input into MoonLSM, compare target MoonLSM/FST and pagination, and enforce independent scan budgets. Data readiness and workload approval remain separate.
- Snapshot reader module validates portable artifacts once, then serves pages without filesystem access. Device/weather consumers and 100-page measurements included.
- SQLite business-field oracle, refreshed-digest corruption cases, report overwrite protection, one-command acceptance and candidate packaging.
