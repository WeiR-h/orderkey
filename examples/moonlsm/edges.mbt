///|
/// Exercise the adapter namespace with every possible first byte.
fn verify_keyspace() -> Unit raise {
  let spec = @orderkey.KeySpec::new([BytesField(Asc)])
  let storage = @moonlsm.MemStorage::new()
  let writer = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  let values = [b""]
  for i = 0; i < 256; i = i + 1 {
    values.push(Bytes::from_array([i.to_byte()]))
  }
  for value in values {
    writer.put_deferred(storage_key(spec.encode([Binary(value)])), value)
    |> ignore
  }
  writer.sync()
  writer.flush()
  writer.close()
  let db = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  let all = scan_fixture(db, values.length())
  assert_eq(all.length(), 257)
  let (fst, _) = build_snapshot(all)
  for prefix in [b"", b"\x00", b"\xff"] {
    let range = spec.prefix_range([Binary(prefix)])
    let expected = scan_range(db, range, 258)
    let actual = scan_snapshot(fst, range, 258)
    assert_eq(
      actual.map(fn(row) { row.key }),
      expected.map(fn(row) { row.key }),
    )
    assert_eq(expected.length(), 1)
  }
  let open_end = @orderkey.Span(spec.encode([Binary(b"\xff")]), None)
  assert_eq(scan_range(db, open_end, 258).length(), 1)
  assert_eq(scan_snapshot(fst, open_end, 258).length(), 1)
  db.close()
}
