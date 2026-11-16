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
async fn execute(args : Array[String]) -> Unit {
  let command = args[1]
  let dir = option(args, "--out")
  if command == "plan" || command == "build" {
    let input_path = @fs.realpath(option(args, "--input"))
    let source_path = @fs.realpath(option(args, "--source-contract"))
    let target_path = @fs.realpath(option(args, "--target-contract"))
    let input = prepare(input_path, source_path, target_path)
    if command == "plan" {
      println(
        object([
          ("rows", Json::number(input.rows.length().to_double())),
          ("fingerprint", Json::string(input.fingerprint)),
        ]).stringify(),
      )
      return
    }
    @fs.mkdir(dir, allow_exist=false)
    atomic_json(
      dir + "/report.json",
      object([
        ("schema_version", Json::number(1)),
        ("ready", Json::boolean(false)),
        ("phase", Json::string("building")),
      ]),
    )
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
    build_database(dir + "/db", input)
    snapshot(dir, input)
    finish(dir, input)
    println("verified " + dir)
  } else if command == "verify" {
    let manifest = require_ready(dir)
    let input = persisted_input(dir)
    if input.fingerprint != text(field(manifest, "fingerprint")) {
      invalid("input fingerprint differs")
    }
    verify_contents(dir, input)
    println("verified " + dir)
  } else if command == "query" {
    let manifest = require_ready(dir)
    let spec = @orderkey.IndexContract::from_bytes(
      read(dir + "/target.contract"),
    )
    let start = decode(option(args, "--start-hex"))
    let upper = option(args, "--end-hex")
    let range = @orderkey.Span(
      start,
      if upper.is_empty() {
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
          spec.issue_cursor(
            snapshot_id,
            range,
            entries[entries.length() - 1].key,
          ),
        ),
      )
    }
    println(
      object([("rows", Json::array(output)), ("cursor", cursor)]).stringify(),
    )
  } else {
    invalid("unknown command " + command)
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
      " plan|build|verify|query --input FILE --source-contract FILE --target-contract FILE --out DIR",
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
          ("error", Json::string(error.to_string())),
        ]).stringify(),
      )
      exit_process(1)
    }
  }
}
