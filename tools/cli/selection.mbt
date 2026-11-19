///|
struct SelectedLayout {
  options : LayoutOptions
  target_path : String
  identity : Json
  digests : Json
  predictions : Json
  target_digest : String
}

///|
async fn prepare_selection(args : Array[String]) -> SelectedLayout {
  let options = layout_options(
    args,
    [
      "--input", "--source-contract", "--queries", "--policy", "--selection", "--out",
      "--fail-after", "--pause-after", "--fail-io",
    ],
    ["--resume"],
  )
  let dir = @fs.realpath(options.path("--selection"))
  let raw = read(dir + "/selection.json", maximum=1048576)
  let selection = @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
  only_fields(selection, [
    "schema_version", "digests", "target_contract_sha256", "predictions",
  ])
  if field(selection, "schema_version") != Json::number(1) {
    invalid("unsupported selection version")
  }
  let input = layout_input(options)
  if field(selection, "digests") != input.digests {
    invalid("selection inputs changed")
  }
  let target_path = dir + "/target.contract"
  let target = contract(target_path)
  let target_digest = hash(target.to_bytes())
  if text(field(selection, "target_contract_sha256")) != target_digest {
    invalid("selected target contract changed")
  }
  if layout_key(input.source) == layout_key(target) {
    invalid("selection must change the layout")
  }
  let score = evaluate_layout(input, target, false)
  if !score.eligible || score.predictions != field(selection, "predictions") {
    invalid("selected layout no longer matches its predictions or policy")
  }
  let identity = object([
    ("schema_version", Json::number(1)),
    ("selection_sha256", Json::string(hash(raw))),
    ("digests", input.digests),
    ("target_contract_sha256", Json::string(target_digest)),
  ])
  {
    options,
    target_path,
    identity,
    digests: input.digests,
    predictions: score.predictions,
    target_digest,
  }
}

///|
async fn check_selection_identity(selection : SelectedLayout) -> Unit {
  if layout_digests(selection.options) != selection.digests ||
    hash(contract(selection.target_path).to_bytes()) != selection.target_digest ||
    Json::string(
      hash(
        read(
          selection.options.path("--selection") + "/selection.json",
          maximum=1048576,
        ),
      ),
    ) !=
    field(selection.identity, "selection_sha256") {
    invalid("selection inputs changed during the job")
  }
}

///|
async fn build_selected(
  args : Array[String],
  dir : String,
  selection : SelectedLayout,
) -> Unit {
  let binding = dir + "/selection-job.json"
  if selection.options.switches.contains("--resume") {
    if !@fs.exists(binding) || json_file(binding) != selection.identity {
      invalid("selected job identity differs")
    }
  } else {
    atomic_json(binding, selection.identity)
  }
  let receipt = dir + "/selection-report.json"
  let run_id = Json::string(@async.now().to_string())
  atomic_json(
    receipt,
    object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(false)),
      ("job", selection.identity),
      ("run_id", run_id),
    ]),
  )
  atomic_json(
    dir + "/report.json",
    object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(false)),
      ("phase", Json::string("selected")),
      ("run_id", run_id),
    ]),
  )
  try {
    check_selection_identity(selection)
    record_plan(
      dir,
      selection.options.path("--input"),
      selection.options.path("--source-contract"),
      selection.target_path,
    )
    let input = persisted_input(dir)
    if Json::string(hash(input.raw)) != field(selection.digests, "input_sha256") ||
      Json::string(hash(input.source.to_bytes())) !=
      field(selection.digests, "source_contract_sha256") ||
      hash(input.target.to_bytes()) != selection.target_digest {
      invalid("rebuild input differs from the selection")
    }
    resume_stages(dir, input, args)
    finish(dir, input)
    inject(args, "selected-workload")
    let measured = workload(args, dir, replay_source=false)
    if field(measured, "cutover_ready") != Json::boolean(true) {
      invalid("selected workload exceeded its scan budget")
    }
    guard field(measured, "queries") is Array(results) else {
      raise Invalid("missing workload results")
    }
    let actual = Json::array(
      results.map(result => {
        object([
          ("id", field(result, "id")),
          ("scanned", field(result, "target_scanned")),
          ("matched", field(result, "matched")),
        ])
      }),
    )
    if actual != selection.predictions {
      invalid("predicted and measured query results differ")
    }
    check_selection_identity(selection)
    let report = object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(true)),
      ("cutover_ready", Json::boolean(true)),
      ("job", selection.identity),
      ("run_id", run_id),
      ("predictions", selection.predictions),
      ("workload", measured),
    ])
    atomic_json(receipt, report)
    println(report.stringify())
  } catch {
    error => {
      let message = error_message(error)
      let failure = object([
        ("schema_version", Json::number(1)),
        ("ready", Json::boolean(false)),
        ("cutover_ready", Json::boolean(false)),
        ("job", selection.identity),
        ("run_id", run_id),
        ("first_difference", Json::string(message)),
      ])
      atomic_json(receipt, failure)
      atomic_json(dir + "/report.json", failure)
      raise Invalid(message)
    }
  }
}
