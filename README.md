# OrderKey

**v0.1.0 支持在重建前比较索引布局。** 导入冻结的 KV 导出和业务查询，比较扫描预算及返回顺序，再重建推荐布局。验收报告逐条对照预测扫描数、MoonLSM 实测和 MoonFST 分页结果。 [布局选型指南](docs/LAYOUTS.md) · [查询与 SDK 指南](docs/QUERIES.md)

OrderKey 是一个 MoonBit 库，给按无符号字节字典序排序的存储引擎生成复合键和扫描区间。调用方固定索引的字段类型与升降序后，可以按前导字段查找、在下一字段限定区间，或从上一页末尾继续扫描。

各版本交付见 [CHANGELOG.md](CHANGELOG.md)，Windows 与 Linux 程序及复验报告随 [GitHub Releases](https://github.com/WeiR-h/orderkey/releases) 提供。v0.1.0 沿用 v1 键格式。

## 复现

在完整项目的根目录运行。完整源码见 [GitHub](https://github.com/WeiR-h/orderkey)。核心历史兼容基线使用 MoonBit v0.10.20 工具链验证，MoonLSM 演示的 JS 后端需要 Node.js。 [MoonBit 工具链下载](https://www.moonbitlang.com/download/)

```sh
moon update
moon test --target wasm .
moon test --target wasm-gc .
moon test --target js .
moon run --target js examples/moonlsm
```

可选的独立验证需要 Python 3.10+。脚本对合成数据和项目内的 NOAA 原始观测各运行一次双引擎验证，把 JS 和 Wasm GC 的键逐字节核对，再用 SQLite 比较多列排序、BLOB 排序和时间区间结果。

```sh
python examples/moonlsm/verify_sqlite.py
```

在有本地 `v0.0.1` Git 标签的工作区，可以加 `--baseline` 从干净目录重建 v0.0.1 和 v0.0.4，并核对两个版本的键字节。

核心库只依赖 MoonBit 标准库。工作区的演示使用 [MoonLSM 0.3.2](https://mooncakes.io/docs/PingGuoMiaoMiao/moonlsm%400.3.2) 和 [MoonFST 0.1.1](https://mooncakes.io/docs/starAndHonor/fst%400.1.1)。

## 真实文件与阶段恢复

原生工具支持外部 KV JSONL 导出、JSON 或二进制契约、真实磁盘重建、快照分发和按阶段恢复。下载对应平台程序后，可以在新进程中重新核对候选。命令及文件格式见 [CLI 使用说明](docs/CLI.md)。

~~~sh
python scripts/build.py
python scripts/verify_cli.py --report cli-report.json
python scripts/benchmark.py --report benchmark.json
~~~

复验包括真实进程终止、任务锁、写入和同步失败、文件截断、输入变化以及中文路径。10 万条数据由固定种子生成，报告包含原生构建耗时、峰值驻留内存和磁盘用量。依赖与数据出处见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 使用示例

从 Mooncakes 安装 v0.1.0 的核心库。使用原生快照读取时，也安装同版本的快照 SDK。

```sh
moon add WeiR-h/orderkey@0.1.0
moon add WeiR-h/orderkey_snapshot@0.1.0
```

在调用方的 `moon.pkg` 中导入 `"WeiR-h/orderkey"`。下面的函数生成一条记录的键，以及同一租户和设备上时间戳 `[-2, 4)` 的扫描范围。

```moonbit
fn make_query() -> (Bytes, @orderkey.ByteRange) raise @orderkey.KeyError {
  let spec = @orderkey.KeySpec::new([
    BytesField(Asc), BytesField(Asc), Int64Field(Desc), Int64Field(Asc),
  ])
  let key = spec.encode([Binary(b"t3"), Binary(b"pump"), Signed(0L), Signed(1L)])
  let range = spec.field_range(
    [Binary(b"t3"), Binary(b"pump")],
    Inclusive(Signed(-2L)),
    Exclusive(Signed(4L)),
  )
  (key, range)
}
```

- `encode` 和 `decode` 处理完整的键。字段索引与解码错误偏移均从 0 开始。
- `prefix_range` 按完整的前导字段匹配。设备 `pump` 与 `pump\x00A` 是不同的字段值。
- `field_range` 先限定前导字段，再给紧接着的一个字段指定范围。输入端点始终按值的自然升序表达，`Desc` 字段会由库转换为相应的字节顺序。
- `tuple_range` 接受由多个后续字段组成的端点，端点按配置的索引顺序给出。端点可以只给出部分字段，包含或排除作用于与其共享前缀的整组键。
- `layout` 生成持久化布局描述符，`from_layout` 可恢复布局，`require_layout` 用于重新打开索引时检查已有布局和调用方预期是否一致。
- `Span(start, Some(end))` 表示 `[start, end)`，`Span(start, None)` 表示上界无穷，`Empty` 表示空区间。范围语义针对按同一布局写入的完整键。
- `resume_after` 检查游标是否是范围内的完整键，并排除该键。需要并发写入期间稳定翻页时，存储层须提供一致的读快照。

## 离线换序与验收

在有序 KV 上自建索引时，保存 IndexContract 描述符。它包含稳定的索引 ID、代次和按顺序排列的字段 ID。交换两个升序字节字段时，原有布局的类型标签一样，新的契约能识别字段含义变化。旧索引的字段 ID 由应用显式提供。

- 用 IndexContract::new 建立源和目标契约。打开索引时通过 require_same 验证保存的描述符。
- 调用 ReindexPlan::new 预检重排与方向变更，然后对冻结记录调用 rekey，把新键与原载荷写入独立目标。目标代次递增，字段 ID 及其类型对应一致。
- 续读时将原始区间、存储层提供的稳定快照 ID 和实际末键传入 issue_cursor。resume_cursor 检查同一索引、代次、快照和区间。公开接口的游标应由应用层鉴别完整性。
- 重开并核对目标后，由调用方决定何时切换。示例使用 MoonLSM 的 MemStorage 重开 SSTable，并从目标记录生成、重载 MoonFST，只读索引保存目标记录序号。

在完整源码的根目录，用 Python 3.10+、Node.js 与 MoonBit 运行。

```sh
moon update
python examples/moonlsm/verify_reindex.py --report reindex-report.json
```

报告逐项记录源与目标契约、行数、重复数、源前后 SHA-256、查询结果 SHA-256 和首个差异。源摘要覆盖引擎扫描出的键值载荷。ready 表示此轮复验的目标可作为切换候选。负向检查覆盖错误布局、旧游标、坏键、目标重复和存储写入失败。SQLite 按原始类型和值独立验证合成遥测和 NOAA 观测。

## v1 键格式

| 字段 | 升序编码 | 降序编码 |
|---|---|---|
| `Int64` | 翻转符号位，写成 8 字节大端序 | 逐字节反转升序编码的所有位 |
| `Bytes` | `00` 转义成 `00 FF`，字段以 `00 00` 结束 | 逐字节反转升序编码的所有位 |

完整键按布局顺序连接各字段。字节字段用原始字节比较，空字节串和包含 `00`、`FF` 的值均可编码。索引元数据应保存版本与字段布局。布局变化时，为新布局重建索引，避免在一个字节排序空间内混用不同布局。

布局描述符以 `4F 4B 01` 开头，随后每个字段占一个字节。字节串升序为 `10`，字节串降序为 `11`，整数升序为 `20`，整数降序为 `21`。描述符存到索引的元数据位置，原有数据键沿用 v1 编码。

## 双引擎演示

示例写入 9,840 条模拟设备读数，刷新 SSTable 后重新打开数据库。固定查询跨越负数和零，同一时间戳包含三条记录。

- 比较全扫后过滤、手写正确字节边界和 OrderKey 生成边界的逐条结果。
- 对同一查询做游标分页，并与单次范围查询核对顺序与记录数量。
- 重新打开后检查持久化布局，再用时间戳和序号共同限定区间，验证边界可以切开同一时间戳的记录。
- 将相同键和原始行的序号构建成 MoonFST 只读索引，序列化并重新载入。按设备取前缀、复合区间和游标续读的结果都与 MoonLSM 对照。
- 统计扫描返回给调用方的行数，以及键和值的字节总数。示例用 MoonLSM 自带的内存存储，SSTable 在打开时载入。返回的数据量和物理磁盘读取量是两个指标。

| 扫描路径 | 引擎返回行数 | 返回的键和值 |
|---|---:|---:|
| 全扫后由调用方过滤 | 9,840 | 334,560 字节 |
| 手写正确边界 | 18 | 648 字节 |
| OrderKey 生成边界 | 18 | 648 字节 |

三条路径最终得到相同的 18 行。游标分为 5、5、5、3 条，拼接结果与单次查询一致。示例的 MoonLSM 适配代码使用有限的上界，核心库同时支持上界无穷。

MoonFST 快照只包含键和记录序号，真实键值内容仍由 MoonLSM 返回。SQLite 独立核对两个引擎的返回键和顺序。

## 公开数据样本

样本来自 NOAA NCEI 的 GHCNd Daily Summaries。原始 CSV 包含三个美国测站在 2024 年第一季度的 273 条观测，保留 `STATION`、`DATE`、`TMAX`、`TMIN` 四列。脚本先检查原始字节的 SHA-256，再把日期按 `YYYYMMDD` 写入降序索引，温度作为原样文本值写入 MoonLSM。 [原始 CSV](https://github.com/WeiR-h/orderkey/blob/v0.0.8/examples/moonlsm/fixtures/noaa-ghcnd-2024-q1.csv) · [NOAA 数据接口](https://www.ncei.noaa.gov/access/services/data/v1?dataset=daily-summaries&stations=USW00094846,USW00024233,USW00094728&startDate=2024-01-01&endDate=2024-03-31&dataTypes=TMAX,TMIN&units=metric&format=csv) · [NCEI 开放数据政策](https://www.ncei.noaa.gov/sites/default/files/2023-12/NCEI%20PD-10-2-02%20-%20Open%20Data%20Policy%20Signed.pdf)

对 `USW00094846` 查询日期范围 `[20240201, 20240301)`，两个引擎各返回 29 条，从 2024 年 2 月 29 日开始降序排列。复现使用项目内的原始文件。

设计参考可比较键的公开先例 [FoundationDB Tuple Layer](https://apple.github.io/foundationdb/data-modeling.html) 和 [Google orderedcode](https://pkg.go.dev/github.com/google/orderedcode)。OrderKey 使用上表中的 v1 字节格式。
