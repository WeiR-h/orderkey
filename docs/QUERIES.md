# 查询回归验收

CLI 查询和 SDK 使用同一套类型谓词及快照读取逻辑。重建前可先比较布局和扫描预算。 [布局选型指南](LAYOUTS.md)

## 开始

```sh
python scripts/upgrade_toolchain.py --mirror cn
# 将输出目录的 bin 加到当前终端 PATH，并设置 MOON_HOME 为该目录。
moon update
python scripts/build.py
python scripts/acceptance.py
```

升级器校验官方下载包的 SHA-256，并安装编译器对应的标准库。安装和标准库构建均成功后才更新 `toolchain.json`，安装失败时保留已有环境。CI 从该文件读取固定编译器和标准库版本。当前固定版为 `moonc v1.0.0-rc1+3c0520448`（2026-11-26）。下载器可在整包连接停滞时改用带 ETag 和长度检查的分段请求，完成后核对完整 SHA-256。 [MoonBit 1.0 RC 公告](https://www.moonbitlang.com/blog/moonbit-1-0-rc)

## 查询文件

```json
{
  "eq": {
    "tenant": {"bytes_hex": "7433"},
    "device": {"bytes_hex": "70756d700041"}
  },
  "range": {
    "field": "time",
    "lower": {"int64": "-2"},
    "upper": {"int64": "4"}
  }
}
```

eq 按稳定字段 ID 匹配。最多一个 range，语义为自然升序的 `[lower, upper)`，可省略任一端点；字段降序由规划器转换。空查询 `{}` 代表全部记录。未命中的前导条件使用剩余谓词过滤。未知字段、错误类型、重复 JSON 属性、额外属性和溢出整数报错。JSON 字段 ID 使用 UTF-8；值只接受 bytes_hex 或 int64 两者之一。

```sh
orderkey explain --source-contract source.json --target-contract target.json --where where.json
orderkey query --out candidate --where where.json --limit 5
orderkey query --out candidate --where where.json --limit 5 --cursor PREVIOUS_TOKEN
```

响应包含 rows、cursor、scanned 和 plan。cursor 为 null 时结束；整页恰好到结尾可能多一次空页。limit 为 1–100000。语义查询不能混用字节边界。游标绑定清单、契约、规范化谓词和原始区间；JSON 属性重排不改变谓词身份。公开接口仍由调用方负责游标认证。

## 查询集与门禁

```json
{
  "schema_version": 1,
  "queries": [
    {
      "id": "tenant-scan",
      "eq": {"tenant": {"bytes_hex": "7433"}},
      "page_size": 113,
      "max_target_scanned": 1000
    }
  ]
}
```

```sh
orderkey check-queries --out candidate --queries workload.json --report queries-report.json
```

查询集为 1–100 条，每条 ID 非空且唯一。page_size 默认 100，max_target_scanned 默认 100000，均为 1–100000 的整数。报告必须写到候选目录之外，且不能覆盖输入文件。

工具把冻结导出重放为临时源 MoonLSM，在目标的私有副本上执行查询，再检查目标 FST、分页及不使用规划范围的类型值全扫。源和目标分别保持自身契约规定的顺序；逻辑记录及载荷必须相同。扫描数为引擎返回、尚未进行剩余谓词过滤的记录数。

遥测案例中，tenant 查询换序后从 984 条扫描扩大为 9840 条，结果仍为 984 条。预算为 1000 时，check-queries 返回非零状态，报告 data_ready=true、workload_passed=false、cutover_ready=false。候选本身的数据报告保持原样。成功和失败报告均有新的 run_id；解析错误也撤销此前的成功状态。

报告绑定输入、源目标契约、清单、查询集摘要、工具版本、编译器和源码提交。失败只允许作为失败结果展示。运行 verify/resume/check-queries 期间保留冻结原文件；只读 query 和 SDK 不要求这些原始路径存在。

## 只读 SDK

SDK 是独立模块 WeiR-h/orderkey_snapshot，默认 native；核心 WeiR-h/orderkey 继续仅依赖标准库。候选阶段在本工作区使用；公开包需等待正式发布。

```moonbit
let reader = @snapshot.Reader::open(candidate_dir)
let query = @orderkey.QuerySpec::new(
  [(b"tenant", Binary(b"t3"))], None,
)
let first = reader.query(query, limit=5)
let second = reader.query(query, limit=5, cursor=first.cursor)
```

Reader::open 一次校验候选文件清单、摘要、记录顺序、完整键、FST 序号映射及成功回执，并把查询所需记录载入内存。返回之后不再访问磁盘；文件在磁盘上变化不会改变已打开会话。新会话重新校验。快照应作为不可变交付物使用，摘要和回执不构成发布者身份认证。

每页按需遍历 FST，不展开剩余结果；含剩余谓词时可能扫描更多记录。当前上限仍为 10 万条、单文件 64 MiB、单行 1 MiB。SDK 示例分别是设备时间查询和天气日期查询；verify_snapshot.py 独立核对结果、便携目录和 100 页单会话查询。benchmark.py 在 10 万条样本上额外记录首次打开和连续 100 页的时间。

## 复验与交付

```sh
python scripts/demo_queries.py --out _build/query-demo
python scripts/demo.py --out _build/recovery-demo
python scripts/acceptance.py
python scripts/package.py --candidate
python scripts/package_snapshot.py
python scripts/release_gate.py
```

完整复验包含历史字节兼容、四个核心后端、18 项恢复检查、查询/SDK 验收和 10 万条规模。故障样本会重新计算摘要，避免仅靠哈希失败掩盖内容验收缺陷。

candidate 包供本地评审。正式打标签和公开发布前，必须完成最新稳定版升级、干净提交复验、Windows/Linux CI 和公开下载安装核对。主办方初审、最终验收和季度评选分别记录。
