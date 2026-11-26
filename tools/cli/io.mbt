///|
suberror CliError {
  Invalid(String)
}

///|
async fn lock_job(dir : String) -> @fs.File {
  let path = dir + "/.lock"
  if @fs.exists(path) && @fs.kind(path, follow_symlink=false) != @fs.Regular {
    invalid("invalid job lock")
  }
  let lock = @fs.open(path, mode=ReadWrite, create_mode=OpenOrCreate)
  errdefer lock.close()
  if !lock.try_lock(Exclusive) {
    invalid("job is locked")
  }
  lock
}

///|
fn invalid(message : String) -> Unit raise {
  raise Invalid(message)
}

///|
fn object(items : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(items))
}

///|
fn field(value : Json, name : String) -> Json raise {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(item) => item
        None => raise Invalid("missing field " + name)
      }
    _ => raise Invalid("expected JSON object")
  }
}

///|
fn text(value : Json) -> String raise {
  match value {
    String(value) => value
    _ => raise Invalid("expected JSON string")
  }
}

///|
fn hash(bytes : Bytes) -> String {
  let digest = @sha256.Digest::new()
  for byte in bytes {
    digest.write(byte)
  }
  digest.check_sum()
}

///|
fn hex(bytes : Bytes) -> String {
  @hex.encode(bytes[:])
}

///|
fn decode(value : String) -> Bytes raise {
  @hex.decode(value[:])
}

///|
async fn read(path : String, maximum~ : Int32 = 67108864) -> Bytes {
  if @fs.kind(path, follow_symlink=false) != @fs.Regular {
    invalid("expected regular file " + path)
  }
  let input = @fs.open(path, mode=ReadOnly)
  defer input.close()
  let output = @buffer.Buffer()
  let block = FixedArray::make(65536, b'\x00')
  while true {
    let n = input.read(block)
    if n == 0 {
      break
    }
    if output.length() > maximum - n {
      invalid("file exceeds byte limit " + path)
    }
    for i = 0; i < n; i = i + 1 {
      output.write_byte(block[i])
    }
  }
  output.to_bytes()
}

///|
async fn atomic_json(path : String, data : Json) -> Unit {
  @fs.write_file(path + ".tmp", data.stringify(), sync=Full)
  @fs.rename(path + ".tmp", path, replace=true)
}

///|
async fn json_file(path : String) -> Json {
  @json.parse(@utf8.decode(read(path)), reject_duplicate_keys=true)
}

///|
async fn contract(path : String) -> @orderkey.IndexContract {
  let bytes = read(path, maximum=1048576)
  if bytes.length() >= 4 && bytes[:4].to_owned() == b"OKC\x01" {
    return @orderkey.IndexContract::from_bytes(bytes)
  }
  let value = @json.parse(@utf8.decode(bytes), reject_duplicate_keys=true)
  let id = @utf8.encode(text(field(value, "index_id")))
  let generation = @string.parse_uint64(text(field(value, "generation")))
  let fields = match field(value, "fields") {
    Array(fields) => fields
    _ => raise Invalid("fields must be an array")
  }
  let spec = []
  for entry in fields {
    let direction : @orderkey.Direction = match
      text(field(entry, "direction")) {
      "asc" => Asc
      "desc" => Desc
      _ => raise Invalid("unknown field direction")
    }
    let kind : @orderkey.Field = match text(field(entry, "kind")) {
      "bytes" => BytesField(direction)
      "int64" => Int64Field(direction)
      _ => raise Invalid("unknown field kind")
    }
    spec.push((@utf8.encode(text(field(entry, "id"))), kind))
  }
  @orderkey.IndexContract::new(id, generation, spec)
}

///|
struct Row {
  key : Bytes
  value : Bytes
}

///|
fn parse_rows(raw : Bytes) -> Array[Row] raise {
  let rows = []
  let seen : Map[Bytes, Unit] = Map([])
  let source = @utf8.decode(raw)
  let lines = source.split("\n").collect()
  for index, line in lines {
    if line.is_empty() && index == lines.length() - 1 {
      break
    }
    if @utf8.encode(line).length() > 1048576 {
      invalid("row exceeds 1 MiB")
    }
    let value = @json.parse(line, reject_duplicate_keys=true)
    let key = decode(text(field(value, "key_hex")))
    if seen.contains(key) {
      invalid("duplicate key at row " + (index + 1).to_string())
    }
    seen[key] = ()
    rows.push({ key, value: decode(text(field(value, "value_hex"))), })
    if rows.length() > 100000 {
      invalid("row count exceeds 100000")
    }
  }
  rows
}

///|
fn rows_bytes(rows : Array[Row]) -> Bytes {
  let output = @buffer.Buffer()
  for row in rows {
    let line = object([
      ("key_hex", Json::string(hex(row.key))),
      ("value_hex", Json::string(hex(row.value))),
    ])
    output.write_bytes(@utf8.encode(line.stringify())[:])
    output.write_byte(10)
  }
  output.to_bytes()
}

///|
fn prefixed(key : Bytes) -> Bytes {
  let output = @buffer.Buffer()
  output.write_byte(1)
  output.write_bytes(key[:])
  output.to_bytes()
}

///|
async fn regular_files(dir : String) -> Array[String] {
  let files = []
  for name in @fs.readdir(dir, sort=true) {
    match @fs.kind(dir + "/" + name, follow_symlink=false) {
      Regular => files.push(name)
      Directory =>
        for nested in regular_files(dir + "/" + name) {
          files.push(name + "/" + nested)
        }
      _ => invalid("unexpected entry in data directory")
    }
  }
  files
}

///|
async fn put(path : String, bytes : Bytes) -> Unit {
  @fs.write_file(path, bytes, sync=Full)
}

///|
#borrow(path)
extern "C" fn change_directory(path : Bytes, length : Int32) -> Int32 = "orderkey_chdir"

///|
fn enter_directory(path : String) -> Unit raise {
  let bytes = @utf8.encode(path)
  if change_directory(bytes, bytes.length()) != 0 {
    invalid("cannot enter native directory")
  }
}

///|
fn error_message(error : Error) -> String {
  match error {
    Invalid(message)
    | @moonlsm.Io(message)
    | @moonlsm.Corruption(message)
    | @snapshot.InvalidSnapshot(message) => message
    _ => error.to_string()
  }
}
