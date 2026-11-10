///|
const MIN_I64 : Int64 = -9223372036854775808L

///|
const MAX_I64 : Int64 = 9223372036854775807L

///|
fn[A] key_error(
  operation : () -> A raise @orderkey.KeyError,
) -> @orderkey.KeyError {
  try {
    operation() |> ignore
    abort("expected a KeyError")
  } catch {
    error => error
  }
}

///|
test "v1 format golden keys" {
  let spec = @orderkey.KeySpec::new([BytesField(Asc), Int64Field(Desc)])
  let values : Array[@orderkey.Value] = [Binary(b"a\x00\xff"), Signed(0L)]
  let encoded = b"a\x00\xff\xff\x00\x00\x7f\xff\xff\xff\xff\xff\xff\xff"
  assert_eq(spec.encode(values), encoded)
  assert_eq(spec.decode(encoded), values)
  let asc = @orderkey.KeySpec::new([Int64Field(Asc)])
  assert_eq(asc.encode([Signed(MIN_I64)]), b"\x00\x00\x00\x00\x00\x00\x00\x00")
  assert_eq(asc.encode([Signed(MAX_I64)]), b"\xff\xff\xff\xff\xff\xff\xff\xff")
  let desc = @orderkey.KeySpec::new([BytesField(Desc), Int64Field(Asc)])
  assert_eq(
    desc.encode([Binary(b"a\x00\xff"), Signed(-1L)]),
    b"\x9e\xff\x00\x00\xff\xff\x7f\xff\xff\xff\xff\xff\xff\xff",
  )
}

///|
test "mixed direction keys preserve order and round-trip" {
  let binaries = [
    b"", b"\x00", b"\x00\xff", b"p", b"p\x00", b"p\xff", b"\xff", b"\xff\xff",
  ]
  let integers = [MIN_I64, -2L, -1L, 0L, 1L, 2L, MAX_I64]
  for binary_direction in [@orderkey.Asc, @orderkey.Desc] {
    for int_direction in [@orderkey.Asc, @orderkey.Desc] {
      let spec = @orderkey.KeySpec::new([
        BytesField(binary_direction),
        Int64Field(int_direction),
        Int64Field(Asc),
      ])
      let mut last : Bytes? = None
      for bi = 0; bi < binaries.length(); bi = bi + 1 {
        let binary = match binary_direction {
          Asc => binaries[bi]
          Desc => binaries[binaries.length() - 1 - bi]
        }
        for ii = 0; ii < integers.length(); ii = ii + 1 {
          let number = match int_direction {
            Asc => integers[ii]
            Desc => integers[integers.length() - 1 - ii]
          }
          for sequence in [-1L, 0L, 1L] {
            let values : Array[@orderkey.Value] = [
              Binary(binary),
              Signed(number),
              Signed(sequence),
            ]
            let key = spec.encode(values)
            assert_eq(spec.decode(key), values)
            if last is Some(previous) {
              assert_true(previous.lexical_compare(key) < 0)
            }
            last = Some(key)
          }
        }
      }
    }
  }
}

///|
test "the layout is copied and wrong arity and types are rejected" {
  let fields : Array[@orderkey.Field] = [BytesField(Asc)]
  let spec = @orderkey.KeySpec::new(fields)
  fields[0] = Int64Field(Desc)
  assert_eq(spec.encode([Binary(b"ok")]), b"ok\x00\x00")
  assert_true(
    key_error(() => @orderkey.KeySpec::new([])) is @orderkey.EmptySpec,
  )
  assert_true(key_error(() => spec.encode([])) is @orderkey.WrongArity(1, 0))
  assert_true(
    key_error(() => spec.encode([Signed(1L)])) is @orderkey.TypeMismatch(0),
  )
}

///|
test "decode rejects truncation, bad escapes and trailing bytes" {
  let bytes = @orderkey.KeySpec::new([BytesField(Asc)])
  assert_true(
    key_error(() => bytes.decode(b"a\x00")) is @orderkey.TruncatedKey(2),
  )
  assert_true(
    key_error(() => bytes.decode(b"a\x00\xfe")) is @orderkey.InvalidEscape(2),
  )
  assert_true(
    key_error(() => bytes.decode(b"a\x00\x00\x00"))
    is @orderkey.TrailingBytes(3),
  )
  let signed = @orderkey.KeySpec::new([Int64Field(Desc)])
  assert_true(
    key_error(() => signed.decode(b"\x01")) is @orderkey.TruncatedKey(1),
  )
}
