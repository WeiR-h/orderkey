///|
test "rekey permutes field identities and reverses signed byte order" {
  let old = @orderkey.IndexContract::new(b"i", 1UL, [
    (b"name", BytesField(Asc)),
    (b"time", Int64Field(Desc)),
  ])
  let new = @orderkey.IndexContract::new(b"i", 2UL, [
    (b"time", Int64Field(Asc)),
    (b"name", BytesField(Desc)),
  ])
  let plan = @orderkey.ReindexPlan::new(old, new)
  for time in [-9223372036854775808L, -1L, 0L, 9223372036854775807L] {
    let key = old.key_spec().encode([Binary(b"\x00\xff"), Signed(time)])
    assert_eq(new.key_spec().decode(plan.rekey(key)), [
      Signed(time),
      Binary(b"\x00\xff"),
    ])
  }
  assert_true((Ok(plan.rekey(b"broken")) catch { e => Err(e) }) is Err(_))
}

///|
test "a migration needs the same index, newer generation and identical field kinds" {
  let old = @orderkey.IndexContract::new(b"i", 1UL, [(b"name", BytesField(Asc))])
  let other = @orderkey.IndexContract::new(b"j", 2UL, [
    (b"name", BytesField(Asc)),
  ])
  let changed = @orderkey.IndexContract::new(b"i", 2UL, [
    (b"name", Int64Field(Asc)),
  ])
  let renamed = @orderkey.IndexContract::new(b"i", 2UL, [
    (b"other", BytesField(Asc)),
  ])
  assert_true(
    (Ok(@orderkey.ReindexPlan::new(old, other)) catch { e => Err(e) })
    is Err(@orderkey.DifferentIndex),
  )
  assert_true(
    (Ok(@orderkey.ReindexPlan::new(old, old)) catch { e => Err(e) })
    is Err(@orderkey.InvalidGeneration),
  )
  assert_true(
    (Ok(@orderkey.ReindexPlan::new(old, changed)) catch { e => Err(e) })
    is Err(@orderkey.IncompatibleFields),
  )
  assert_true(
    (Ok(@orderkey.ReindexPlan::new(old, renamed)) catch { e => Err(e) })
    is Err(@orderkey.IncompatibleFields),
  )
}
