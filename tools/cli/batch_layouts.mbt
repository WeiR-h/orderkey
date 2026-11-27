///|
struct LayoutBatch {
  id : String
  options : LayoutOptions
}

///|
struct LayoutBatches {
  path : String
  raw : Bytes
  entries : Array[LayoutBatch]
}

///|
async fn read_layout_batches(path : String) -> LayoutBatches {
  let path = @fs.realpath(path)
  let raw = read(path, maximum=1048576)
  let batches = batch_inventory(raw)
  if batches.length() < 2 {
    invalid("batch comparison requires 2..5 batches")
  }
  let parent = batch_parent(path)
  let entries = batches.map(batch => {
    id: text(field(batch, "id")),
    options: batch_options(parent, batch),
  })
  { path, raw, entries, }
}

///|
fn LayoutBatches::require(
  self : LayoutBatches,
  id : String,
) -> LayoutBatch raise {
  for entry in self.entries {
    if entry.id == id {
      return entry
    }
  }
  raise Invalid("unknown anchor batch " + id)
}

///|
fn layout_scope(digests : Json) -> Json raise {
  object(
    ["source_contract_sha256", "workload_sha256", "policy_sha256"].map(name => {
      (name, field(digests, name))
    }),
  )
}

///|
fn keys_sha256(rows : Array[Row]) -> String {
  let keys = rows.map(row => row.key)
  keys.sort_by((a, b) => a.lexical_compare(b))
  let digest = @sha256.Digest::new()
  for key in keys {
    hash_framed(digest, key)
  }
  digest.check_sum()
}

///|
struct AssessedBatch {
  batch : LayoutBatch
  digests : Json
  keys_sha256 : String
  rows : Int32
}

///|
fn AssessedBatch::to_json(self : AssessedBatch) -> Json {
  object([
    ("id", Json::string(self.batch.id)),
    ("digests", self.digests),
    ("keys_sha256", Json::string(self.keys_sha256)),
    ("rows", Json::number(self.rows.to_double())),
  ])
}

///|
struct BatchLayoutScore {
  contract : @orderkey.IndexContract
  order_key : Bytes
  baseline : Bool
  mut eligible : Bool
  mut worst_batch : String
  mut worst_weighted : Int64
  mut total_weighted : Int64
  mut anchor_predictions : Json
  reports : Array[Json]
}

///|
fn batch_query_summary(query : Json) -> Json raise {
  let plan = field(query, "bounded_scan")
  guard field(plan, "rank_windows") is Array(windows) else {
    raise Invalid("missing bounded windows")
  }
  object(
    [
      "id", "scanned", "matched", "budget", "weight", "order_changed", "failures",
    ].map(name => (name, field(query, name))) +
    [
      ("max_target_windows", field(plan, "max_target_windows")),
      ("window_count", Json::number(windows.length().to_double())),
    ],
  )
}

///|
fn assess_batch(
  batch : LayoutBatch,
  input : LayoutInput,
  layouts : Array[BatchLayoutScore],
  anchor~ : Bool = false,
) -> AssessedBatch raise {
  let mode : ScanMode = Bounded
  for query in input.queries {
    mode.require_window_budget(query.window_budget)
  }
  for layout in layouts {
    let score = evaluate_layout(input, layout.contract, layout.baseline, mode~)
    if anchor {
      layout.anchor_predictions = score.predictions
    }
    layout.eligible = layout.eligible && score.eligible
    layout.total_weighted += score.weighted
    if score.weighted > layout.worst_weighted ||
      (
        score.weighted == layout.worst_weighted &&
        batch.id.compare(layout.worst_batch) < 0
      ) {
      layout.worst_weighted = score.weighted
      layout.worst_batch = batch.id
    }
    guard field(score.detail, "queries") is Array(queries) else {
      raise Invalid("missing layout query scores")
    }
    layout.reports.push(
      object([
        ("id", Json::string(batch.id)),
        ("eligible", Json::boolean(score.eligible)),
        ("weighted_scans", Json::number(score.weighted.to_double())),
        ("queries", Json::array(queries.map(batch_query_summary))),
      ]),
    )
  }
  {
    batch,
    digests: input.digests,
    keys_sha256: keys_sha256(input.rows),
    rows: input.rows.length(),
  }
}

///|
async fn start_batch_comparison(
  anchor : LayoutBatch,
  options : LayoutOptions,
) -> (Array[BatchLayoutScore], AssessedBatch) {
  let input = layout_input(anchor.options)
  let candidates = [input.source] + layout_candidates(input, options)
  let layouts = candidates.mapi((i, contract) => {
    contract,
    order_key: layout_key(contract),
    baseline: i == 0,
    eligible: true,
    worst_batch: "",
    worst_weighted: -1L,
    total_weighted: 0L,
    anchor_predictions: Json::null(),
    reports: [],
  })
  (layouts, assess_batch(anchor, input, layouts, anchor=true))
}

///|
fn BatchLayoutScore::to_json(self : BatchLayoutScore) -> Json {
  object([
    ("baseline", Json::boolean(self.baseline)),
    ("contract_sha256", Json::string(hash(self.contract.to_bytes()))),
    (
      "fields",
      Json::array(
        self.contract
        .fields()
        .map(entry => {
          let (id, kind) = entry
          object([
            ("id_hex", Json::string(hex(id))),
            ("direction", Json::string(field_direction(kind))),
          ])
        }),
      ),
    ),
    ("eligible", Json::boolean(self.eligible)),
    ("worst_batch", Json::string(self.worst_batch)),
    ("worst_weighted_scans", Json::number(self.worst_weighted.to_double())),
    ("total_weighted_scans", Json::number(self.total_weighted.to_double())),
    ("batches", Json::array(self.reports)),
  ])
}

///|
fn best_batch_layout(layouts : Array[BatchLayoutScore]) -> BatchLayoutScore? {
  let mut best = None
  for candidate in layouts {
    if !candidate.eligible {
      continue
    }
    match best {
      None => best = Some(candidate)
      Some(current) =>
        if candidate.worst_weighted < current.worst_weighted ||
          (
            candidate.worst_weighted == current.worst_weighted &&
            candidate.total_weighted < current.total_weighted
          ) ||
          (
            candidate.worst_weighted == current.worst_weighted &&
            candidate.total_weighted == current.total_weighted &&
            !current.baseline &&
            candidate.order_key.lexical_compare(current.order_key) < 0
          ) {
          best = Some(candidate)
        }
    }
  }
  best
}

///|
async fn compare_batches(args : Array[String]) -> Unit {
  let options = layout_options(
    args,
    ["--batches", "--anchor", "--candidate", "--out"],
    ["--auto"],
  )
  let batches = read_layout_batches(options.path("--batches"))
  let anchor_id = options.path("--anchor")
  let anchor = batches.require(anchor_id)
  let (layouts, first) = start_batch_comparison(anchor, options)
  let assessed = [first]
  let scope = layout_scope(first.digests)
  for batch in batches.entries {
    if batch.id == anchor_id {
      continue
    }
    let input = layout_input(batch.options)
    if layout_scope(input.digests) != scope {
      invalid(
        "batch " + batch.id + " differs in source contract, workload, or policy",
      )
    }
    let item = assess_batch(batch, input, layouts)
    if assessed.any(earlier => earlier.keys_sha256 == item.keys_sha256) {
      invalid("batch " + batch.id + " reuses an assessed key set")
    }
    assessed.push(item)
  }
  for item in assessed {
    if layout_digests(item.batch.options) != item.digests {
      invalid("batch changed during comparison: " + item.batch.id)
    }
  }
  if read(batches.path, maximum=1048576) != batches.raw {
    invalid("batch manifest changed during comparison")
  }
  let best = best_batch_layout(layouts)
  let (status, target) = match best {
    None => ("no_feasible_candidate", Json::null())
    Some(best) if best.baseline => ("keep_source", Json::null())
    Some(best) => ("selected", Json::string(hash(best.contract.to_bytes())))
  }
  let report = object([
    ("schema_version", Json::number(1)),
    ("version", Json::string(tool_version)),
    ("scan_mode", Json::string("bounded")),
    ("status", Json::string(status)),
    ("batches_sha256", Json::string(hash(batches.raw))),
    ("anchor", Json::string(anchor_id)),
    ("selected_contract_sha256", target),
    ("batches", Json::array(assessed.map(AssessedBatch::to_json))),
    ("layouts", Json::array(layouts.map(BatchLayoutScore::to_json))),
  ])
  let out = options.path("--out")
  @fs.mkdir(out, allow_exist=false)
  atomic_json(out + "/comparison-batches.json", report)
  if best is Some(winner) && !winner.baseline {
    let selection = layout_selection(
      Bounded,
      first.digests,
      target,
      winner.anchor_predictions,
    )
    let evidence = object([
      ("schema_version", Json::number(1)),
      ("anchor", Json::string(anchor_id)),
      ("batches_sha256", field(report, "batches_sha256")),
      (
        "selection_sha256",
        Json::string(hash(@utf8.encode(selection.stringify()))),
      ),
      ("target_contract_sha256", target),
      ("batches", field(report, "batches")),
    ])
    put(out + "/target.contract", winner.contract.to_bytes())
    atomic_json(out + "/assessment.json", evidence)
    atomic_json(out + "/selection.json", selection)
  }
  println(report.stringify())
}
