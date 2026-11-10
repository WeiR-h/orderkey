///|
const MEMTABLE_LIMIT : Int32 = 32768

///|
const PAGE_SIZE : Int32 = 5

///|
fn scan_range(
  db : @moonlsm.Db[@moonlsm.MemStorage],
  range : @orderkey.ByteRange,
  limit : Int32,
) -> Array[@moonlsm.KvPair] raise @moonlsm.LsmError {
  match range {
    Empty => []
    Span(start, Some(end)) => db.scan(start, end, limit)
    Span(_, None) => abort("this fixture requires a finite MoonLSM upper bound")
  }
}

///|
fn payload_bytes(rows : Array[@moonlsm.KvPair]) -> Int32 {
  let mut bytes = 0
  for row in rows {
    bytes += row.key.length() + row.value.length()
  }
  bytes
}

///|
fn run_demo(emit_fixture : Bool) -> Unit raise {
  let spec = @orderkey.KeySpec::new([
    BytesField(Asc),
    BytesField(Asc),
    Int64Field(Desc),
    Int64Field(Asc),
  ])
  let storage = @moonlsm.MemStorage::new()
  let writer = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  let layout_key = b"\x00orderkey-layout"
  writer.put_deferred(layout_key, spec.layout()) |> ignore
  let tenants = [
    b"t0", b"t1", b"t2", b"t3", b"t4", b"t5", b"t6", b"t7", b"t8", b"t9",
  ]
  let devices = [
    b"pump", b"pump\x00A", b"pump\x00B", b"pump\xff", b"meter", b"valve", b"fan",
    b"edge",
  ]
  let mut count = 0
  for tenant in tenants {
    for device in devices {
      for timestamp = -20L; timestamp <= 20L; timestamp = timestamp + 1L {
        for sequence in [0L, 1L, 2L] {
          let key = spec.encode([
            Binary(tenant),
            Binary(device),
            Signed(timestamp),
            Signed(sequence),
          ])
          writer.put_deferred(key, b"reading") |> ignore
          if emit_fixture {
            println(
              "key,\{@hex.encode(tenant[:])},\{@hex.encode(device[:])},\{timestamp},\{sequence},\{@hex.encode(key[:])}",
            )
          }
          count += 1
        }
      }
    }
  }
  writer.sync()
  writer.flush()
  writer.close()

  let sst_files = storage.names().filter(name => name.has_suffix(".sst"))
  assert_true(!sst_files.is_empty())
  let db = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  match db.get(layout_key) {
    Some(layout) => spec.require_layout(layout)
    None => abort("missing OrderKey layout")
  }

  // Fixture keys begin with ASCII tenant bytes. The layout key lives below 01.
  let full_scan = db.scan(b"\x01", b"\xff", count + 1)
  assert_eq(full_scan.length(), count)
  let filtered = []
  for row in full_scan {
    match spec.decode(row.key) {
      [Binary(tenant), Binary(device), Signed(timestamp), Signed(_)] =>
        if tenant == b"t3" &&
          device == b"pump\x00A" &&
          timestamp >= -2L &&
          timestamp < 4L {
          filtered.push((row.key, row.value))
        }
      _ => abort("unexpected key in fixture")
    }
  }

  let range = spec.field_range(
    [Binary(b"t3"), Binary(b"pump\x00A")],
    Inclusive(Signed(-2L)),
    Exclusive(Signed(4L)),
  )
  // With DESC Int64, [-2, 4) starts at 3 and stops before -3 in byte order.
  let manual_start = b"t3\x00\x00pump\x00\xffA\x00\x00\x7f\xff\xff\xff\xff\xff\xff\xfc"
  let manual_end = b"t3\x00\x00pump\x00\xffA\x00\x00\x80\x00\x00\x00\x00\x00\x00\x02"
  assert_eq(range, @orderkey.Span(manual_start, Some(manual_end)))

  let manual = db.scan(manual_start, manual_end, count + 1)
  let indexed = scan_range(db, range, count + 1)
  let indexed_pairs = indexed.map(fn(row) { (row.key, row.value) })
  assert_eq(indexed_pairs, manual.map(fn(row) { (row.key, row.value) }))
  assert_eq(indexed_pairs, filtered)

  let observed = []
  for row in indexed {
    match spec.decode(row.key) {
      [Binary(_), Binary(_), Signed(timestamp), Signed(sequence)] =>
        observed.push((timestamp, sequence))
      _ => abort("unexpected key in range")
    }
  }
  let expected = []
  for timestamp = 3L; timestamp >= -2L; timestamp = timestamp - 1L {
    for sequence in [0L, 1L, 2L] {
      expected.push((timestamp, sequence))
    }
  }
  assert_eq(observed, expected)

  let tuple_range = spec.tuple_range(
    [Binary(b"t3"), Binary(b"pump\x00A")],
    TupleInclusive([Signed(3L), Signed(1L)]),
    TupleExclusive([Signed(2L), Signed(2L)]),
  )
  let tuple_rows = scan_range(db, tuple_range, count + 1)
  assert_eq(tuple_rows.map(fn(row) { (row.key, row.value) }), [
    indexed_pairs[1],
    indexed_pairs[2],
    indexed_pairs[3],
    indexed_pairs[4],
  ])

  let paged = []
  let page_sizes = []
  let mut window = range
  while true {
    let page = scan_range(db, window, PAGE_SIZE)
    if page.is_empty() {
      break
    }
    page_sizes.push(page.length())
    for row in page {
      paged.push((row.key, row.value))
    }
    if page.length() < PAGE_SIZE {
      break
    }
    window = spec.resume_after(window, page[page.length() - 1].key)
  }
  assert_eq(paged, indexed_pairs)
  assert_eq(page_sizes, [5, 5, 5, 3])
  db.close()

  if emit_fixture {
    for row in indexed {
      println("match,\{@hex.encode(row.key[:])}")
    }
  }
  println("OrderKey 0.0.2 / MoonLSM 0.3.2")
  println(
    "fixture: \{count} records, \{sst_files.length()} SSTable files, reopened",
  )
  println("query: t3 / pump\\x00A / timestamp [-2, 4)")
  println(
    "full scan: \{full_scan.length()} rows, \{payload_bytes(full_scan)} payload bytes",
  )
  println(
    "manual bounds: \{manual.length()} rows, \{payload_bytes(manual)} payload bytes",
  )
  println(
    "OrderKey bounds: \{indexed.length()} rows, \{payload_bytes(indexed)} payload bytes",
  )
  println("verified: identical results, pages 5 / 5 / 5 / 3")
  println(
    "layout verified on reopen, tuple range returned \{tuple_rows.length()} rows",
  )
}

///|
fn main {
  run_demo(@env.args().contains("--sqlite-fixture")) catch {
    error => abort(error.to_string())
  }
}
