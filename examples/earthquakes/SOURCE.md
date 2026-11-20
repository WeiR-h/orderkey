# USGS ComCat 冻结案例

来源为美国地质调查局 ANSS 综合地震目录。2026-11-20 UTC 获取 2024-04-01 至 2024-04-22 的全球事件，
最小震级 2.5，按事件时间升序。原始响应 SHA-256 为
`4ab13216dd593d56e1689d0edf7b65d2b687f986b4e61f3081f8ff6b39cb3e4a`。
随包分发的 TSV 提取四个结构化事实字段，时间转成 UTC 毫秒，保留目录返回的事件类型、网络及事件 ID。
数据来源归属 U.S. Geological Survey 及 ComCat 贡献网络。 [原始查询](https://earthquake.usgs.gov/fdsnws/event/1/query?format=csv&starttime=2024-04-01&endtime=2024-04-22&orderby=time-asc&minmagnitude=2.5) · [USGS 数据许可](https://www.usgs.gov/data-management/data-licensing)

用同一份冻结目录构造三份累积导出。业务查询固定为网络 `ak` 在 4 月 1 日至 8 日 UTC 的半开窗口。
源布局先按事件类型，候选布局先按网络。时间为降序，事件 ID 为升序。快照载荷保存事件 ID。
预算为 50 条候选记录。三批实测扫描 33、45、71 条，按事件类型、时间及 ID 排序后均返回同样的 33 条。

应用读取示例位于 SDK 的 `examples/earthquakes`。传入已验收快照所在目录和已批准的方案 SHA-256。
