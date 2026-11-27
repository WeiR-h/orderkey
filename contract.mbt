///|
/// Failures when reading or comparing index and cursor metadata.
#derive(Debug)
pub suberror ContractError {
  InvalidContract
  ContractMismatch
  InvalidCursor
  CursorScopeMismatch
}

///|
pub extend ContractError with @debug.Debug::{to_repr}

///|
/// Logical identity and physical layout for one generation of an index.
/// Field identifiers are application-assigned, nonempty byte strings.
pub struct IndexContract {
  priv index_id : Bytes
  priv generation : UInt64
  priv field_ids : Array[Bytes]
  priv spec : KeySpec
}

///|
pub fn IndexContract::new(
  index_id : Bytes,
  generation : UInt64,
  fields : Array[(Bytes, Field)],
) -> IndexContract raise ContractError {
  if index_id.is_empty() || fields.is_empty() {
    raise InvalidContract
  }
  let field_ids = []
  let kinds = []
  let seen : Map[Bytes, Unit] = Map([])
  for pair in fields {
    let (field_id, field) = pair
    if field_id.is_empty() || seen.contains(field_id) {
      raise InvalidContract
    }
    seen[field_id] = ()
    field_ids.push(field_id)
    kinds.push(field)
  }
  { index_id, generation, field_ids, spec: { fields: kinds, }, }
}

///|
pub fn IndexContract::key_spec(self : IndexContract) -> KeySpec {
  self.spec
}

///|
/// Ordered field identities and types. The returned array is independent.
pub fn IndexContract::fields(self : IndexContract) -> Array[(Bytes, Field)] {
  self.field_ids.mapi((i, id) => (id, self.spec.fields[i]))
}

///|
/// A new generation of the same logical index. A saturated generation fails.
pub fn IndexContract::successor(
  self : IndexContract,
  fields : Array[(Bytes, Field)],
) -> IndexContract raise ContractError {
  if self.generation == 18446744073709551615UL {
    raise InvalidContract
  }
  IndexContract::new(self.index_id, self.generation + 1UL, fields)
}

///|
fn write_part(buffer : @buffer.Buffer, bytes : Bytes) -> Unit {
  let length = bytes.length()
  for shift = 24; shift >= 0; shift = shift - 8 {
    buffer.write_byte((length >> shift).to_byte())
  }
  buffer.write_bytesview(bytes[:])
}

///|
/// Reads a length-prefixed byte string without overflowing an offset.
fn read_part(
  input : Bytes,
  start : Int32,
) -> (Bytes, Int32) raise ContractError {
  if input.length() - start < 4 {
    raise InvalidContract
  }
  let mut length = 0U
  for i = start; i < start + 4; i = i + 1 {
    length = (length << 8) | input[i].to_int().reinterpret_as_uint()
  }
  let first = start + 4
  if length > (input.length() - first).reinterpret_as_uint() {
    raise InvalidContract
  }
  let end = first + length.reinterpret_as_int()
  (input[first:end].to_owned(), end)
}

///|
/// Canonical v1 metadata: OKC 01, generation (u64 BE), then u32-length
/// byte strings for index ID, v1 key layout, and each ordered field ID.
pub fn IndexContract::to_bytes(self : IndexContract) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_bytesview(b"OKC\x01"[:])
  buffer.write_uint64_be(self.generation)
  write_part(buffer, self.index_id)
  write_part(buffer, self.spec.layout())
  for field_id in self.field_ids {
    write_part(buffer, field_id)
  }
  buffer.to_bytes()
}

///|
pub fn IndexContract::from_bytes(
  input : Bytes,
) -> IndexContract raise ContractError {
  if input.length() < 12 || input[:4].to_owned() != b"OKC\x01" {
    raise InvalidContract
  }
  let mut generation = 0UL
  for i = 4; i < 12; i = i + 1 {
    generation = (generation << 8) | input[i].to_int().to_uint64()
  }
  let (index_id, layout_start) = read_part(input, 12)
  let (layout, fields_start) = read_part(input, layout_start)
  let spec = KeySpec::from_layout(layout) catch { _ => raise InvalidContract }
  let fields = []
  let mut offset = fields_start
  for field in spec.fields {
    let (field_id, next) = read_part(input, offset)
    fields.push((field_id, field))
    offset = next
  }
  if offset != input.length() {
    raise InvalidContract
  }
  IndexContract::new(index_id, generation, fields)
}

///|
pub fn IndexContract::require_same(
  self : IndexContract,
  persisted : Bytes,
) -> Unit raise ContractError {
  if self.to_bytes() != persisted {
    IndexContract::from_bytes(persisted) |> ignore
    raise ContractMismatch
  }
}

///|
fn IndexContract::cursor_scope(
  self : IndexContract,
  snapshot_id : Bytes,
  range : ByteRange,
) -> Bytes raise ContractError {
  if snapshot_id.is_empty() {
    raise InvalidCursor
  }
  let (start, end) = match range {
    Empty => raise InvalidCursor
    Span(start, end) => (start, end)
  }
  let buffer = @buffer.Buffer()
  buffer.write_bytesview(b"OKP\x01"[:])
  write_part(buffer, self.to_bytes())
  write_part(buffer, snapshot_id)
  write_part(buffer, start)
  match end {
    None => buffer.write_byte(0)
    Some(end) => {
      buffer.write_byte(1)
      write_part(buffer, end)
    }
  }
  buffer.to_bytes()
}

///|
/// Issues a cursor for the last actual key of a page in the original range.
/// Use a stable snapshot ID supplied by the storage layer. This is a scope
/// check for trusted cursors, so applications exposing tokens authenticate them.
pub fn IndexContract::issue_cursor(
  self : IndexContract,
  snapshot_id : Bytes,
  range : ByteRange,
  last_key : Bytes,
) -> Bytes raise {
  let scope = self.cursor_scope(snapshot_id, range)
  self.spec.resume_after(range, last_key) |> ignore
  let buffer = @buffer.from_bytes(scope[:])
  write_part(buffer, last_key)
  buffer.to_bytes()
}

///|
/// Resumes strictly after the saved key, using the same original range.
pub fn IndexContract::resume_cursor(
  self : IndexContract,
  snapshot_id : Bytes,
  range : ByteRange,
  token : Bytes,
) -> ByteRange raise {
  if token.length() < 4 || token[:4].to_owned() != b"OKP\x01" {
    raise InvalidCursor
  }
  let scope = self.cursor_scope(snapshot_id, range)
  let size = scope.length()
  if token.length() < size || token[:size].to_owned() != scope {
    raise CursorScopeMismatch
  }
  let (last_key, end) = read_part(token, size) catch {
    _ => raise InvalidCursor
  }
  if end != token.length() {
    raise InvalidCursor
  }
  self.spec.resume_after(range, last_key)
}
