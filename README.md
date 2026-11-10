# OrderKey 0.0.2

OrderKey 是一个 MoonBit 库，给按无符号字节字典序排序的存储引擎生成复合键和扫描区间。调用方固定索引的字段类型与升降序后，可以按前导字段查找、在下一字段限定区间，或从上一页末尾继续扫描。

小版本的交付与验证记录见 [CHANGELOG.md](CHANGELOG.md)。包版本与 v1 键格式是独立的。

## 复现

在完整项目的根目录运行。此版本使用 MoonBit v0.10.20 工具链验证，MoonLSM 演示的 JS 后端需要 Node.js。 [MoonBit 工具链下载](https://www.moonbitlang.com/download/)

```sh
moon update
moon test --target wasm .
moon test --target wasm-gc .
moon test --target js .
moon run --target js examples/moonlsm
```

可选的独立验证需要 Python 3.9+。脚本把 JS 和 Wasm GC 实际生成的键逐字节核对，再用 SQLite 比较多列排序、BLOB 排序和时间区间查询结果。

```sh
python examples/moonlsm/verify_sqlite.py
```

核心库只依赖 MoonBit 标准库。工作区的演示依赖 Mooncakes 上的 [MoonLSM 0.3.2](https://mooncakes.io/docs/PingGuoMiaoMiao/moonlsm%400.3.2)。

## 使用示例

在调用方的 `moon.pkg` 中导入 `"orderkey/orderkey"`。下面的函数生成一条记录的键，以及同一租户和设备上时间戳 `[-2, 4)` 的扫描范围。

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

## v1 键格式

| 字段 | 升序编码 | 降序编码 |
|---|---|---|
| `Int64` | 翻转符号位，写成 8 字节大端序 | 逐字节反转升序编码的所有位 |
| `Bytes` | `00` 转义成 `00 FF`，字段以 `00 00` 结束 | 逐字节反转升序编码的所有位 |

完整键按布局顺序连接各字段。字节字段用原始字节比较，空字节串和包含 `00`、`FF` 的值均可编码。索引元数据应保存版本与字段布局。布局变化时，为新布局重建索引，避免在一个字节排序空间内混用不同布局。

布局描述符以 `4F 4B 01` 开头，随后每个字段占一个字节。字节串升序为 `10`，字节串降序为 `11`，整数升序为 `20`，整数降序为 `21`。描述符存到索引的元数据位置，原有数据键沿用 v1 编码。

## MoonLSM 演示

示例写入 9,840 条模拟设备读数，刷新 SSTable 后重新打开数据库。固定查询跨越负数和零，同一时间戳包含三条记录。

- 比较全扫后过滤、手写正确字节边界和 OrderKey 生成边界的逐条结果。
- 对同一查询做游标分页，并与单次范围查询核对顺序与记录数量。
- 重新打开后检查持久化布局，再用时间戳和序号共同限定区间，验证边界可以切开同一时间戳的记录。
- 统计扫描返回给调用方的行数，以及键和值的字节总数。示例用 MoonLSM 自带的内存存储，SSTable 在打开时载入。返回的数据量和物理磁盘读取量是两个指标。

| 扫描路径 | 引擎返回行数 | 返回的键和值 |
|---|---:|---:|
| 全扫后由调用方过滤 | 9,840 | 334,560 字节 |
| 手写正确边界 | 18 | 648 字节 |
| OrderKey 生成边界 | 18 | 648 字节 |

三条路径最终得到相同的 18 行。游标分为 5、5、5、3 条，拼接结果与单次查询一致。示例的 MoonLSM 适配代码使用有限的上界，核心库同时支持上界无穷。

设计参考可比较键的公开先例 [FoundationDB Tuple Layer](https://apple.github.io/foundationdb/data-modeling.html) 和 [Google orderedcode](https://pkg.go.dev/github.com/google/orderedcode)。OrderKey 使用上表中的 v1 字节格式。
