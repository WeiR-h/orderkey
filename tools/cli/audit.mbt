///|
fn batch_path(
  parent : String,
  descriptor : Json,
  name : String,
) -> String raise {
  let path = path_slashes(text(field(descriptor, name)))
  if path == "" {
    invalid("empty batch path: " + name)
  }
  if path.has_prefix("/") || (path.length() >= 2 && path[1] == ':') {
    path
  } else {
    parent + "/" + path
  }
}

///|
fn batch_options(parent : String, batch : Json) -> LayoutOptions raise {
  only_fields(batch, ["id", "input", "source_contract", "queries", "policy"])
  let paths = Map::from_array([
    ("--input", [batch_path(parent, batch, "input")]),
    ("--source-contract", [batch_path(parent, batch, "source_contract")]),
    ("--queries", [batch_path(parent, batch, "queries")]),
  ])
  if optional(batch, "policy") is Some(_) {
    paths["--policy"] = [batch_path(parent, batch, "policy")]
  }
  { paths, switches: [], }
}

///|
async fn audit_report(
  options : LayoutOptions,
  locked : Bool,
  segmented~ : Bool = false,
) -> Json {
  let reports = []
  try {
    let selection_dir = @fs.realpath(options.path("--selection"))
    let batch_file = @fs.realpath(options.path("--batches"))
    let parts = path_slashes(batch_file)
      .split("/")
      .map(part => part.to_owned())
      .collect()
    let parent = parts[:parts.length() - 1].to_owned().join("/")
    let selected_raw = read(selection_dir + "/selection.json", maximum=1048576)
    let selected = @json.parse(
      @utf8.decode(selected_raw),
      reject_duplicate_keys=true,
    )
    if field(selected, "schema_version") != Json::number(1) {
      invalid("unsupported selection version")
    }
    let target_path = selection_dir + "/target.contract"
    let target = contract(target_path)
    let target_digest = Json::string(hash(target.to_bytes()))
    if target_digest != field(selected, "target_contract_sha256") {
      invalid("target contract differs from selection")
    }
    let selected_digests = field(selected, "digests")
    let source_digest = field(selected_digests, "source_contract_sha256")
    let raw = read(batch_file, maximum=1048576)
    let descriptor = @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
    only_fields(descriptor, ["schema_version", "batches"])
    guard field(descriptor, "schema_version") == Json::number(1) &&
      field(descriptor, "batches") is Array(batches) &&
      !batches.is_empty() &&
      batches.length() <= 5 else {
      raise Invalid("audit requires schema version 1 and 1..5 batches")
    }
    let ids : Map[String, Unit] = Map([])
    let verified_inputs : Array[(LayoutOptions, Json)] = []
    let hashes = [field(selected_digests, "input_sha256")]
    let mut regression = false
    let mut malformed = false
    for batch in batches {
      let id = text(field(batch, "id"))
      if id == "" || ids.contains(id) {
        invalid("empty or repeated batch id: " + id)
      }
      ids[id] = ()
      try {
        let paths = batch_options(parent, batch)
        let input = layout_input(paths)
        if field(input.digests, "source_contract_sha256") != source_digest {
          invalid("batch source contract differs from selected source")
        }
        if locked {
          for name in ["workload_sha256", "policy_sha256"] {
            if field(input.digests, name) != field(selected_digests, name) {
              invalid("locked audit: " + name + " differs from selection")
            }
          }
        }
        let data_hash = field(input.digests, "input_sha256")
        if hashes.contains(data_hash) {
          invalid("batch reuses an earlier frozen export")
        }
        hashes.push(data_hash)
        let source_score = evaluate_layout(input, input.source, true)
        let target_score = evaluate_layout(input, target, false, segmented~)
        verified_inputs.push((paths, input.digests))
        if !target_score.eligible {
          regression = true
        }
        reports.push(
          object([
            ("id", Json::string(id)),
            (
              "status",
              Json::string(
                if target_score.eligible {
                  "passed"
                } else {
                  "regression"
                },
              ),
            ),
            ("digests", input.digests),
            ("source", source_score.detail),
            ("target", target_score.detail),
          ]),
        )
      } catch {
        error => {
          malformed = true
          reports.push(
            object([
              ("id", Json::string(id)),
              ("status", Json::string("invalid")),
              ("error", Json::string(error_message(error))),
            ]),
          )
        }
      }
    }
    for (paths, digests) in verified_inputs {
      if layout_digests(paths) != digests {
        invalid("batch inputs changed during audit")
      }
    }
    if read(batch_file, maximum=1048576) != raw ||
      read(selection_dir + "/selection.json", maximum=1048576) != selected_raw ||
      Json::string(hash(contract(target_path).to_bytes())) != target_digest {
      invalid("selection or batch manifest changed during audit")
    }
    let status = if malformed {
      "invalid"
    } else if regression {
      "regression"
    } else {
      "passed"
    }
    object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(status == "passed")),
      ("status", Json::string(status)),
      ("locked", Json::boolean(locked)),
      (
        "scan_mode",
        Json::string(if segmented { "segmented" } else { "single" }),
      ),
      ("selection_sha256", Json::string(hash(selected_raw))),
      ("batches_sha256", Json::string(hash(raw))),
      ("target_contract_sha256", target_digest),
      ("batches", Json::array(reports)),
    ])
  } catch {
    error =>
      object([
        ("schema_version", Json::number(1)),
        ("ready", Json::boolean(false)),
        ("status", Json::string("invalid")),
        ("error", Json::string(error_message(error))),
        ("batches", Json::array(reports)),
      ])
  }
}

///|
async fn audit_layout(args : Array[String]) -> Unit {
  let options = layout_options(
    args,
    ["--selection", "--batches", "--out", "--scan-mode"],
    ["--locked"],
  )
  let segmented = segmented_mode(option(args, "--scan-mode", fallback="single"))
  let locked = options.switches.contains("--locked")
  if segmented && !locked {
    invalid("segmented audit requires --locked")
  }
  let out = options.path("--out")
  @fs.mkdir(out, allow_exist=false)
  let report_path = out + "/audit-report.json"
  atomic_json(
    report_path,
    object([
      ("schema_version", Json::number(1)),
      ("ready", Json::boolean(false)),
      ("status", Json::string("running")),
      ("batches", Json::array([])),
    ]),
  )
  let report = audit_report(options, locked, segmented~)
  atomic_json(report_path, report)
  println(report.stringify())
  if field(report, "ready") != Json::boolean(true) {
    invalid("layout audit failed; see audit-report.json")
  }
}
