///|
test "same physical layout still detects swapped field identities" {
  let old = @orderkey.IndexContract::new(b"telemetry", 1UL, [
    (b"tenant", BytesField(Asc)),
    (b"device", BytesField(Asc)),
  ])
  let changed = @orderkey.IndexContract::new(b"telemetry", 1UL, [
    (b"device", BytesField(Asc)),
    (b"tenant", BytesField(Asc)),
  ])
  assert_eq(old.key_spec().layout(), changed.key_spec().layout())
  let persisted = old.to_bytes()
  let restored = @orderkey.IndexContract::from_bytes(persisted)
  assert_eq(restored.to_bytes(), persisted)
  old.require_same(persisted)
  assert_true(
    (Ok(changed.require_same(persisted)) catch { e => Err(e) })
    is Err(@orderkey.ContractMismatch),
  )
  for n = 0; n < persisted.length(); n = n + 1 {
    assert_true(
      (Ok(@orderkey.IndexContract::from_bytes(persisted[:n].to_owned())) catch {
        e => Err(e)
      })
      is Err(@orderkey.InvalidContract),
    )
  }
  assert_true(
    (Ok(
      @orderkey.IndexContract::new(b"i", 1UL, [
        (b"same", BytesField(Asc)),
        (b"same", Int64Field(Desc)),
      ]),
    ) catch {
      e => Err(e)
    })
    is Err(@orderkey.InvalidContract),
  )
}

///|
test "a cursor is bound to generation, snapshot and original interval" {
  let fields : Array[(Bytes, @orderkey.Field)] = [(b"time", Int64Field(Desc))]
  let original = @orderkey.IndexContract::new(b"i", 9UL, fields)
  let rebuilt = @orderkey.IndexContract::new(b"i", 10UL, fields)
  let spec = original.key_spec()
  let key = spec.encode([Signed(0L)])
  let range = spec.field_range(
    [],
    Inclusive(Signed(-2L)),
    Exclusive(Signed(4L)),
  )
  let token = original.issue_cursor(b"fixed", range, key)
  let next = original.resume_cursor(b"fixed", range, token)
  assert_false(next.contains(key))
  assert_true(next.contains(spec.encode([Signed(-1L)])))
  assert_true(
    (Ok(rebuilt.resume_cursor(b"fixed", range, token)) catch { e => Err(e) })
    is Err(@orderkey.CursorScopeMismatch),
  )
  assert_true(
    (Ok(original.resume_cursor(b"other", range, token)) catch { e => Err(e) })
    is Err(@orderkey.CursorScopeMismatch),
  )
  assert_true(
    (Ok(original.resume_cursor(b"fixed", spec.prefix_range([]), token)) catch {
      e => Err(e)
    })
    is Err(@orderkey.CursorScopeMismatch),
  )
  assert_true(
    (Ok(
      original.resume_cursor(
        b"fixed",
        range,
        token[:token.length() - 1].to_owned(),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@orderkey.InvalidCursor),
  )
}

///|
test "malformed lengths, trailing metadata and all truncated cursors are rejected" {
  let contract = @orderkey.IndexContract::new(b"id", 18446744073709551615UL, [
    (b"binary", BytesField(Desc)),
    (b"number", Int64Field(Asc)),
  ])
  assert_true(
    (Ok(
      @orderkey.IndexContract::from_bytes(
        b"OKC\x01\x00\x00\x00\x00\x00\x00\x00\x01\xff\xff\xff\xff",
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@orderkey.InvalidContract),
  )
  let spec = contract.key_spec()
  let range = spec.prefix_range([])
  let key = spec.encode([Binary(b""), Signed(-9223372036854775808L)])
  let token = contract.issue_cursor(b"snapshot", range, key)
  for size = 0; size < token.length(); size = size + 1 {
    assert_true(
      (Ok(contract.resume_cursor(b"snapshot", range, token[:size].to_owned())) catch {
        e => Err(e)
      })
      is Err(_),
    )
  }
  assert_false(contract.resume_cursor(b"snapshot", range, token).contains(key))
  assert_true(
    (Ok(contract.issue_cursor(b"", range, key)) catch { e => Err(e) })
    is Err(@orderkey.InvalidCursor),
  )
}
