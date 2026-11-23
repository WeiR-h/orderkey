///|
test "segment planner bounds encoded descending groups" {
  let contract = IndexContract::new(b"events", 2UL, [
    (b"group", BytesField(Desc)),
    (b"time", Int64Field(Desc)),
  ])
  let predicate = QuerySpec::new(
    [],
    Some((b"time", Some(Signed(0L)), Some(Signed(1L)))),
  )
  let plan = predicate.plan(contract)
  let spec = contract.key_spec()
  let keys = []
  for i in 0..<17 {
    let group = Binary(Bytes::make(1, i.to_byte()))
    keys.push(spec.encode([group, Signed(2L)]))
    keys.push(spec.encode([group, Signed(0L)]))
  }
  keys.sort_by((a, b) => a.lexical_compare(b))
  let supported = keys[:32].to_owned()
  let split = plan.segment_ranges(supported)
  assert_true(split.fallback is None)
  assert_eq(split.windows.length(), 16)
  assert_eq(split.planned_scanned, 16)
  assert_eq(split.single_scanned, 32)
  for i, window in split.windows {
    assert_true(window.contains(supported[i * 2 + 1]))
    assert_false(window.contains(supported[i * 2]))
  }
  let fallback = plan.segment_ranges(keys)
  assert_eq(fallback.fallback, Some("group_limit"))
  assert_eq(fallback.planned_scanned, 34)
}
