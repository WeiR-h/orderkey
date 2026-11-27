///|
async fn probe_database(
  dir : String,
  windows : Array[@orderkey.ByteRange],
  count : Int32,
) -> Array[Row] {
  if windows.all(window => window is Empty) {
    return []
  }
  let absolute = @fs.realpath(dir)
  let previous = @fs.realpath(".")
  enter_directory(absolute)
  defer enter_directory(previous)
  let storage = @moonlsm.NativeStorage::new(".")
  defer storage.close()
  let db = @moonlsm.Db::open(storage, 1048576)
  defer db.close()
  let rows = []
  for window in windows {
    guard window is Span(first, last) else { continue }
    for
      row in db.scan(
        prefixed(first),
        last.map(prefixed).unwrap_or(b"\x02"),
        count + 1,
      ) {
      rows.push({ key: row.key[1:].to_owned(), value: row.value, })
    }
  }
  rows
}

///|
async fn write_source_database(dir : String, rows : Array[Row]) -> Unit {
  @fs.mkdir(dir)
  let previous = @fs.realpath(".")
  let absolute = @fs.realpath(dir)
  enter_directory(absolute)
  defer enter_directory(previous)
  let storage = @moonlsm.NativeStorage::new(".")
  defer storage.close()
  let db = @moonlsm.Db::open(storage, 1048576)
  defer db.close()
  for row in rows {
    db.put_deferred(prefixed(row.key), row.value) |> ignore
  }
  db.sync()
  db.flush()
}

///|
fn logical_rows(
  rows : Array[Row],
  contract : @orderkey.IndexContract,
) -> Array[Row] raise {
  let logical = rows.map(row => {
    key: contract.logical_key(row.key),
    value: row.value,
  })
  logical.sort_by((a, b) => a.key.lexical_compare(b.key))
  logical
}

///|
fn positive_integer(
  value : Json,
  name : String,
  fallback : Int32,
) -> Int32 raise {
  match optional(value, name) {
    None => fallback
    Some(Number(number, ..)) if number >= 1.0 &&
      number <= 100000.0 &&
      number == number.to_int().to_double() => number.to_int()
    _ => raise Invalid(name + " must be an integer in 1..100000")
  }
}

///|
fn measured_rows_sha256(rows : Array[Row]) -> String {
  let digest = @sha256.Digest::new()
  for row in rows {
    for bytes in [row.key, row.value] {
      hash_framed(digest, bytes)
    }
  }
  digest.check_sum()
}

///|
async fn workload(
  args : Array[String],
  dir : String,
  replay_source~ : Bool = true,
  mode~ : ScanMode = Single,
  evidence~ : Bool = false,
) -> Json {
  let input = persisted_input(dir)
  let path = option(args, "--queries")
  let raw = read(path, maximum=1048576)
  let measured = measure_workload(
    dir,
    input,
    raw,
    dir,
    replay_source~,
    mode~,
    evidence~,
  )
  if persisted_input(dir).fingerprint != input.fingerprint ||
    read(path, maximum=1048576) != raw {
    invalid("input or workload changed during verification")
  }
  measured
}

///|
async fn measure_workload(
  dir : String,
  input : Input,
  raw : Bytes,
  scratch_root : String,
  replay_source~ : Bool = true,
  mode~ : ScanMode = Single,
  evidence~ : Bool = false,
) -> Json {
  let manifest = require_ready(dir)
  let manifest_hash = hash(read(dir + "/manifest.json"))
  if field(manifest, "fingerprint") != Json::string(input.fingerprint) ||
    field(manifest, "source_sha256") != Json::string(hash(input.raw)) {
    invalid("delivery belongs to another frozen export or contract")
  }
  verify_contents(dir, input, scratch_root~)
  let queries = parse_workload(raw)
  // Private copies: opening MoonLSM can change metadata.
  let mut ordinal = 0
  while @fs.exists(scratch_root + "/probe-" + ordinal.to_string()) {
    ordinal += 1
  }
  let scratch = scratch_root + "/probe-" + ordinal.to_string()
  @fs.mkdir(scratch)
  defer @fs.rmdir(scratch, recursive=true)
  if replay_source {
    write_source_database(scratch + "/source", input.rows)
  }
  @fs.mkdir(scratch + "/target")
  @fs.mkdir(scratch + "/target/sst")
  @fs.mkdir(scratch + "/target/wal")
  for name in regular_files(dir + "/db") {
    put(scratch + "/target/" + name, read(dir + "/db/" + name))
  }
  let target = target_rows(input)
  let source = input.rows.copy()
  source.sort_by((a, b) => a.key.lexical_compare(b.key))
  let reader = @snapshot.Reader::open(dir)
  let results = []
  let seen : Map[String, Unit] = Map([])
  let mut passed = true
  let mut first : Json = Json::null()
  for query in queries {
    let id = text(field(query, "id"))
    try {
      if id.is_empty() || seen.contains(id) {
        invalid("empty or repeated query id")
      }
      seen[id] = ()
      let predicate = parse_query(query)
      let source_plan = predicate.plan(input.source)
      let target_plan = predicate.plan(input.target)
      let page_size = positive_integer(query, "page_size", 100)
      let budget = positive_integer(query, "max_target_scanned", 100000)
      let window_budget = query_window_budget(query)
      mode.require_window_budget(window_budget)
      let source_scanned = if replay_source {
        probe_database(
          scratch + "/source",
          [source_plan.byte_range()],
          source.length(),
        )
      } else {
        source.filter(row => source_plan.byte_range().contains(row.key))
      }
      let split = if mode is Segmented {
        Some(reader.plan_segmented(predicate))
      } else {
        None
      }
      let bounded = window_budget.map(maximum => {
        reader.plan_bounded(predicate, maximum)
      })
      let scan = split.map(plan => plan.scan())
      let windows = match (bounded, scan) {
        (Some(plan), _) => plan.windows()
        (None, Some(info)) => info.windows
        _ => [target_plan.byte_range()]
      }
      let target_scanned = probe_database(
        scratch + "/target",
        windows,
        target.length(),
      )
      let source_actual = source_scanned.filter(row => {
        source_plan.matches(row.key)
      })
      let actual = target_scanned.filter(row => target_plan.matches(row.key))
      // Full typed evaluation: no planned range in either reference path.
      let source_expected = source.filter(row => source_plan.matches(row.key))
      let expected = target.filter(row => target_plan.matches(row.key))
      same_rows(source_actual, source_expected)
      same_rows(actual, expected)
      same_rows(
        logical_rows(source_actual, input.source),
        logical_rows(actual, input.target),
      )
      let pages = []
      let mut cursor : Bytes? = None
      let mut fst_scanned = 0
      while true {
        let page = match (bounded, split) {
          (Some(plan), _) =>
            reader.query_bounded(plan, limit=page_size, cursor~)
          (None, Some(plan)) =>
            reader.query_segmented(plan, limit=page_size, cursor~)
          _ => reader.query(predicate, limit=page_size, cursor~)
        }
        fst_scanned += page.scanned
        for row in page.rows {
          pages.push({ key: row.key, value: row.value, })
        }
        if page.cursor is None {
          break
        }
        if page.cursor == cursor || fst_scanned > target.length() {
          invalid("pagination made no progress")
        }
        cursor = page.cursor
      }
      same_rows(pages, expected)
      if fst_scanned != target_scanned.length() {
        invalid("FST scan count differs")
      }
      if scan is Some(plan) && plan.planned_scanned != fst_scanned {
        invalid("segmented prediction differs from measured scan count")
      }
      let bounded_fields = if bounded is Some(plan) &&
        window_budget is Some(maximum) {
        let info = plan.scan()
        if info.planned_scanned != fst_scanned ||
          info.matched != pages.length() ||
          windows.length() > maximum {
          invalid("bounded prediction differs from measured scan")
        }
        [("bounded_scan", bounded_scan_json(info, maximum))]
      } else {
        []
      }
      let within_budget = target_scanned.length() <= budget
      if !within_budget {
        passed = false
        if first == Json::null() {
          first = object([
            ("query_id", Json::string(id)),
            ("reason", Json::string("target scan budget exceeded")),
          ])
        }
      }
      results.push(
        object(
          [
            ("id", Json::string(id)),
            ("query_sha256", Json::string(hash(predicate.to_bytes()))),
            ("source_plan", plan_json(source_plan)),
            ("target_plan", plan_json(target_plan)),
            (
              "source_scanned",
              Json::number(source_scanned.length().to_double()),
            ),
            (
              "target_scanned",
              Json::number(target_scanned.length().to_double()),
            ),
            ("matched", Json::number(actual.length().to_double())),
            ("fst_scanned", Json::number(fst_scanned.to_double())),
            (
              "filtered",
              Json::number(
                (target_scanned.length() - actual.length()).to_double(),
              ),
            ),
            ("max_target_scanned", Json::number(budget.to_double())),
            ("results_match", Json::boolean(true)),
            ("pagination_match", Json::boolean(true)),
            ("within_budget", Json::boolean(within_budget)),
          ] +
          scan
          .map(info => [("segmented_scan", segmented_scan_json(info))])
          .unwrap_or([]) +
          bounded_fields +
          (if evidence {
            [
              ("page_size", Json::number(page_size.to_double())),
              (
                "ordered_result_sha256",
                Json::string(measured_rows_sha256(pages)),
              ),
            ]
          } else {
            []
          }),
        ),
      )
    } catch {
      error => raise Invalid("query " + id + ": " + error_message(error))
    }
  }
  require_ready(dir) |> ignore
  if hash(read(dir + "/manifest.json")) != manifest_hash {
    invalid("manifest changed during verification")
  }
  object([
    ("schema_version", Json::number(1)),
    ("workload_passed", Json::boolean(passed)),
    ("scan_mode", Json::string(mode.label())),
    ("cutover_ready", Json::boolean(passed)),
    ("data_ready", Json::boolean(true)),
    ("version", Json::string(tool_version)),
    ("build_commit", Json::string(build_commit)),
    ("compiler", Json::string(build_compiler)),
    ("dirty", Json::boolean(build_dirty)),
    ("manifest_sha256", Json::string(manifest_hash)),
    ("fingerprint", Json::string(input.fingerprint)),
    ("source_contract_sha256", Json::string(hash(input.source.to_bytes()))),
    ("target_contract_sha256", Json::string(hash(input.target.to_bytes()))),
    ("workload_sha256", Json::string(hash(raw))),
    ("queries", Json::array(results)),
    (
      "scan_metric",
      Json::string("engine-returned records before residual filtering"),
    ),
    ("first_difference", first),
    ("manifest", manifest),
  ])
}

///|
async fn check_queries(args : Array[String], dir : String) -> Unit {
  let path = option(args, "--report", fallback=dir + "-queries-report.json")
  // Reports must not overwrite a candidate, query input, or the original inputs.
  let plan = json_file(dir + "/plan.json")
  let report_name = path_slashes(path)
  let pieces = report_name.split("/").map(x => x.to_owned()).collect()
  let parent = pieces[:pieces.length() - 1].to_owned().join("/")
  let resolved = @fs.realpath(if parent == "" { "." } else { parent }) +
    "/" +
    pieces[pieces.length() - 1]
  if path_slashes(resolved)
    .to_lower()
    .has_prefix(path_slashes(dir).to_lower() + "/") {
    invalid("workload report must be outside candidate")
  }
  for
    protected_path in [
      option(args, "--queries"),
      text(field(plan, "input_path")),
      text(field(plan, "source_path")),
      text(field(plan, "target_path")),
    ] {
    if @fs.exists(path) &&
      path_slashes(@fs.realpath(path)).to_lower() ==
      path_slashes(@fs.realpath(protected_path)).to_lower() {
      invalid("report would overwrite an input")
    }
  }
  let run_id = @async.now().to_string()
  atomic_json(
    path,
    object([
      ("workload_passed", Json::boolean(false)),
      ("cutover_ready", Json::boolean(false)),
      ("run_id", Json::string(run_id)),
    ]),
  )
  let result = try {
    let mode = scan_mode(option(args, "--scan-mode", fallback="single"))
    workload(args, dir, mode~)
  } catch {
    error => {
      atomic_json(
        path,
        object([
          ("workload_passed", Json::boolean(false)),
          ("cutover_ready", Json::boolean(false)),
          ("run_id", Json::string(run_id)),
          ("failed_stage", Json::string("check-queries")),
          ("first_difference", Json::string(error_message(error))),
        ]),
      )
      raise Invalid(error_message(error))
    }
  }
  match result {
    Object(fields) => fields["run_id"] = Json::string(run_id)
    _ => ()
  }
  atomic_json(path, result)
  println(result.stringify())
  if field(result, "workload_passed") != Json::boolean(true) {
    raise Invalid("workload gate failed; see report")
  }
}

///|
fn path_slashes(path : String) -> String {
  path.split("\\").map(part => part.to_owned()).collect().join("/")
}
