///|
fn option(
  args : Array[String],
  name : String,
  fallback~ : String = "",
) -> String raise {
  for i = 0; i < args.length(); i = i + 1 {
    if args[i] == name {
      if i + 1 == args.length() {
        invalid("missing value for " + name)
      }
      return args[i + 1]
    }
  }
  fallback
}

///|
async fn query(args : Array[String], dir : String) -> Unit {
  let manifest = require_ready(dir)
  let spec = @orderkey.IndexContract::from_bytes(read(dir + "/target.contract"))
  let start = decode(option(args, "--start-hex"))
  let upper = option(args, "--end-hex", fallback="unbounded")
  let range = @orderkey.Span(
    start,
    if upper == "unbounded" {
      None
    } else {
      Some(decode(upper))
    },
  )
  let snapshot_id = @utf8.encode(text(field(manifest, "snapshot_id")))
  let token = option(args, "--cursor")
  let window = if token.is_empty() {
    range
  } else {
    spec.resume_cursor(snapshot_id, range, decode(token))
  }
  let limit = @string.parse_int(option(args, "--limit", fallback="100"))
  if limit <= 0 || limit > 100000 {
    invalid("limit must be in 1..100000")
  }
  let rows = parse_rows(read(dir + "/records.jsonl"))
  let map = @fst.FstMap::from_bytes(read(dir + "/target.fst"))
  let stream = match window {
    Empty => map.stream(range=@fst.KeyRange::between(b"", b""))
    Span(first, last) =>
      map.stream(range={
        lower: @fst.Included(first),
        upper: match last {
          None => @fst.Unbounded
          Some(last) => @fst.Excluded(last)
        },
      })
  }
  defer stream.close()
  let entries = stream.take(limit)
  let output = []
  for entry in entries {
    let row = rows[entry.value.to_int()]
    output.push(
      object([
        ("key_hex", Json::string(hex(entry.key))),
        ("value_hex", Json::string(hex(row.value))),
      ]),
    )
  }
  let cursor = if entries.is_empty() {
    Json::null()
  } else {
    Json::string(
      hex(
        spec.issue_cursor(snapshot_id, range, entries[entries.length() - 1].key),
      ),
    )
  }
  println(
    object([("rows", Json::array(output)), ("cursor", cursor)]).stringify(),
  )
}

///|
async fn execute(args : Array[String]) -> Unit {
  let command = args[1]
  if command == "version" {
    println(
      object([
        ("version", Json::string(tool_version)),
        ("build_commit", Json::string(build_commit)),
        ("compiler", Json::string(build_compiler)),
        ("dirty", Json::boolean(build_dirty)),
      ]).stringify(),
    )
    return
  }
  if command == "explain" {
    explain(args)
    return
  }
  if !["plan", "build", "resume", "verify", "query", "check-queries"].contains(
      command,
    ) {
    invalid("unknown command " + command)
  }
  let dir = option(args, "--out")
  if command == "plan" {
    let input = prepare(
      option(args, "--input"),
      option(args, "--source-contract"),
      option(args, "--target-contract"),
    )
    println(
      object([
        ("rows", Json::number(input.rows.length().to_double())),
        ("fingerprint", Json::string(input.fingerprint)),
      ]).stringify(),
    )
    return
  }
  if command == "build" {
    @fs.mkdir(dir, allow_exist=false)
  }
  if @fs.kind(dir, follow_symlink=false) != @fs.Directory {
    invalid("expected job directory")
  }
  let dir = @fs.realpath(dir)
  let lock_path = dir + "/.lock"
  if @fs.exists(lock_path) &&
    @fs.kind(lock_path, follow_symlink=false) != @fs.Regular {
    invalid("invalid job lock")
  }
  let lock = @fs.open(lock_path, mode=ReadWrite, create_mode=OpenOrCreate)
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    invalid("job is locked")
  }
  if command == "query" {
    if args.contains("--where") {
      semantic_query(args, dir)
    } else {
      query(args, dir)
    }
    return
  }
  if command == "check-queries" {
    check_queries(args, dir)
    return
  }
  let run_id = @async.now().to_string()
  atomic_json(
    dir + "/report.json",
    object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(false)),
      ("run_id", Json::string(run_id)),
      ("phase", Json::string(command)),
    ]),
  )
  try {
    if command == "build" {
      progress(dir, "preflight")
      let input_path = @fs.realpath(option(args, "--input"))
      let source_path = @fs.realpath(option(args, "--source-contract"))
      let target_path = @fs.realpath(option(args, "--target-contract"))
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
      put(dir + "/source.contract", input.source.to_bytes())
      put(dir + "/target.contract", input.target.to_bytes())
    }
    let input = persisted_input(dir)
    input.source.require_same(read(dir + "/source.contract"))
    input.target.require_same(read(dir + "/target.contract"))
    if command == "verify" {
      check_hashes(dir, json_file(dir + "/manifest.json"))
    } else {
      resume_stages(dir, input, args)
    }
    finish(dir, input)
    inject(args, "complete")
    println("verified " + dir)
  } catch {
    error => {
      atomic_json(
        dir + "/report.json",
        object([
          ("schema_version", Json::number(1)),
          ("ready", Json::boolean(false)),
          ("run_id", Json::string(run_id)),
          ("phase", Json::string(command)),
          ("failed_stage", field(json_file(dir + "/report.json"), "phase")),
          ("first_difference", Json::string(error_message(error))),
        ]),
      )
      raise Invalid(error_message(error))
    }
  }
}

///|
extern "C" fn exit_process(code : Int32) -> Unit = "exit"

///|
async fn main {
  let args = @env.args()
  if args.length() < 2 {
    println(
      "OrderKey " +
      tool_version +
      " version|plan|build|resume|verify|query|explain|check-queries --input FILE --source-contract FILE --target-contract FILE --out DIR",
    )
    return
  }
  execute(args) catch {
    @moonlsm.Io(message) => {
      println(
        object([
          ("ready", Json::boolean(false)),
          ("error", Json::string(message)),
        ]).stringify(),
      )
      exit_process(1)
    }
    error => {
      println(
        object([
          ("ready", Json::boolean(false)),
          ("error", Json::string(error_message(error))),
        ]).stringify(),
      )
      exit_process(1)
    }
  }
}
