# 用业务查询选择索引布局

OrderKey 比较冻结导出上的布局，在源布局和最多八套目标中选出候选。扫描数是字节区间内、剩余谓词过滤前的记录数。用代表实际访问的查询参数与预算解释结果，耗时与磁盘 I/O 需用实际部署测量。

## 遥测案例

在解压的发布目录运行以下命令。Windows 使用 `orderkey.exe`，Linux 使用 `./orderkey`。输出目录每次使用新名称。

~~~sh
orderkey compare-layouts --input examples/telemetry/input.jsonl --source-contract examples/telemetry/source.json --queries examples/telemetry/layout-workload.json --auto --out telemetry-plan
orderkey build-selected --input examples/telemetry/input.jsonl --source-contract examples/telemetry/source.json --queries examples/telemetry/layout-workload.json --selection telemetry-plan --out telemetry-selected
orderkey query --out telemetry-selected --where examples/telemetry/where.json --limit 5
~~~

第一条命令可重复传入 `--candidate FILE`，支持 JSON 或 OKC01。`--auto` 按查询权重提出等值字段、范围字段优先的顺序，保留各字段方向。手工候选先加入，重复布局合并，最多八套目标参与比较。源布局也参与比较。所有候选均满足 `IndexContract` 的同一索引及递增代次约束。

报告 `comparison.json` 逐查询列出 `scanned`、`matched`、`budget`、`order_changed` 和 `failures`。遥测设备查询源扫描 9,840 条，推荐布局扫描 1,230 条，历史查询仍命中 18 条。用 `examples/telemetry/conflict-workload.json` 替换查询文件，可看到租户上限 1,000 条与设备上限 1,500 条的冲突。

| 比较状态 | 处理 |
|---|---|
| `selected` | 同目录生成 `selection.json` 和 `target.contract`，可交给 `build-selected`。 |
| `keep_source` | 保留源布局。 |
| `no_feasible_candidate` | 查看各布局的失败查询，调整候选或业务约束。 |

三个状态都代表已完成比较。无效输入或执行错误返回非零退出码。自动建议覆盖给定查询形成的候选集合。

## 双预算选型

用 `compare-layouts --scan-mode bounded` 让原布局和候选共同按扫描行数与区间数比较。
每条查询需提供 `max_target_scanned` 和 1–16 的 `max_target_windows`。
报告列出精确的半开位置区间、候选行数及命中数，仍按固定前缀、返回顺序和权重选型。
通过的 v2 选型记录扫描模式和逐查询预测；部署方可以独立保存选型文件的 SHA-256。

## 策略与重建

### 跨批选型与留出验收

`compare-batches` 接受 2–5 份冻结导出。沿用批次清单的 `schema_version: 1`，每项填写 `id`、`input`、`source_contract`、`queries` 和可选的 `policy`。相对路径以清单所在目录为准。`--anchor` 指定用来生成重建方案的批次。所有批次的源契约、查询文件和策略摘要必须一致。

~~~sh
orderkey compare-batches --batches assessment.json --anchor two-weeks --candidate target.json --out proposal
~~~

可重复传入 `--candidate` 或使用 `--auto`，共比较源布局与最多八套目标。每条查询填写扫描行数上限和 1–16 的区间上限。任意批次违反预算、前缀或顺序约束都会淘汰该布局。合格布局依次比较最差批次和所有批次的加权扫描行数，并列优先保留源布局。

`comparison-batches.json` 列出各布局的最差批次、逐查询扫描量、质量约束和失败原因。选中新布局后，方案目录同时包含标准 v2 `selection.json`、`target.contract` 和 `assessment.json`。后者绑定清单、各输入、锁定的工作负载和所选契约。键集摘要按键字典序计算，每个键前写入 4 字节大端长度，载荷变化和行序变化均保留相同的键集身份。

~~~sh
orderkey build-selected --input two-weeks.jsonl --source-contract source.json --queries workload.json \
  --selection proposal --assessment-batches assessment.json --assessment-sha256 "$APPROVED_ASSESSMENT_SHA256" \
  --out anchor-index
~~~

有策略文件时，在重建命令同时传入 `--policy`。恢复沿用全部参数并加 `--resume`。评估清单和评估输入应在重建及恢复期间保持冻结。

留出批次独立建库，使用同一 `target.contract`。将该批次的清单与两个批准摘要交给验收命令。

~~~sh
orderkey gate-batch --selection proposal --selection-sha256 "$APPROVED_SELECTION_SHA256" \
  --assessment-sha256 "$APPROVED_ASSESSMENT_SHA256" --batches holdout.json --batch-id late \
  --delivery late-index --scan-mode bounded --out approval
~~~

验收拒绝已参与评估的键集。通过时，回执记录评估摘要、新键集摘要与双引擎实测。调用方用可信渠道取得回执 SHA-256 后可用 `ApprovedReader` 分页。发行包中的 `replay-batch-selection` 提供可直接运行的 USGS 流程。

### 单批策略

可在两个命令上使用 `--policy FILE`，文件内容示例

~~~json
{
  "fixed_prefix": ["tenant"],
  "weights": {"fleet": 10},
  "allow_order_change": ["history"]
}
~~~

三个属性均可省略。权重默认 1，支持 1–100000 的整数。固定前导字段匹配顺序和字段 ID。默认逐查询排除等值约束下的常量字段，再比较其余字段的顺序和方向。确实允许返回顺序变化时，显式登记查询 ID。先筛预算、前导字段和顺序，再比较加权扫描总数和最大单查询扫描数。并列优先保留源布局。

`build-selected --selection DIR` 重新读取方案、契约、导出、查询和策略，复核摘要、预算与预测值后重建。中断时用相同命令和 `--out`，再加 `--resume`。只有 `selection-report.json` 的 `ready` 和 `cutover_ready` 均为真，且其中的清单摘要与交付文件一致时，该候选通过本次选型验收。原有 `report.json` 用于检查数据库与快照文件。

v2 选型的构建从选型文件取得扫描模式，核对两个引擎的候选行数、区间、顺序与分页。
交付目录包含原始 `selection.json`，可由 `verify-delivery --selection-sha256` 对照独立保存的摘要。
冻结的后续批次使用选定的目标契约重建，再运行 `gate-batch --scan-mode bounded`。
区间由末批键重新计算，通过后凭该批的回执分页。

把上述命令中的 `telemetry` 换成 `weather`，可用 273 条 NOAA 数据重建天气快照。示例查询返回 29 条，现有 `Reader::open` 可以查询重建后的目录。一个页面的游标按索引契约、快照与查询作用域校验。

交付选型结果时，用 `orderkey verify-delivery --out telemetry-selected`
验证文件与业务回执，或在应用内一次调用 `Reader::open_selected`。
部署方可用 `--selection-sha256` 指定选型方案的预期摘要。
接收方只需候选目录中的清单、文件、数据回执、选型任务和选型回执。
回执用于一致性检查，来源认证由交付渠道负责。

## 开发者复验

~~~sh
python scripts/acceptance.py
python scripts/verify_consumer.py --registry --report _build/acceptance/public-consumer.json
~~~

本地验收包含四后端、故障恢复和独立 SQLite 对照。本地消费者使用打包后的 SDK，`--registry` 则从干净依赖缓存验证公开包。

规模报告 `layout-benchmark.json` 记录十万条数据、八套布局的两条路径。逐个重建的基线保留八个输出目录，选型路径保留一套。报告注明主机、单进程峰值内存和采样输出磁盘占用。
