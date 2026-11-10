///|
/// A bound on the next field in its logical, ascending value order.
pub(all) enum Bound {
  Unbounded
  Inclusive(Value)
  Exclusive(Value)
}

///|
/// A half-open byte range. A missing upper bound means positive infinity.
#derive(Eq, Debug)
pub(all) enum ByteRange {
  Empty
  Span(Bytes, Bytes?)
}

///|
pub extend ByteRange with Eq::{equal, not_equal}

///|
pub extend ByteRange with @debug.Debug::{to_repr}

///|
pub fn ByteRange::contains(self : ByteRange, key : Bytes) -> Bool {
  match self {
    Empty => false
    Span(start, Some(end)) =>
      start.lexical_compare(key) <= 0 && key.lexical_compare(end) < 0
    Span(start, None) => start.lexical_compare(key) <= 0
  }
}

///|
fn prefix_end(prefix : Bytes) -> Bytes? {
  for index = prefix.length() - 1; index >= 0; index = index - 1 {
    let byte = prefix[index]
    if byte != 0xff {
      let output = @buffer.Buffer(size_hint=index + 1)
      output.write_bytes(prefix[:index])
      output.write_byte((byte.to_int() + 1).to_byte())
      return Some(output.to_bytes())
    }
  }
  None
}

///|
fn bounded_span(start : Bytes?, end : Bytes?) -> ByteRange {
  match start {
    None => Empty
    Some(start) =>
      match end {
        Some(end) if start.lexical_compare(end) >= 0 => Empty
        _ => Span(start, end)
      }
  }
}

///|
/// Matches complete fields at the start of a key. An empty prefix matches
/// the entire index. Each index must use the same spec for every key.
pub fn KeySpec::prefix_range(
  self : KeySpec,
  prefix : Array[Value],
) -> ByteRange raise KeyError {
  if prefix.length() > self.fields.length() {
    raise InvalidPrefixLength(prefix.length())
  }
  let start = self.encode_prefix(prefix)
  Span(start, prefix_end(start))
}

///|
fn encode_endpoint(
  prefix : Bytes,
  field : Field,
  index : Int32,
  bound : Bound,
  is_start : Bool,
) -> Bytes? raise KeyError {
  let (value, inclusive) = match bound {
    Unbounded => return if is_start { Some(prefix) } else { prefix_end(prefix) }
    Inclusive(value) => (value, true)
    Exclusive(value) => (value, false)
  }
  let output = @buffer.from_bytes(prefix[:])
  write_field(output, field, value, index)
  let key = output.to_bytes()
  // Inclusive starts and exclusive ends already have the required byte bound.
  if inclusive == is_start {
    Some(key)
  } else {
    prefix_end(key)
  }
}

///|
/// Compiles equality on the leading fields and an interval on the next field
/// into a single byte range. Remaining fields can have any value.
pub fn KeySpec::field_range(
  self : KeySpec,
  prefix : Array[Value],
  lower : Bound,
  upper : Bound,
) -> ByteRange raise KeyError {
  let index = prefix.length()
  if index >= self.fields.length() {
    raise InvalidPrefixLength(index)
  }
  let encoded_prefix = self.encode_prefix(prefix)
  let field = self.fields[index]
  let (first, last) = match field.direction() {
    Asc => (lower, upper)
    Desc => (upper, lower)
  }
  let start = encode_endpoint(encoded_prefix, field, index, first, true)
  let end = encode_endpoint(encoded_prefix, field, index, last, false)
  bounded_span(start, end)
}

///|
/// Restricts the range to keys strictly after a complete key from that range.
pub fn KeySpec::resume_after(
  self : KeySpec,
  range : ByteRange,
  cursor : Bytes,
) -> ByteRange raise KeyError {
  self.decode(cursor) |> ignore
  match range {
    Span(_, end) if range.contains(cursor) => {
      let output = @buffer.from_bytes(cursor[:])
      // Appending 00 is the smallest byte string greater than the cursor.
      output.write_byte(0)
      bounded_span(Some(output.to_bytes()), end)
    }
    _ => raise CursorOutsideRange
  }
}
