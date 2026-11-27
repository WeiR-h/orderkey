///|
struct SelectedLayout {
  options : LayoutOptions
  mode : ScanMode
  raw : Bytes
  target_path : String
  identity : Json
  digests : Json
  predictions : Json
  target_digest : String
  assessment_inputs : AssessmentInputs?
}

///|
fn selection_mode(selection : Json) -> ScanMode raise {
  match field(selection, "schema_version") {
    Number(1.0, ..) => Single
    Number(2.0, ..) if field(selection, "scan_mode") == Json::string("bounded") =>
      Bounded
    _ => raise Invalid("unsupported selection version or scan mode")
  }
}

///|
async fn prepare_selection(args : Array[String]) -> SelectedLayout {
  let options = layout_options(
    args,
    [
      "--input", "--source-contract", "--queries", "--policy", "--selection", "--out",
      "--fail-after", "--pause-after", "--fail-io", "--assessment-batches", "--assessment-sha256",
    ],
    ["--resume"],
  )
  let dir = @fs.realpath(options.path("--selection"))
  let raw = read(dir + "/selection.json", maximum=1048576)
  let selection = @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
  let mode = selection_mode(selection)
  let metadata = selection_metadata(mode)
  only_fields(
    selection,
    metadata.map(pair => pair.0) +
    ["digests", "target_contract_sha256", "predictions"],
  )
  let input = layout_input(options)
  for query in input.queries {
    if mode is Single && query.window_budget is Some(_) {
      invalid(
        "use build and gate-batch --scan-mode bounded for a window budget",
      )
    }
    mode.require_window_budget(query.window_budget)
  }
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
  let score = evaluate_layout(input, target, false, mode~)
  if !score.eligible || score.predictions != field(selection, "predictions") {
    invalid("selected layout no longer matches its predictions or policy")
  }
  let selection_sha256 = hash(raw)
  let assessment_inputs = match
    (
      options.paths.get("--assessment-batches"),
      options.paths.get("--assessment-sha256"),
    ) {
    (Some([manifest]), Some([approved])) => {
      let assessment = read_assessment(
        dir, approved, selection, selection_sha256,
      )
      guard assessment.identities.get(assessment.anchor) is Some(anchor) &&
        anchor.keys_sha256 == keys_sha256(input.rows) else {
        raise Invalid("assessment anchor key set differs from selected input")
      }
      let batches = read_layout_batches(manifest)
      let inputs : AssessmentInputs = { assessment, batches, }
      inputs.check()
      Some(inputs)
    }
    (None, None) if !@fs.exists(dir + "/assessment.json") => None
    _ =>
      raise Invalid(
        "assessed build requires --assessment-batches and --assessment-sha256",
      )
  }
  let bindings = [
    ("selection_sha256", Json::string(selection_sha256)),
    ("digests", input.digests),
    ("target_contract_sha256", Json::string(target_digest)),
  ]
  if assessment_inputs is Some(inputs) {
    bindings.push(("assessment_sha256", Json::string(inputs.assessment.sha256)))
  }
  {
    options,
    mode,
    raw,
    target_path,
    identity: object(metadata + bindings),
    digests: input.digests,
    predictions: score.predictions,
    target_digest,
    assessment_inputs,
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
  if selection.assessment_inputs is Some(inputs) {
    inputs.check()
  }
}

///|
async fn build_selected(
  args : Array[String],
  dir : String,
  selection : SelectedLayout,
) -> Unit {
  let binding = dir + "/selection-job.json"
  let selection_file = dir + "/selection.json"
  let assessment_file = dir + "/assessment.json"
  let bounded = selection.mode is Bounded
  if selection.options.switches.contains("--resume") {
    if !@fs.exists(binding) ||
      json_file(binding) != selection.identity ||
      (bounded && read(selection_file, maximum=1048576) != selection.raw) {
      invalid("selected job identity differs")
    }
    if selection.assessment_inputs is Some(inputs) &&
      read(assessment_file, maximum=1048576) != inputs.assessment.raw {
      invalid("delivered assessment differs from the approved job")
    }
  } else {
    if bounded {
      put(selection_file + ".tmp", selection.raw)
      @fs.rename(selection_file + ".tmp", selection_file)
    }
    if selection.assessment_inputs is Some(inputs) {
      put(assessment_file + ".tmp", inputs.assessment.raw)
      @fs.rename(assessment_file + ".tmp", assessment_file)
    }
    atomic_json(binding, selection.identity)
  }
  let version = field(selection.identity, "schema_version")
  let receipt = dir + "/selection-report.json"
  let run_id = Json::string(@async.now().to_string())
  atomic_json(
    receipt,
    object([
      ("schema_version", version),
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
    let measured = workload(
      args,
      dir,
      replay_source=false,
      mode=selection.mode,
      evidence=bounded,
    )
    if field(measured, "cutover_ready") != Json::boolean(true) {
      invalid("selected workload exceeded its scan budget")
    }
    guard field(measured, "queries") is Array(results) else {
      raise Invalid("missing workload results")
    }
    let actual = Json::array(
      results.map(result => {
        layout_prediction(result, "target_scanned", "max_target_scanned")
      }),
    )
    if actual != selection.predictions {
      invalid("predicted and measured query results differ")
    }
    check_selection_identity(selection)
    if bounded && read(selection_file, maximum=1048576) != selection.raw {
      invalid("delivered selection changed during rebuild")
    }
    if selection.assessment_inputs is Some(inputs) &&
      read(assessment_file, maximum=1048576) != inputs.assessment.raw {
      invalid("delivered assessment changed during rebuild")
    }
    let report = object([
      ("schema_version", version),
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
        ("schema_version", version),
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
