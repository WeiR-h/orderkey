///|
pub suberror SnapshotError {
  InvalidSnapshot(String)
}

///|
pub(all) struct Record {
  key : Bytes
  value : Bytes
}

///|
pub(all) struct Page {
  rows : Array[Record]
  cursor : Bytes?
  scanned : Int32
}

///|
/// Immutable in-memory session. No filesystem access after open returns.
pub struct Reader {
  priv contract : @orderkey.IndexContract
  priv rows : Array[Record]
  priv map : @fst.FstMap
  priv manifest_hash : String
  priv loaded_bytes : Int64
}

///|
fn digest(bytes : Bytes) -> String {
  let d = @sha256.Digest::new()
  for b in bytes {
    d.write(b)
  }
  d.check_sum()
}

///|
async fn read_file(path : String) -> Bytes {
  if @fs.kind(path, follow_symlink=false) != @fs.Regular {
    raise InvalidSnapshot("expected regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let buffer = @buffer.Buffer()
  let block = FixedArray::make(65536, b'\x00')
  while true {
    let n = file.read(block)
    if n == 0 {
      break
    }
    if buffer.length() > 67108864 - n {
      raise InvalidSnapshot("file exceeds 64 MiB")
    }
    for i = 0; i < n; i = i + 1 {
      buffer.write_byte(block[i])
    }
  }
  buffer.to_bytes()
}

///|
fn property(value : Json, name : String) -> Json raise {
  guard value is Object(fields) else {
    raise InvalidSnapshot("expected object")
  }
  guard fields.get(name) is Some(value) else {
    raise InvalidSnapshot("missing " + name)
  }
  value
}

///|
fn string(value : Json) -> String raise {
  guard value is String(value) else { raise InvalidSnapshot("expected string") }
  value
}

///|
fn parse(raw : Bytes) -> Json raise {
  @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
}

///|
async fn inventory(dir : String) -> Array[String] {
  let files = []
  for name in @fs.readdir(dir, sort=true) {
    match @fs.kind(dir + "/" + name, follow_symlink=false) {
      Regular => files.push(name)
      Directory =>
        for nested in inventory(dir + "/" + name) {
          files.push(name + "/" + nested)
        }
      _ => raise InvalidSnapshot("unexpected entry in database")
    }
  }
  files
}

///|
/// Opens a portable candidate without requiring original input paths.
pub async fn Reader::open(dir : String) -> Reader {
  if @fs.kind(dir, follow_symlink=false) != @fs.Directory {
    raise InvalidSnapshot("expected candidate directory")
  }
  let report_raw = read_file(dir + "/report.json")
  let report = parse(report_raw)
  if property(report, "ready") != Json::boolean(true) {
    raise InvalidSnapshot("candidate is not ready")
  }
  let raw = read_file(dir + "/manifest.json")
  let manifest_hash = digest(raw)
  if string(property(report, "manifest_sha256")) != manifest_hash {
    raise InvalidSnapshot("receipt differs")
  }
  let manifest = parse(raw)
  if property(manifest, "schema_version") != Json::number(1) {
    raise InvalidSnapshot("unsupported manifest")
  }
  guard property(manifest, "files") is Object(expected) else {
    raise InvalidSnapshot("invalid inventory")
  }
  let names = [
    "source.contract", "target.contract", "records.jsonl", "target.fst",
  ]
  for name in inventory(dir + "/db") {
    names.push("db/" + name)
  }
  if expected.length() != names.length() {
    raise InvalidSnapshot("file inventory differs")
  }
  let loaded : Map[String, Bytes] = Map([])
  let mut loaded_bytes = raw.length().to_int64() +
    report_raw.length().to_int64()
  for name in names {
    guard expected.get(name) is Some(sha) else {
      raise InvalidSnapshot("file inventory differs")
    }
    let bytes = read_file(dir + "/" + name)
    loaded_bytes += bytes.length().to_int64()
    if digest(bytes) != string(sha) {
      raise InvalidSnapshot("file digest differs: " + name)
    }
    if !name.has_prefix("db/") {
      loaded[name] = bytes
    }
  }
  let contract = @orderkey.IndexContract::from_bytes(loaded["target.contract"])
  let source = @orderkey.IndexContract::from_bytes(loaded["source.contract"])
  @orderkey.ReindexPlan::new(source, contract) |> ignore
  let rows : Array[Record] = []
  let lines = @utf8.decode(loaded["records.jsonl"]).split("\n").collect()
  for i, line in lines {
    if line.is_empty() && i == lines.length() - 1 {
      break
    }
    if @utf8.encode(line).length() > 1048576 {
      raise InvalidSnapshot("record exceeds 1 MiB")
    }
    let value = @json.parse(line, reject_duplicate_keys=true)
    let key = @hex.decode(string(property(value, "key_hex"))[:])
    let payload = @hex.decode(string(property(value, "value_hex"))[:])
    contract.key_spec().decode(key) |> ignore
    if rows.length() > 0 &&
      rows[rows.length() - 1].key.lexical_compare(key) >= 0 {
      raise InvalidSnapshot("records not strictly ordered")
    }
    rows.push({ key, value: payload, })
    if rows.length() > 100000 {
      raise InvalidSnapshot("too many records")
    }
  }
  if property(manifest, "rows") != Json::number(rows.length().to_double()) {
    raise InvalidSnapshot("row count differs")
  }
  let map = @fst.FstMap::from_bytes(loaded["target.fst"])
  let stream = map.stream()
  defer stream.close()
  let entries = stream.take(rows.length() + 1)
  if entries.length() != rows.length() {
    raise InvalidSnapshot("FST count differs")
  }
  for i, entry in entries {
    if entry.key != rows[i].key || entry.value != i.to_uint64() {
      raise InvalidSnapshot("FST mapping differs")
    }
  }
  if read_file(dir + "/manifest.json") != raw ||
    read_file(dir + "/report.json") != report_raw {
    raise InvalidSnapshot("candidate changed while opening")
  }
  { contract, rows, map, manifest_hash, loaded_bytes, }
}

///|
pub fn Reader::loaded_bytes(self : Reader) -> Int64 {
  self.loaded_bytes
}

///|
pub fn Reader::row_count(self : Reader) -> Int32 {
  self.rows.length()
}

///|
pub fn Reader::plan(
  self : Reader,
  query : @orderkey.QuerySpec,
) -> @orderkey.QueryPlan raise {
  query.plan(self.contract)
}

///|
pub fn Reader::query(
  self : Reader,
  query : @orderkey.QuerySpec,
  limit~ : Int32 = 100,
  cursor~ : Bytes? = None,
) -> Page raise {
  if limit < 1 || limit > 100000 {
    raise InvalidSnapshot("limit must be in 1..100000")
  }
  let plan = query.plan(self.contract)
  let original = plan.byte_range()
  let scope = @utf8.encode(
    digest(
      @utf8.encode(
        "OrderKey/where/v1:" + self.manifest_hash + digest(query.to_bytes()),
      ),
    ),
  )
  let window = match cursor {
    None => original
    Some(token) => self.contract.resume_cursor(scope, original, token)
  }
  let stream = match window {
    Empty => self.map.stream(range=@fst.KeyRange::between(b"", b""))
    Span(first, last) =>
      self.map.stream(range={
        lower: @fst.Included(first),
        upper: match last {
          Some(key) => @fst.Excluded(key)
          None => @fst.Unbounded
        },
      })
  }
  defer stream.close()
  // Pull one entry at a time; a page never materializes the remaining stream.
  let rows = []
  let mut scanned = 0
  let mut last : Bytes? = None
  while true {
    let entries = stream.take(1)
    if entries.is_empty() {
      return { rows, cursor: None, scanned, }
    }
    let entry = entries[0]
    scanned += 1
    last = Some(entry.key)
    let row = self.rows[entry.value.to_int()]
    if plan.matches(row.key) {
      rows.push(row)
      if rows.length() == limit {
        break
      }
    }
  }
  let token = match last {
    None => None
    Some(key) => Some(self.contract.issue_cursor(scope, original, key))
  }
  { rows, cursor: token, scanned, }
}
