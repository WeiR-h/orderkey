///|
/// Failures when reading or comparing index and cursor metadata.
#derive(Debug)
pub suberror ContractError {
  InvalidContract
  ContractMismatch
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
fn write_part(buffer : @buffer.Buffer, bytes : Bytes) -> Unit {
  let length = bytes.length()
  for shift = 24; shift >= 0; shift = shift - 8 {
    buffer.write_byte((length >> shift).to_byte())
  }
  buffer.write_bytes(bytes[:])
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
  buffer.write_bytes(b"OKC\x01"[:])
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
