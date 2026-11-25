///|
struct LayoutOptions {
  paths : Map[String, Array[String]]
  switches : Array[String]
}

///|
fn layout_options(
  args : Array[String],
  paths : Array[String],
  switches : Array[String],
) -> LayoutOptions raise {
  let options : LayoutOptions = { paths: Map([]), switches: [], }
  let mut i = 2
  while i < args.length() {
    let flag = args[i]
    if switches.contains(flag) && !options.switches.contains(flag) {
      options.switches.push(flag)
      i += 1
    } else if paths.contains(flag) &&
      i + 1 < args.length() &&
      !args[i + 1].has_prefix("--") &&
      args[i + 1] != "" {
      match options.paths.get(flag) {
        None => options.paths[flag] = [args[i + 1]]
        Some(values) if flag == "--candidate" => values.push(args[i + 1])
        Some(_) => invalid("repeated " + flag)
      }
      i += 2
    } else {
      invalid("unknown, repeated, or missing value for " + flag)
    }
  }
  options
}

///|
fn LayoutOptions::path(self : LayoutOptions, name : String) -> String raise {
  guard self.paths.get(name) is Some(values) else {
    raise Invalid("missing " + name)
  }
  values[0]
}

///|
struct LayoutQuery {
  id : String
  predicate : @orderkey.QuerySpec
  equality : Array[Bytes]
  interval : Bytes?
  budget : Int32
  window_budget : Int32?
  weight : Int32
  allow_order_change : Bool
  source_plan : @orderkey.QueryPlan
  matched : Int32
}

///|
struct LayoutInput {
  rows : Array[Row]
  source : @orderkey.IndexContract
  queries : Array[LayoutQuery]
  fixed_prefix : Array[Bytes]
  digests : Json
}

///|
fn parse_workload(raw : Bytes) -> Array[Json] raise {
  let specification = @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
  only_fields(specification, ["schema_version", "queries"])
  if field(specification, "schema_version") != Json::number(1) {
    invalid("unsupported workload version")
  }
  guard field(specification, "queries") is Array(queries) else {
    raise Invalid("queries must be an array")
  }
  if queries.is_empty() || queries.length() > 100 {
    invalid("workload requires 1..100 queries")
  }
  queries
}

///|
fn id_list(value : Json?, label : String) -> Array[String] raise {
  match value {
    None => []
    Some(Array(items)) => {
      let ids = []
      for item in items {
        let id = text(item)
        if id == "" || ids.contains(id) {
          invalid("empty or repeated " + label)
        }
        ids.push(id)
      }
      ids
    }
    _ => raise Invalid(label + " must be an array")
  }
}

///|
async fn layout_digests(options : LayoutOptions) -> Json {
  let policy_raw = match options.paths.get("--policy") {
    None => None
    Some(paths) => Some(hash(read(paths[0], maximum=1048576)))
  }
  object([
    ("input_sha256", Json::string(hash(read(options.path("--input"))))),
    (
      "source_contract_sha256",
      Json::string(hash(contract(options.path("--source-contract")).to_bytes())),
    ),
    (
      "workload_sha256",
      Json::string(hash(read(options.path("--queries"), maximum=1048576))),
    ),
    ("policy_sha256", policy_raw.map(Json::string).unwrap_or(Json::null())),
  ])
}

///|
async fn layout_input(options : LayoutOptions) -> LayoutInput {
  let source = contract(options.path("--source-contract"))
  let raw = read(options.path("--input"))
  let workload = read(options.path("--queries"), maximum=1048576)
  let policy_raw = match options.paths.get("--policy") {
    None => None
    Some(paths) => Some(read(paths[0], maximum=1048576))
  }
  let policy = match policy_raw {
    None => object([])
    Some(bytes) => @json.parse(@utf8.decode(bytes), reject_duplicate_keys=true)
  }
  only_fields(policy, ["fixed_prefix", "weights", "allow_order_change"])
  let fields = source.fields()
  let fixed_prefix = id_list(optional(policy, "fixed_prefix"), "fixed_prefix").map(id => {
      @utf8.encode(id)
    },
  )
  for id in fixed_prefix {
    if !fields.any(entry => entry.0 == id) {
      invalid("unknown fixed prefix field")
    }
  }
  let allow = id_list(
    optional(policy, "allow_order_change"),
    "allow_order_change",
  )
  let weights = optional(policy, "weights").unwrap_or(object([]))
  guard weights is Object(weight_names) else {
    raise Invalid("weights must be an object")
  }
  let rows = parse_rows(raw)
  for row in rows {
    source.key_spec().decode(row.key) |> ignore
  }
  let queries = []
  let seen : Map[String, Unit] = Map([])
  for query in parse_workload(workload) {
    let id = text(field(query, "id"))
    if id == "" || seen.contains(id) {
      invalid("empty or repeated query id")
    }
    seen[id] = ()
    let predicate = parse_query(query)
    let source_plan = predicate.plan(source)
    positive_integer(query, "page_size", 100) |> ignore
    let equality = match optional(query, "eq") {
      Some(Object(values)) =>
        values.keys().map(id => @utf8.encode(id)).collect()
      _ => []
    }
    let interval = match optional(query, "range") {
      Some(value) => Some(@utf8.encode(text(field(value, "field"))))
      None => None
    }
    let mut matched = 0
    for row in rows {
      if source_plan.matches(row.key) {
        matched += 1
      }
    }
    queries.push({
      id,
      predicate,
      equality,
      interval,
      budget: positive_integer(query, "max_target_scanned", 100000),
      window_budget: query_window_budget(query),
      weight: positive_integer(weights, id, 1),
      allow_order_change: allow.contains(id),
      source_plan,
      matched,
    })
  }
  for id in allow {
    if !seen.contains(id) {
      invalid("unknown allow_order_change query " + id)
    }
  }
  for id, _ in weight_names {
    if !seen.contains(id) {
      invalid("unknown weight query " + id)
    }
  }
  let digests = object([
    ("input_sha256", Json::string(hash(raw))),
    ("source_contract_sha256", Json::string(hash(source.to_bytes()))),
    ("workload_sha256", Json::string(hash(workload))),
    (
      "policy_sha256",
      policy_raw.map(bytes => Json::string(hash(bytes))).unwrap_or(Json::null()),
    ),
  ])
  { rows, source, queries, fixed_prefix, digests, }
}

///|
fn layout_key(contract : @orderkey.IndexContract) -> Bytes raise {
  // A neutral identity excludes the original index id and generation.
  @orderkey.IndexContract::new(b"L", 0UL, contract.fields()).to_bytes()
}

///|
fn bound_index(keys : Array[Bytes], bound : Bytes) -> Int32 {
  let mut lo = 0
  let mut hi = keys.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    if keys[mid].lexical_compare(bound) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
fn scan_count(keys : Array[Bytes], range : @orderkey.ByteRange) -> Int32 {
  match range {
    Empty => 0
    Span(start, end) => {
      let high = end
        .map(stop => bound_index(keys, stop))
        .unwrap_or(keys.length())
      let low = bound_index(keys, start)
      if high > low {
        high - low
      } else {
        0
      }
    }
  }
}

///|
struct LayoutScore {
  eligible : Bool
  weighted : Int64
  maximum : Int32
  detail : Json
  predictions : Json
}

///|
fn field_direction(kind : @orderkey.Field) -> String {
  match kind {
    BytesField(Asc) | Int64Field(Asc) => "asc"
    _ => "desc"
  }
}

///|
fn variable_order(
  fields : Array[(Bytes, @orderkey.Field)],
  equalities : Array[Bytes],
) -> Array[(Bytes, String)] {
  fields
  .filter(entry => !equalities.contains(entry.0))
  .map(entry => (entry.0, field_direction(entry.1)))
}

///|
fn evaluate_layout(
  input : LayoutInput,
  target : @orderkey.IndexContract,
  baseline : Bool,
  mode~ : ScanMode = Single,
) -> LayoutScore raise {
  let keys = if baseline {
    input.rows.map(row => row.key)
  } else {
    let reindex = @orderkey.ReindexPlan::new(input.source, target)
    input.rows.map(row => reindex.rekey(row.key))
  }
  keys.sort_by((a, b) => a.lexical_compare(b))
  let source_fields = input.source.fields()
  let target_fields = target.fields()
  let fixed_ok = input.fixed_prefix.length() <= target_fields.length() &&
    input.fixed_prefix.mapi((i, id) => target_fields[i].0 == id).all(ok => ok)
  let mut eligible = fixed_ok
  let mut weighted = 0L
  let mut maximum = 0
  let results = []
  let predictions = []
  for query in input.queries {
    let plan = if baseline {
      query.source_plan
    } else {
      query.predicate.plan(target)
    }
    let (scanned, scan_details) = match mode {
      Single => (scan_count(keys, plan.byte_range()), [])
      Segmented => {
        let scan = plan.segment_ranges(keys)
        (scan.planned_scanned, [("segmented_scan", segmented_scan_json(scan))])
      }
      Bounded => {
        guard query.window_budget is Some(maximum) else {
          raise Invalid("missing window budget for " + query.id)
        }
        let scan = plan.bounded_ranges(keys, maximum)
        if scan.matched != query.matched {
          invalid("bounded plan excludes matches: " + query.id)
        }
        (
          scan.planned_scanned,
          [("bounded_scan", bounded_scan_json(scan, maximum))],
        )
      }
    }
    let source_order = variable_order(source_fields, query.equality)
    let target_order = variable_order(target_fields, query.equality)
    let changed = source_order != target_order
    let failures = []
    if !fixed_ok {
      failures.push(Json::string("fixed_prefix"))
    }
    if changed && !query.allow_order_change {
      failures.push(Json::string("order_changed"))
    }
    if scanned > query.budget {
      failures.push(Json::string("scan_budget"))
    }
    if scanned < query.matched {
      failures.push(Json::string("range_excludes_matches"))
    }
    if !failures.is_empty() {
      eligible = false
    }
    weighted += query.weight.to_int64() * scanned.to_int64()
    if scanned > maximum {
      maximum = scanned
    }
    let prediction = [
      ("id", Json::string(query.id)),
      ("scanned", Json::number(scanned.to_double())),
      ("matched", Json::number(query.matched.to_double())),
    ]
    predictions.push(object(prediction))
    results.push(
      object(
        prediction +
        [
          ("plan", plan_json(plan)),
          (
            "residual_filtered",
            if scanned >= query.matched {
              Json::number((scanned - query.matched).to_double())
            } else {
              Json::null()
            },
          ),
          ("budget", Json::number(query.budget.to_double())),
          (
            "over_budget_by",
            Json::number(
              (if scanned > query.budget { scanned - query.budget } else { 0 }).to_double(),
            ),
          ),
          ("weight", Json::number(query.weight.to_double())),
          ("order_changed", Json::boolean(changed)),
          ("failures", Json::array(failures)),
        ] +
        scan_details,
      ),
    )
  }
  let detail = object([
    ("baseline", Json::boolean(baseline)),
    ("contract_sha256", Json::string(hash(target.to_bytes()))),
    (
      "fields",
      Json::array(
        target_fields.map(entry => {
          let (id, kind) = entry
          object([
            ("id_hex", Json::string(hex(id))),
            ("direction", Json::string(field_direction(kind))),
          ])
        }),
      ),
    ),
    ("eligible", Json::boolean(eligible)),
    ("weighted_scans", Json::number(weighted.to_double())),
    ("max_scanned", Json::number(maximum.to_double())),
    ("queries", Json::array(results)),
  ])
  {
    eligible,
    weighted,
    maximum,
    detail,
    predictions: Json::array(predictions),
  }
}

///|
fn evaluate_candidates(
  input : LayoutInput,
  candidates : Array[@orderkey.IndexContract],
) -> (Array[Json], (@orderkey.IndexContract, LayoutScore)?) raise {
  let baseline = evaluate_layout(input, input.source, true)
  let reports = [baseline.detail]
  let mut best = if baseline.eligible {
    Some((input.source, baseline))
  } else {
    None
  }
  for candidate in candidates {
    let score = evaluate_layout(input, candidate, false)
    reports.push(score.detail)
    if !score.eligible {
      continue
    }
    match best {
      None => best = Some((candidate, score))
      Some((current, old)) =>
        if score.weighted < old.weighted ||
          (score.weighted == old.weighted && score.maximum < old.maximum) ||
          (
            score.weighted == old.weighted &&
            score.maximum == old.maximum &&
            current.to_bytes() != input.source.to_bytes() &&
            layout_key(candidate).lexical_compare(layout_key(current)) < 0
          ) {
          best = Some((candidate, score))
        }
    }
  }
  (reports, best)
}

///|
fn add_automatic_layouts(
  input : LayoutInput,
  candidates : Array[@orderkey.IndexContract],
  keys : Array[Bytes],
) -> Unit raise {
  let source = input.source.fields()
  let kinds = Map::from_array(source)
  let ordered = input.queries.copy()
  ordered.sort_by((a, b) => {
    if a.weight != b.weight {
      b.weight - a.weight
    } else {
      a.id.compare(b.id)
    }
  })
  for query in ordered {
    if candidates.length() >= 8 {
      break
    }
    let ids = input.fixed_prefix.copy()
    for (id, _) in source {
      if query.equality.contains(id) && !ids.contains(id) {
        ids.push(id)
      }
    }
    if query.interval is Some(id) && !ids.contains(id) {
      ids.push(id)
    }
    for (id, _) in source {
      if !ids.contains(id) {
        ids.push(id)
      }
    }
    let fields = ids.map(id => kinds[id])
    let ordered_fields = ids.mapi((i, id) => (id, fields[i]))
    let key = @orderkey.IndexContract::new(b"L", 0UL, ordered_fields).to_bytes()
    if !keys.contains(key) {
      candidates.push(input.source.successor(ordered_fields))
      keys.push(key)
    }
  }
}

///|
async fn compare_layouts(args : Array[String]) -> Unit {
  let options = layout_options(
    args,
    [
      "--input", "--source-contract", "--queries", "--candidate", "--policy", "--out",
    ],
    ["--auto"],
  )
  let paths = options.paths.get("--candidate").unwrap_or([])
  if paths.length() > 8 ||
    (paths.is_empty() && !options.switches.contains("--auto")) {
    invalid("supply up to eight --candidate contracts and/or --auto")
  }
  let input = layout_input(options)
  let candidates = []
  let keys = [layout_key(input.source)]
  for path in paths {
    let candidate = contract(path)
    @orderkey.ReindexPlan::new(input.source, candidate) |> ignore
    let key = layout_key(candidate)
    if !keys.contains(key) {
      keys.push(key)
      candidates.push(candidate)
    }
  }
  if options.switches.contains("--auto") {
    add_automatic_layouts(input, candidates, keys)
  }
  let (reports, best) = evaluate_candidates(input, candidates)
  if layout_digests(options) != input.digests {
    invalid("comparison inputs changed")
  }
  let out = options.path("--out")
  @fs.mkdir(out, allow_exist=false)
  let (status, selected) = match best {
    None => ("no_feasible_candidate", Json::null())
    Some((target, _)) if target.to_bytes() == input.source.to_bytes() =>
      ("keep_source", Json::null())
    Some((target, _)) => ("selected", Json::string(hash(target.to_bytes())))
  }
  let report = object([
    ("schema_version", Json::number(1)),
    ("version", Json::string(tool_version)),
    ("status", Json::string(status)),
    ("digests", input.digests),
    ("rows", Json::number(input.rows.length().to_double())),
    (
      "scan_metric",
      Json::string(
        "records in the planned byte range before residual filtering",
      ),
    ),
    ("selected_contract_sha256", selected),
    ("layouts", Json::array(reports)),
  ])
  atomic_json(out + "/comparison.json", report)
  if status == "selected" {
    guard best is Some((target, score)) else {
      raise Invalid("missing selection")
    }
    put(out + "/target.contract", target.to_bytes())
    atomic_json(
      out + "/selection.json",
      object([
        ("schema_version", Json::number(1)),
        ("digests", input.digests),
        ("target_contract_sha256", selected),
        ("predictions", score.predictions),
      ]),
    )
  }
  println(report.stringify())
}
