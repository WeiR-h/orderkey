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
