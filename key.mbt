///|
pub(all) enum Direction {
  Asc
  Desc
}

///|
pub(all) enum Field {
  BytesField(Direction)
  Int64Field(Direction)
}

///|
#derive(Eq, Debug)
pub(all) enum Value {
  Binary(Bytes)
  Signed(Int64)
}

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}

///|
/// Field indexes and byte offsets in errors are zero-based.
#derive(Debug)
pub suberror KeyError {
  EmptySpec
  WrongArity(Int32, Int32)
  InvalidPrefixLength(Int32)
  TypeMismatch(Int32)
  TruncatedKey(Int32)
  InvalidEscape(Int32)
  TrailingBytes(Int32)
  CursorOutsideRange
}

///|
pub extend KeyError with @debug.Debug::{to_repr}

///|
/// A fixed layout for one ordered index. Keys carry no schema metadata.
pub struct KeySpec {
  priv fields : Array[Field]
}

///|
pub fn KeySpec::new(fields : Array[Field]) -> KeySpec raise KeyError {
  if fields.is_empty() {
    raise EmptySpec
  }
  { fields: fields.copy(), }
}

///|
fn Field::direction(self : Field) -> Direction {
  match self {
    BytesField(direction) | Int64Field(direction) => direction
  }
}

///|
fn Direction::mask(self : Direction) -> Byte {
  match self {
    Asc => 0
    Desc => 0xff
  }
}

///|
fn Direction::int64_mask(self : Direction) -> UInt64 {
  match self {
    Asc => 0x8000000000000000UL
    Desc => 0x7fffffffffffffffUL
  }
}

///|
fn write_field(
  output : @buffer.Buffer,
  field : Field,
  value : Value,
  index : Int32,
) -> Unit raise KeyError {
  match (field, value) {
    (BytesField(direction), Binary(bytes)) => {
      let mask = direction.mask()
      for byte in bytes {
        output.write_byte(byte ^ mask)
        if byte == 0 {
          output.write_byte(0xff ^ mask)
        }
      }
      output.write_byte(mask)
      output.write_byte(mask)
    }
    (Int64Field(direction), Signed(number)) =>
      output.write_uint64_be(
        number.reinterpret_as_uint64() ^ direction.int64_mask(),
      )
    _ => raise TypeMismatch(index)
  }
}

///|
fn KeySpec::encode_prefix(
  self : KeySpec,
  values : Array[Value],
) -> Bytes raise KeyError {
  let output = @buffer.Buffer()
  for index, value in values {
    write_field(output, self.fields[index], value, index)
  }
  output.to_bytes()
}

///|
/// Encodes a complete key in unsigned lexicographic byte order.
pub fn KeySpec::encode(
  self : KeySpec,
  values : Array[Value],
) -> Bytes raise KeyError {
  if values.length() != self.fields.length() {
    raise WrongArity(self.fields.length(), values.length())
  }
  self.encode_prefix(values)
}

///|
fn read_binary(
  key : Bytes,
  start : Int32,
  mask : Byte,
) -> (Bytes, Int32) raise KeyError {
  let value = @buffer.Buffer()
  let mut index = start
  while index < key.length() {
    let byte = key[index] ^ mask
    index += 1
    if byte != 0 {
      value.write_byte(byte)
    } else {
      if index == key.length() {
        raise TruncatedKey(index)
      }
      match key[index] ^ mask {
        0 => return (value.to_bytes(), index + 1)
        0xff => value.write_byte(0)
        _ => raise InvalidEscape(index)
      }
      index += 1
    }
  }
  raise TruncatedKey(index)
}

///|
fn read_int64(
  key : Bytes,
  start : Int32,
  direction : Direction,
) -> (Int64, Int32) raise KeyError {
  if key.length() - start < 8 {
    raise TruncatedKey(key.length())
  }
  let mut bits = 0UL
  for index = start; index < start + 8; index = index + 1 {
    bits = (bits << 8) | key[index].to_int().to_uint64()
  }
  ((bits ^ direction.int64_mask()).reinterpret_as_int64(), start + 8)
}

///|
/// Decodes exactly one complete key and rejects trailing bytes.
pub fn KeySpec::decode(
  self : KeySpec,
  key : Bytes,
) -> Array[Value] raise KeyError {
  let values = []
  let mut offset = 0
  for field in self.fields {
    match field {
      BytesField(direction) => {
        let (value, end) = read_binary(key, offset, direction.mask())
        values.push(Binary(value))
        offset = end
      }
      Int64Field(direction) => {
        let (value, end) = read_int64(key, offset, direction)
        values.push(Signed(value))
        offset = end
      }
    }
  }
  if offset != key.length() {
    raise TrailingBytes(offset)
  }
  values
}
