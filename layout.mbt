///|
/// Store this descriptor alongside the index, outside the ordered data keys.
pub fn KeySpec::layout(self : KeySpec) -> Bytes {
  let descriptor = @buffer.Buffer(size_hint=3 + self.fields.length())
  descriptor.write_bytes(b"OK\x01"[:])
  for field in self.fields {
    descriptor.write_byte(
      match field {
        BytesField(Asc) => 0x10
        BytesField(Desc) => 0x11
        Int64Field(Asc) => 0x20
        Int64Field(Desc) => 0x21
      },
    )
  }
  descriptor.to_bytes()
}

///|
/// Reconstructs a spec from a persisted v1 layout descriptor.
pub fn KeySpec::from_layout(descriptor : Bytes) -> KeySpec raise KeyError {
  if descriptor.length() == 0 || descriptor[0] != b'O' {
    raise InvalidLayout(0)
  }
  if descriptor.length() < 2 || descriptor[1] != b'K' {
    raise InvalidLayout(1)
  }
  if descriptor.length() < 3 {
    raise InvalidLayout(2)
  }
  if descriptor[2] != 1 {
    raise UnsupportedKeyFormat(descriptor[2])
  }
  if descriptor.length() == 3 {
    raise InvalidLayout(3)
  }
  let fields = []
  for index = 3; index < descriptor.length(); index = index + 1 {
    fields.push(
      match descriptor[index] {
        0x10 => BytesField(Asc)
        0x11 => BytesField(Desc)
        0x20 => Int64Field(Asc)
        0x21 => Int64Field(Desc)
        _ => raise InvalidLayout(index)
      },
    )
  }
  { fields, }
}

///|
/// Checks the stored key format, field types and directions before opening an index.
pub fn KeySpec::require_layout(
  self : KeySpec,
  descriptor : Bytes,
) -> Unit raise KeyError {
  if descriptor != self.layout() {
    KeySpec::from_layout(descriptor) |> ignore
    raise LayoutMismatch
  }
}
