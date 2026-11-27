///|
let layout_key = b"\x00orderkey-layout"

///|
fn fixture_spec() -> @orderkey.KeySpec raise @orderkey.KeyError {
  @orderkey.KeySpec::new([
    BytesField(Asc),
    BytesField(Asc),
    Int64Field(Desc),
    Int64Field(Asc),
  ])
}

///|
fn open_fixture(
  spec : @orderkey.KeySpec,
) -> (@moonlsm.MemStorage, @moonlsm.Db[@moonlsm.MemStorage]) raise @moonlsm.LsmError {
  let storage = @moonlsm.MemStorage::new()
  let writer = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  writer.put_deferred(layout_key, spec.layout()) |> ignore
  (storage, writer)
}

///|
fn reopen_fixture(
  storage : @moonlsm.MemStorage,
  writer : @moonlsm.Db[@moonlsm.MemStorage],
  spec : @orderkey.KeySpec,
) -> (@moonlsm.Db[@moonlsm.MemStorage], Int32) raise {
  writer.sync()
  writer.flush()
  writer.close()
  let sst_files = storage.names().filter(name => name.has_suffix(".sst"))
  assert_true(!sst_files.is_empty())
  let db = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  match db.get(layout_key) {
    Some(layout) => spec.require_layout(layout)
    None => abort("missing OrderKey layout")
  }
  (db, sst_files.length())
}

///|
fn scan_fixture(
  db : @moonlsm.Db[@moonlsm.MemStorage],
  count : Int32,
) -> Array[@moonlsm.KvPair] raise @moonlsm.LsmError {
  scan_range(db, Span(b"", None), count + 1)
}

///|
fn emit_fixture_key(
  source : Bytes,
  device : Bytes,
  time : Int64,
  sequence : Int64,
  key : Bytes,
) -> Unit {
  println(
    "key,\{@hex.encode(source[:])},\{@hex.encode(device[:])},\{time},\{sequence},\{@hex.encode(key[:])}",
  )
}

///|
fn storage_key(key : Bytes) -> Bytes {
  let output = @buffer.Buffer()
  output.write_byte(1)
  output.write_bytesview(key[:])
  output.to_bytes()
}
