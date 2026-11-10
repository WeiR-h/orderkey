///|
test "prefix ranges match complete fields" {
  let spec = @orderkey.KeySpec::new([BytesField(Asc), Int64Field(Desc)])
  let one = spec.encode([Binary(b"pump"), Signed(5L)])
  let two = spec.encode([Binary(b"pump"), Signed(-5L)])
  let other = spec.encode([Binary(b"pump\x00"), Signed(5L)])
  let prefix = spec.prefix_range([Binary(b"pump")])
  assert_true(prefix.contains(one))
  assert_true(prefix.contains(two))
  assert_false(prefix.contains(other))
  let entire = spec.prefix_range([])
  assert_eq(entire, @orderkey.Span(b"", None))
  assert_true(entire.contains(other))
  assert_true(spec.prefix_range([Binary(b"pump"), Signed(5L)]).contains(one))
  assert_false(spec.prefix_range([Binary(b"pump"), Signed(5L)]).contains(two))
}

///|
fn admits_int64(bound : @orderkey.Bound, value : Int64, lower : Bool) -> Bool {
  match bound {
    Unbounded => true
    Inclusive(Signed(limit)) =>
      if lower {
        value >= limit
      } else {
        value <= limit
      }
    Exclusive(Signed(limit)) =>
      if lower {
        value > limit
      } else {
        value < limit
      }
    _ => abort("expected an Int64 test bound")
  }
}

///|
test "all signed interval combinations match logical predicates" {
  let times = [MIN_I64, -1L, 0L, 1L, MAX_I64]
  let bounds : Array[@orderkey.Bound] = [Unbounded]
  for time in times {
    bounds.push(Inclusive(Signed(time)))
    bounds.push(Exclusive(Signed(time)))
  }
  for direction in [@orderkey.Asc, @orderkey.Desc] {
    let spec = @orderkey.KeySpec::new([
      BytesField(Asc),
      Int64Field(direction),
      Int64Field(Asc),
    ])
    for lower in bounds {
      for upper in bounds {
        let range = spec.field_range([Binary(b"t")], lower, upper)
        for time in times {
          let expected = admits_int64(lower, time, true) &&
            admits_int64(upper, time, false)
          for seq in [0L, 1L] {
            let key = spec.encode([Binary(b"t"), Signed(time), Signed(seq)])
            assert_eq(range.contains(key), expected)
            let other = spec.encode([
              Binary(b"t\x00"),
              Signed(time),
              Signed(seq),
            ])
            assert_false(range.contains(other))
          }
        }
      }
    }
  }
}

///|
test "binary bounds work in either direction with zero bytes and common prefixes" {
  for direction in [@orderkey.Asc, @orderkey.Desc] {
    let spec = @orderkey.KeySpec::new([BytesField(direction), Int64Field(Asc)])
    let range = spec.field_range(
      [],
      Exclusive(Binary(b"p")),
      Inclusive(Binary(b"p\xff")),
    )
    for value in [b"", b"p", b"p\x00", b"p\xff", b"p\xff\x00", b"q", b"\xff"] {
      let expected = value.lexical_compare(b"p") > 0 &&
        value.lexical_compare(b"p\xff") <= 0
      assert_eq(
        range.contains(spec.encode([Binary(value), Signed(7L)])),
        expected,
      )
    }
  }
}

///|
test "unbounded and empty results are distinct at the ends of the key space" {
  let asc = @orderkey.KeySpec::new([Int64Field(Asc)])
  let max_key = asc.encode([Signed(MAX_I64)])
  assert_eq(asc.prefix_range([Signed(MAX_I64)]), @orderkey.Span(max_key, None))
  assert_eq(
    asc.field_range([], Exclusive(Signed(MAX_I64)), Unbounded),
    @orderkey.Empty,
  )
  assert_eq(
    asc.field_range([], Inclusive(Signed(1L)), Exclusive(Signed(1L))),
    @orderkey.Empty,
  )
  let desc = @orderkey.KeySpec::new([Int64Field(Desc)])
  assert_eq(
    desc.field_range([], Unbounded, Exclusive(Signed(MIN_I64))),
    @orderkey.Empty,
  )
}

///|
test "resume excludes the cursor and retains the rest of a timestamp tie" {
  let spec = @orderkey.KeySpec::new([
    BytesField(Asc),
    Int64Field(Desc),
    Int64Field(Asc),
  ])
  let range = spec.prefix_range([Binary(b"a")])
  let first = spec.encode([Binary(b"a"), Signed(7L), Signed(0L)])
  let second = spec.encode([Binary(b"a"), Signed(7L), Signed(1L)])
  let third = spec.encode([Binary(b"a"), Signed(6L), Signed(0L)])
  let elsewhere = spec.encode([Binary(b"b"), Signed(7L), Signed(0L)])
  let next = spec.resume_after(range, first)
  assert_false(next.contains(first))
  assert_true(next.contains(second))
  assert_true(next.contains(third))
  assert_false(next.contains(elsewhere))
  assert_true(
    key_error(() => spec.resume_after(range, elsewhere))
    is @orderkey.CursorOutsideRange,
  )
  assert_true(
    key_error(() => spec.resume_after(range, b"")) is @orderkey.TruncatedKey(0),
  )
}

///|
test "bounds and prefixes reject incompatible input" {
  let spec = @orderkey.KeySpec::new([Int64Field(Asc)])
  assert_true(
    key_error(() => spec.prefix_range([Signed(0L), Signed(1L)]))
    is @orderkey.InvalidPrefixLength(2),
  )
  assert_true(
    key_error(() => spec.field_range([Signed(0L)], Unbounded, Unbounded))
    is @orderkey.InvalidPrefixLength(1),
  )
  assert_true(
    key_error(() => {
      spec.field_range([], Exclusive(Signed(MAX_I64)), Inclusive(Binary(b"x")))
    })
    is @orderkey.TypeMismatch(0),
  )
}
