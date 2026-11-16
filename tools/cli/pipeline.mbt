///|
struct Input {
  raw : Bytes
  rows : Array[Row]
  source : @orderkey.IndexContract
  target : @orderkey.IndexContract
  fingerprint : String
}

///|
async fn prepare(
  input : String,
  source_path : String,
  target_path : String,
) -> Input {
  let raw = read(input)
  let source = contract(source_path)
  let target = contract(target_path)
  let plan = @orderkey.ReindexPlan::new(source, target)
  let rows = parse_rows(raw)
  for row in rows {
    plan.rekey(row.key) |> ignore
  }
  let fingerprint = hash(
    @utf8.encode(hash(raw) + hash(source.to_bytes()) + hash(target.to_bytes())),
  )
  { raw, rows, source, target, fingerprint, }
}

///|
async fn persisted_input(dir : String) -> Input {
  let plan = json_file(dir + "/plan.json")
  let source = text(field(plan, "input_path"))
  let source_contract = text(field(plan, "source_path"))
  let target_contract = text(field(plan, "target_path"))
  let input = prepare(source, source_contract, target_contract)
  if input.fingerprint != text(field(plan, "fingerprint")) {
    invalid("input or contracts changed")
  }
  input
}

///|
fn target_rows(input : Input) -> Array[Row] raise {
  let plan = @orderkey.ReindexPlan::new(input.source, input.target)
  let rows = input.rows.map(row => {
    key: plan.rekey(row.key),
    value: row.value,
  })
  rows.sort_by(fn(a, b) { a.key.lexical_compare(b.key) })
  rows
}

///|
fn same_rows(actual : Array[Row], expected : Array[Row]) -> Unit raise {
  if actual.length() != expected.length() {
    invalid("record count differs")
  }
  for i, row in actual {
    if row.key != expected[i].key || row.value != expected[i].value {
      invalid("record differs at ordinal " + i.to_string())
    }
  }
}

///|
fn database_rows(dir : String, count : Int32) -> Array[Row] raise {
  let storage = @moonlsm.NativeStorage::new(dir)
  defer storage.close()
  let db = @moonlsm.Db::open(storage, 1048576)
  defer db.close()
  db
  .scan(b"\x01", b"\x02", count + 1)
  .map(fn(row) { { key: row.key[1:].to_owned(), value: row.value, } })
}

///|
async fn build_database(dir : String, input : Input) -> Unit {
  @fs.mkdir(dir)
  let storage = @moonlsm.NativeStorage::new(dir)
  defer storage.close()
  let db = @moonlsm.Db::open(storage, 1048576)
  defer db.close()
  let plan = @orderkey.ReindexPlan::new(input.source, input.target)
  for row in input.rows {
    db.put_deferred(prefixed(plan.rekey(row.key)), row.value) |> ignore
  }
  db.sync()
  db.flush()
}

///|
async fn snapshot(dir : String, input : Input) -> Unit {
  let rows = database_rows(dir + "/db", input.rows.length())
  same_rows(rows, target_rows(input))
  let builder = @fst.Builder::map()
  for index, row in rows {
    builder.insert(row.key, index.to_uint64())
  }
  put(dir + "/target.fst", builder.finish())
  put(dir + "/records.jsonl", rows_bytes(rows))
}

///|
async fn file_manifest(dir : String) -> Json {
  let files = [
    "source.contract", "target.contract", "records.jsonl", "target.fst",
  ]
  for name in regular_files(dir + "/db") {
    files.push("db/" + name)
  }
  let entries = []
  for name in files {
    entries.push((name, Json::string(hash(read(dir + "/" + name)))))
  }
  object(entries)
}

///|
async fn check_hashes(dir : String, manifest : Json) -> Unit {
  let files = match field(manifest, "files") {
    Object(files) => files
    _ => raise Invalid("invalid file manifest")
  }
  let expected = file_manifest(dir)
  if expected != field(manifest, "files") {
    invalid("candidate file inventory or digest differs")
  }
  files |> ignore
}

///|
async fn verify_contents(dir : String, input : Input) -> Unit {
  let rows = parse_rows(read(dir + "/records.jsonl"))
  same_rows(rows, target_rows(input))
  input.source.require_same(read(dir + "/source.contract"))
  input.target.require_same(read(dir + "/target.contract"))
  let map = @fst.FstMap::from_bytes(read(dir + "/target.fst"))
  let stream = map.stream()
  defer stream.close()
  let entries = stream.take(rows.length() + 1)
  if entries.length() != rows.length() {
    invalid("FST row count differs")
  }
  for index, entry in entries {
    if entry.key != rows[index].key || entry.value != index.to_uint64() {
      invalid("FST ordinal mismatch")
    }
  }
  // Db::open may create metadata. Verify a private copy instead of changing
  // the immutable candidate database.
  let mut number = 0
  while @fs.exists(dir + "/check-" + number.to_string()) {
    number += 1
  }
  let check_dir = dir + "/check-" + number.to_string()
  @fs.mkdir(check_dir)
  @fs.mkdir(check_dir + "/sst")
  @fs.mkdir(check_dir + "/wal")
  defer @fs.rmdir(check_dir, recursive=true)
  for name in regular_files(dir + "/db") {
    put(check_dir + "/" + name, read(dir + "/db/" + name))
  }
  same_rows(database_rows(check_dir, rows.length()), rows)
}

///|
async fn finish(dir : String, input : Input) -> Unit {
  verify_contents(dir, input)
  let latest = persisted_input(dir)
  if latest.fingerprint != input.fingerprint {
    invalid("source changed during rebuild")
  }
  let manifest = object([
    ("schema_version", Json::number(1)),
    ("version", Json::string(tool_version)),
    ("build_commit", Json::string(build_commit)),
    ("fingerprint", Json::string(input.fingerprint)),
    ("source_sha256", Json::string(hash(input.raw))),
    ("snapshot_id", Json::string(hash(read(dir + "/target.fst")))),
    ("rows", Json::number(input.rows.length().to_double())),
    ("files", file_manifest(dir)),
  ])
  atomic_json(dir + "/manifest.json", manifest)
  atomic_json(
    dir + "/report.json",
    object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(true)),
      ("phase", Json::string("complete")),
      ("fingerprint", Json::string(input.fingerprint)),
      ("first_difference", Json::null()),
      ("manifest_sha256", Json::string(hash(read(dir + "/manifest.json")))),
    ]),
  )
}

///|
async fn require_ready(dir : String) -> Json {
  let report = json_file(dir + "/report.json")
  if field(report, "ready") != Json::boolean(true) {
    invalid("candidate is not verified")
  }
  let manifest = json_file(dir + "/manifest.json")
  if text(field(report, "manifest_sha256")) !=
    hash(read(dir + "/manifest.json")) {
    invalid("manifest differs from the verified receipt")
  }
  check_hashes(dir, manifest)
  manifest
}
