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
async fn record_plan(
  dir : String,
  input_path : String,
  source_path : String,
  target_path : String,
) -> Unit {
  let input_path = @fs.realpath(input_path)
  let source_path = @fs.realpath(source_path)
  let target_path = @fs.realpath(target_path)
  let input = prepare(input_path, source_path, target_path)
  atomic_json(
    dir + "/plan.json",
    object([
      ("input_path", Json::string(input_path)),
      ("source_path", Json::string(source_path)),
      ("target_path", Json::string(target_path)),
      ("fingerprint", Json::string(input.fingerprint)),
    ]),
  )
  for
    (name, expected) in [
      ("source.contract", input.source.to_bytes()),
      ("target.contract", input.target.to_bytes()),
    ] {
    let path = dir + "/" + name
    if @fs.exists(path) {
      if read(path) != expected {
        invalid("job " + name + " differs")
      }
    } else {
      put(path + ".tmp", expected)
      @fs.rename(path + ".tmp", path)
    }
  }
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
    invalid(
      "record count differs: expected=" +
      expected.length().to_string() +
      " actual=" +
      actual.length().to_string(),
    )
  }
  for i, row in actual {
    if row.key != expected[i].key || row.value != expected[i].value {
      invalid(
        "record differs at ordinal " +
        i.to_string() +
        " expected_key=" +
        hex(expected[i].key) +
        " actual_key=" +
        hex(row.key) +
        " expected_value_sha256=" +
        hash(expected[i].value) +
        " actual_value_sha256=" +
        hash(row.value),
      )
    }
  }
}

///|
async fn database_rows(dir : String, count : Int32) -> Array[Row] {
  let absolute = @fs.realpath(dir)
  let previous = @fs.realpath(".")
  enter_directory(absolute)
  defer enter_directory(previous)
  let storage = @moonlsm.NativeStorage::new(".")
  defer storage.close()
  let db = @moonlsm.Db::open(storage, 1048576)
  defer db.close()
  db
  .scan(b"\x01", b"\x02", count + 1)
  .map(fn(row) { { key: row.key[1:].to_owned(), value: row.value, } })
}

///|
async fn build_database(
  dir : String,
  input : Input,
  args : Array[String],
) -> Unit {
  @fs.mkdir(dir)
  let absolute = @fs.realpath(dir)
  let previous = @fs.realpath(".")
  enter_directory(absolute)
  defer enter_directory(previous)
  let storage = @moonlsm.NativeStorage::new(".")
  defer storage.close()
  let db = @moonlsm.Db::open(storage, 1048576)
  defer db.close()
  let plan = @orderkey.ReindexPlan::new(input.source, input.target)
  for index, row in input.rows {
    if index == 1024 {
      inject(args, "writing")
    }
    db.put_deferred(prefixed(plan.rekey(row.key)), row.value) |> ignore
  }
  match option(args, "--fail-io") {
    "write" => storage.write_file("missing-parent/blocked", b"")
    "sync" => storage.sync_file("missing-sync-file")
    "" => ()
    _ => invalid("unknown I/O failure mode")
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
async fn verify_contents(
  dir : String,
  input : Input,
  scratch_root~ : String = dir,
) -> Unit {
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
  while @fs.exists(scratch_root + "/check-" + number.to_string()) {
    number += 1
  }
  let check_dir = scratch_root + "/check-" + number.to_string()
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
    (
      "snapshot_id",
      Json::string(
        hash(
          @utf8.encode(
            input.fingerprint +
            hash(read(dir + "/target.fst")) +
            hash(read(dir + "/records.jsonl")),
          ),
        ),
      ),
    ),
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

///|
fn inject(args : Array[String], phase : String) -> Unit raise {
  if option(args, "--fail-after") == phase {
    invalid("injected failure after " + phase)
  }
  if option(args, "--pause-after") == phase {
    println("paused " + phase)
    @moonlsm.flush_stdio()
    pause_process(30000)
  }
}

///|
extern "C" fn pause_process(ms : Int32) -> Unit = "orderkey_pause"

///|
async fn checkpoint_files(dir : String, full : Bool) -> Json {
  if full {
    return file_manifest(dir)
  }
  let entries = []
  for name in regular_files(dir + "/db") {
    entries.push(("db/" + name, Json::string(hash(read(dir + "/db/" + name)))))
  }
  object(entries)
}

///|
async fn resume_stages(
  dir : String,
  input : Input,
  args : Array[String],
) -> Unit {
  let checkpoint = dir + "/checkpoint.json"
  let mut phase = ""
  if @fs.exists(checkpoint) {
    let saved = json_file(checkpoint)
    if text(field(saved, "fingerprint")) != input.fingerprint {
      invalid("checkpoint identity differs")
    }
    phase = text(field(saved, "phase"))
    if !["database", "snapshot", "verified"].contains(phase) {
      invalid("unknown checkpoint stage")
    }
    if checkpoint_files(dir, phase != "database") != field(saved, "files") {
      invalid("checkpoint file digest differs")
    }
  }
  if phase == "" {
    // Each interrupted database attempt is kept, so restarting never recursively
    // deletes a caller's files.
    if @fs.exists(dir + "/db") {
      let mut n = 0
      while @fs.exists(dir + "/abandoned-db-" + n.to_string()) {
        n += 1
      }
      @fs.rename(dir + "/db", dir + "/abandoned-db-" + n.to_string())
    }
    progress(dir, "database")
    build_database(dir + "/db", input, args)
    atomic_json(
      checkpoint,
      object([
        ("phase", Json::string("database")),
        ("fingerprint", Json::string(input.fingerprint)),
        ("files", checkpoint_files(dir, false)),
      ]),
    )
    phase = "database"
    inject(args, "database")
  }
  if phase == "database" {
    progress(dir, "snapshot")
    snapshot(dir, input)
    atomic_json(
      checkpoint,
      object([
        ("phase", Json::string("snapshot")),
        ("fingerprint", Json::string(input.fingerprint)),
        ("files", checkpoint_files(dir, true)),
      ]),
    )
    inject(args, "snapshot")
  }
  verify_contents(dir, input)
  atomic_json(
    checkpoint,
    object([
      ("phase", Json::string("verified")),
      ("fingerprint", Json::string(input.fingerprint)),
      ("files", checkpoint_files(dir, true)),
    ]),
  )
  inject(args, "verified")
}

///|
async fn progress(dir : String, phase : String) -> Unit {
  let state = json_file(dir + "/report.json")
  match state {
    Object(fields) => {
      fields["phase"] = Json::string(phase)
      atomic_json(dir + "/report.json", Json::object(fields))
    }
    _ => invalid("invalid report state")
  }
}
