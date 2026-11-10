///|
test "layout bytes are canonical and restore the original key ordering" {
  let spec = @orderkey.KeySpec::new([
    BytesField(Asc),
    BytesField(Desc),
    Int64Field(Asc),
    Int64Field(Desc),
  ])
  let saved = b"OK\x01\x10\x11\x20\x21"
  assert_eq(spec.layout(), saved)
  let restored = @orderkey.KeySpec::from_layout(saved)
  let values : Array[@orderkey.Value] = [
    Binary(b"a\x00"),
    Binary(b"\xff"),
    Signed(-3L),
    Signed(4L),
  ]
  assert_eq(restored.encode(values), spec.encode(values))
  assert_eq(restored.decode(spec.encode(values)), values)
  spec.require_layout(restored.layout())
}

///|
test "wrong direction, unknown formats and malformed descriptors are rejected" {
  let spec = @orderkey.KeySpec::new([Int64Field(Desc)])
  assert_true(
    key_error(() => spec.require_layout(b"OK\x01\x20"))
    is @orderkey.LayoutMismatch,
  )
  assert_true(
    key_error(() => spec.require_layout(b"OK\x02\x21"))
    is @orderkey.UnsupportedKeyFormat(2),
  )
  assert_true(
    key_error(() => @orderkey.KeySpec::from_layout(b"OK"))
    is @orderkey.InvalidLayout(2),
  )
  assert_true(
    key_error(() => @orderkey.KeySpec::from_layout(b"OK\x01"))
    is @orderkey.InvalidLayout(3),
  )
  assert_true(
    key_error(() => @orderkey.KeySpec::from_layout(b"OK\x01\x21\xff"))
    is @orderkey.InvalidLayout(4),
  )
}
