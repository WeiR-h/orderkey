# 从业务查询生成选型输入

发布包附 NOAA 观测和原生 weather_capture。Windows 用 exe 后缀，Linux 用 ./ 前缀。
以下命令在新目录运行，用同一个业务入口执行查询并记录参数。给记录路径传 - 可关闭采集。

~~~sh
weather_capture export examples/weather/noaa-ghcnd-2024-q1.csv all weather-export
weather_capture query examples/weather/noaa-ghcnd-2024-q1.csv all USW00094846 query-trace.jsonl
weather_capture query examples/weather/noaa-ghcnd-2024-q1.csv all USW00094846 query-trace.jsonl 20240201 20240301
orderkey collect-queries --trace query-trace.jsonl --source-contract weather-export/source.contract --out weather-workload
orderkey compare-layouts --input weather-export/input.jsonl --source-contract weather-export/source.contract --queries weather-workload/workload.json --policy weather-workload/policy.json --auto --out weather-selection
orderkey build-selected --input weather-export/input.jsonl --source-contract weather-export/source.contract --queries weather-workload/workload.json --policy weather-workload/policy.json --selection weather-selection --out weather-delivery
orderkey verify-delivery --out weather-delivery
weather_capture query-selected weather-delivery USW00094846 20240201 20240301
~~~

导出可用 all 或 YYYYMM 选择观测月份。最后一条命令打开经过业务验收的快照并分页返回 29 条日期和温度记录。

采集文件是 UTF-8 JSONL。每行沿用现有 eq、range、page_size 和 max_target_scanned 字段；
输入 ID 不参与合并。相同规范化谓词与分页参数共享稳定 ID，预算取最小值，
policy.json 中的权重取调用次数。每次最多 100,000 次调用、100 个不同查询、64 MiB 输入、1 MiB 单行。
超限时拆分采集批次。查询参数可能含业务标识，应按业务数据处理本地记录。

## 复核后续批次

~~~sh
orderkey compare-layouts --input examples/regression/training/input.jsonl --source-contract examples/regression/training/source.json --queries examples/regression/training/layout-workload.json --candidate examples/regression/training/target.json --out fleet-selection
orderkey audit-layout --selection fleet-selection --batches examples/regression/batches.json --out fleet-audit
~~~

批次文件使用 schema_version 1，batches 为 1–5 个带唯一 id 的项目。
每项含 input、source_contract、queries 和可选 policy 路径。相对路径以批次文件所在目录为准。
发布复核使用 `audit-layout --locked`，各批查询文件和策略文件的字节摘要须与选型方案一致。
选型时省略策略的方案要求各批也省略策略。更改预算或查询会返回 invalid。
源契约必须与原选型一致。每批导出摘要必须不同，且与初次选型的导出不同。
报告列出源布局和同一已选目标的精确范围扫描数、命中、逐查询预算与顺序约束。
通过时退出码为 0。探测到退化或无效批次时非零退出，并保留 audit-report.json。

示例在后续批次加入 360 条窗外记录。结果仍为 180 条，扫描从 1,230 条
增加到 1,590 条，突破 1,500 条预算。审查只比较冻结导出。交付时仍用 build-selected
验证实际文件并生成业务回执。

## 发布判定

读冻结快照时可用 `query --where FILE --scan-mode segmented`。SDK 使用
`plan_segmented` 准备计划，再把同一个计划交给 `query_segmented` 分页。
报告区分计划探查数和候选扫描行数。分组超过 16 个、查询形状不适用或扫描数持平时使用单段结果，
并给出具体原因。

用 `audit-layout --locked --scan-mode segmented` 和 `gate-selected --scan-mode segmented`
核对冻结批次是否满足预算。发布流程从受信任的配置指定扫描模式和批准摘要。
审查报告的候选扫描数由完整冻结键计算。用 `check-queries --scan-mode segmented`
读取重建后的该批次，核对实际候选行和逐页结果。应用使用同一模式读取快照。

用 `explain --where FILE --source-contract FILE --target-contract FILE` 查看类型化范围。
报告用十六进制表示字段 ID，可表达任何二进制字段名。USGS 案例的目标布局固定 `network`，
`event_type` 阻挡 `time` 区间下推，末批单段扫描 71 条、过滤 38 条、超预算 21 条。

~~~sh
orderkey gate-selected --selection fleet-selection --selection-sha256 APPROVED_SHA256 --batches examples/regression/batches.json --delivery fleet-delivery --out gate-run
~~~

从已批准的配置提供方案摘要。用 `build-selected` 准备 `fleet-delivery`，报告目录每次用新名称。
退出 0 表示交付与所有批次都通过，1 表示冻结查询退化，2 表示输入或交付物无效。
报告里的交付查询为已重建数据的实测结果，各批扫描数为独立冻结导出的预测。
以下 GitHub Actions 步骤可放在已有的下载和构建步骤之后。将 `ORDERKEY_SELECTION_SHA256` 配置在受信任的发布流程中。

~~~yaml
- name: Verify proposed index delivery
  env:
    APPROVED_SHA256: ${{ vars.ORDERKEY_SELECTION_SHA256 }}
  run: |
    ./orderkey gate-selected --selection selection --selection-sha256 "$APPROVED_SHA256" --batches batches.json --delivery delivery --out gate-run
- uses: actions/upload-artifact@v4
  if: always()
  with:
    name: orderkey-gate
    path: gate-run/gate-report.json
~~~
