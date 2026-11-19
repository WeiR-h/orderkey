///|
test "query permutations use field identity and preserve typed membership" {
  let source = IndexContract::new(b"index", 1UL, [
    (b"a", BytesField(Asc)),
    (b"b", BytesField(Asc)),
    (b"t", Int64Field(Desc)),
  ])
  let query = QuerySpec::new(
    [(b"a", Binary(b"\x00\xff"))],
    Some((b"t", Some(Signed(-2L)), Some(Signed(4L)))),
  )
  let old = query.plan(source)
  assert_eq(old.access(), "prefix")
  for mask in 0..<8 {
    let da : Direction = if (mask & 1) == 0 { Asc } else { Desc }
    let db : Direction = if (mask & 2) == 0 { Asc } else { Desc }
    let dt : Direction = if (mask & 4) == 0 { Asc } else { Desc }
    for
      permutation in [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
      ] {
      let fields = [
        (b"a", BytesField(da)),
        (b"b", BytesField(db)),
        (b"t", Int64Field(dt)),
      ]
      let target = IndexContract::new(
        b"index",
        2UL,
        permutation.map(i => fields[i]),
      )
      let plan = query.plan(target)
      let reindex = ReindexPlan::new(source, target)
      for
        number in [
          -9223372036854775808L, -3L, -2L, 0L, 3L, 4L, 9223372036854775807L,
        ] {
        for a in [b"", b"\x00\xff", b"\xff"] {
          let key = source
            .key_spec()
            .encode([Binary(a), Binary(b"b"), Signed(number)])
          let next = reindex.rekey(key)
          assert_eq(source.logical_key(key), target.logical_key(next))
          let expected = a == b"\x00\xff" && number >= -2L && number < 4L
          assert_eq(plan.matches(next), expected)
          if expected {
            assert_true(plan.byte_range().contains(next))
          }
        }
      }
    }
  }
}

///|
test "query identity is canonical and fields are copied" {
  let a = QuerySpec::new([(b"b", Signed(1L)), (b"a", Binary(b""))], None)
  let b = QuerySpec::new([(b"a", Binary(b"")), (b"b", Signed(1L))], None)
  assert_eq(a.to_bytes(), b.to_bytes())
  let c = IndexContract::new(b"id", 1UL, [(b"a", BytesField(Asc))])
  let fields = c.fields()
  fields[0] = (b"changed", Int64Field(Desc))
  assert_eq(c.fields()[0].0, b"a")
}

///|
test "byte intervals empty queries and invalid predicates" {
  for direction in [Asc, Desc] {
    let c = IndexContract::new(b"id", 1UL, [(b"a", BytesField(direction))])
    let query = QuerySpec::new(
      [],
      Some((b"a", Some(Binary(b"\x00")), Some(Binary(b"\xff")))),
    )
    let plan = query.plan(c)
    for value in [b"", b"\x00", b"\x00\xff", b"a", b"\xff", b"\xff\x00"] {
      let key = c.key_spec().encode([Binary(value)])
      let expected = value.lexical_compare(b"\x00") >= 0 &&
        value.lexical_compare(b"\xff") < 0
      assert_eq(plan.matches(key), expected)
      assert_eq(plan.byte_range().contains(key), expected)
    }
    let all = QuerySpec::new([], None).plan(c)
    assert_true(all.matches(c.key_spec().encode([Binary(b"")])))
    let empty = QuerySpec::new(
      [],
      Some((b"a", Some(Binary(b"z")), Some(Binary(b"a")))),
    ).plan(c)
    assert_eq(empty.byte_range(), Empty)
    assert_true(
      (Ok(QuerySpec::new([(b"a", Signed(1L))], None).plan(c)) catch {
        e => Err(e)
      })
      is Err(_),
    )
    assert_true(
      (Ok(QuerySpec::new([(b"unknown", Binary(b""))], None).plan(c)) catch {
        e => Err(e)
      })
      is Err(_),
    )
  }
  assert_true(
    (Ok(QuerySpec::new([(b"a", Signed(1L)), (b"a", Signed(2L))], None)) catch {
      e => Err(e)
    })
    is Err(_),
  )
  assert_true(
    (Ok(QuerySpec::new([(b"a", Signed(1L))], Some((b"a", None, None)))) catch {
      e => Err(e)
    })
    is Err(_),
  )
}
