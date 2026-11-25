///|
fn brute_cover_cost(mask : Int32, size : Int32, limit : Int32) -> Int32 {
  let mut best = size
  for selected in 0..<(1 << size) {
    if (selected & mask) != mask {
      continue
    }
    let mut windows = 0
    let mut rows = 0
    let mut previous = false
    for i in 0..<size {
      let covered = (selected & (1 << i)) != 0
      if covered {
        rows += 1
        if !previous {
          windows += 1
        }
      }
      previous = covered
    }
    if windows <= limit && rows < best {
      best = rows
    }
  }
  best
}

///|
test "bounded scans attain the exhaustive minimum for every small hit pattern" {
  let contract = IndexContract::new(b"events", 1UL, [
    (b"group", BytesField(Asc)),
    (b"time", Int64Field(Desc)),
  ])
  let spec = contract.key_spec()
  let plan = QuerySpec::new(
    [],
    Some((b"time", Some(Signed(0L)), Some(Signed(1L)))),
  ).plan(contract)
  let size = 6
  for mask in 0..<(1 << size) {
    let keys = Array::makei(size, i => {
      spec.encode([
        Binary(Bytes::make(1, i.to_byte())),
        Signed(if (mask & (1 << i)) != 0 { 0L } else { 1L }),
      ]) catch {
        _ => abort("valid fixture")
      }
    })
    for limit in [1, 2, 3, 16] {
      let scan = plan.bounded_ranges(keys, limit)
      assert_eq(scan.planned_scanned, brute_cover_cost(mask, size, limit))
      assert_true(scan.rank_windows.length() <= limit)
      let mut count = 0
      for i in 0..<size {
        if (mask & (1 << i)) != 0 {
          count += 1
          assert_true(
            scan.rank_windows.any(window => window.0 <= i && i < window.1),
          )
        }
      }
      assert_eq(scan.matched, count)
      if mask == 0b010101 && limit == 2 {
        assert_eq(scan.rank_windows, [(0, 1), (2, 5)])
      }
    }
  }
}
