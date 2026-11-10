///|
/// The verification script checks and packs the tracked NOAA CSV for both targets.
fn run_weather(packed : String) -> Unit raise {
  let spec = fixture_spec()
  let (storage, writer) = open_fixture(spec)
  let mut count = 0
  for record in packed.split(";") {
    match record.split("|").collect() {
      [station, date, high, low] => {
        let station_key = @utf8.encode(station)
        let day = @string.parse_int64(date)
        let observation = "\{high},\{low}"
        let key = spec.encode([
          Binary(b"ghcnd"),
          Binary(station_key),
          Signed(day),
          Signed(0L),
        ])
        writer.put_deferred(key, @utf8.encode(observation[:])) |> ignore
        emit_fixture_key(b"ghcnd", station_key, day, 0L, key)
        count += 1
      }
      _ => abort("malformed NOAA fixture row")
    }
  }
  assert_eq(count, 273)
  let (db, _) = reopen_fixture(storage, writer, spec)
  let all_rows = scan_fixture(db, count)
  assert_eq(all_rows.length(), count)
  let february = spec.field_range(
    [Binary(b"ghcnd"), Binary(b"USW00094846")],
    Inclusive(Signed(20240201L)),
    Exclusive(Signed(20240301L)),
  )
  let rows = scan_range(db, february, count + 1)
  assert_eq(rows.length(), 29)
  assert_eq(
    rows[0].key,
    spec.encode([
      Binary(b"ghcnd"),
      Binary(b"USW00094846"),
      Signed(20240229L),
      Signed(0L),
    ]),
  )
  let (snapshot, image_bytes) = build_snapshot(all_rows)
  assert_eq(snapshot.len(), count.to_uint64())
  let snapshot_rows = scan_snapshot(snapshot, february, count + 1)
  assert_eq(snapshot_rows.map(row => row.key), rows.map(row => row.key))
  for row in rows {
    println("match,\{@hex.encode(row.key[:])}")
  }
  for row in snapshot_rows {
    assert_eq(all_rows[row.value.to_int()].key, row.key)
    println("fst,\{@hex.encode(row.key[:])}")
  }
  db.close()
  println(
    "NOAA GHCNd: \{count} observations, \{rows.length()} February matches, \{image_bytes} serialized index bytes",
  )
}
