///|
fn measured_batch_queries(forecast : Json, measured : Json) -> Json raise {
  guard forecast is Array(plans) &&
    measured is Array(actual) &&
    plans.length() == actual.length() else {
    raise Invalid("predicted and measured query sets differ")
  }
  let queries = []
  for i, row in actual {
    let predicted = plans[i]
    let scanned = field(predicted, "scanned")
    let budget = field(predicted, "budget")
    if field(row, "id") != field(predicted, "id") ||
      field(row, "target_scanned") != scanned ||
      field(row, "fst_scanned") != scanned ||
      field(row, "max_target_scanned") != budget ||
      field(row, "matched") != field(predicted, "matched") ||
      optional(row, "bounded_scan") != optional(predicted, "bounded_scan") ||
      field(row, "results_match") != Json::boolean(true) ||
      field(row, "pagination_match") != Json::boolean(true) {
      invalid("measured query differs from forecast: " + text(field(row, "id")))
    }
    let evidence = [
      ("predicted_scanned", scanned),
      ("failures", field(predicted, "failures")),
    ]
    for
      name in [
        "id", "query_sha256", "page_size", "matched", "target_scanned", "fst_scanned",
        "max_target_scanned", "ordered_result_sha256", "within_budget", "results_match",
        "pagination_match",
      ] {
      evidence.push((name, field(row, name)))
    }
    if optional(row, "bounded_scan") is Some(scan) {
      for
        name in [
          "max_target_windows", "rank_windows", "keys_examined", "single_scanned",
        ] {
        evidence.push((name, field(scan, name)))
      }
    }
    queries.push(object(evidence))
  }
  Json::array(queries)
}

///|
async fn gate_batch(args : Array[String]) -> Unit {
  let (report, code) = try {
    let options = layout_options(
      args,
      [
        "--selection", "--selection-sha256", "--assessment-sha256", "--batches",
        "--batch-id", "--delivery", "--scan-mode", "--out",
      ],
      [],
    )
    let out = options.path("--out")
    check_gate_output(options, out)
    @fs.mkdir(out, allow_exist=false)
    let out = @fs.realpath(out)
    let receipt = out + "/batch-receipt.json"
    let schema_version = if options.paths.get("--scan-mode")
      is Some(["bounded"]) {
      2
    } else {
      1
    }
    let evidence = [
      ("schema_version", Json::number(schema_version.to_double())),
      ("kind", Json::string("batch-delivery")),
      ("run_id", Json::string(@async.now().to_string())),
      ("version", Json::string(tool_version)),
      ("build_commit", Json::string(build_commit)),
    ]
    atomic_json(
      receipt,
      object(
        evidence +
        [("ready", Json::boolean(false)), ("status", Json::string("running"))],
      ),
    )
    let mut stage = "selection"
    let (result, code) = try {
      let mode = scan_mode(options.path("--scan-mode"))
      let id = options.path("--batch-id")
      evidence.push(("scan_mode", Json::string(mode.label())))
      evidence.push(("batch_id", Json::string(id)))
      let selection = @fs.realpath(options.path("--selection"))
      let expected = options.path("--selection-sha256").to_lower()
      let selected_raw = read(selection + "/selection.json", maximum=1048576)
      if hash(selected_raw) != expected {
        invalid("selection differs from approved SHA-256")
      }
      evidence.push(("selection_sha256", Json::string(expected)))
      let assessment = match options.paths.get("--assessment-sha256") {
        Some([approved]) => {
          if !(mode is Bounded) {
            invalid("assessed gate requires bounded scan mode")
          }
          let selected = @json.parse(
            @utf8.decode(selected_raw),
            reject_duplicate_keys=true,
          )
          let assessment = read_assessment(
            selection, approved, selected, expected,
          )
          evidence.push(("assessment_sha256", Json::string(assessment.sha256)))
          Some(assessment)
        }
        None if !@fs.exists(selection + "/assessment.json") => None
        _ => raise Invalid("assessed gate requires --assessment-sha256")
      }
      stage = "batch"
      let batch_file = @fs.realpath(options.path("--batches"))
      let raw = read(batch_file, maximum=1048576)
      let batch_hash = Json::string(hash(raw))
      evidence.push(("batches_sha256", batch_hash))
      let audit = audit_report(options, true, mode~, only_batch=Some(id))
      if optional(audit, "error") is Some(error) {
        invalid(text(error))
      }
      guard field(audit, "batches") is Array([batch]) else {
        raise Invalid("expected one audited batch")
      }
      if optional(batch, "error") is Some(error) {
        invalid(text(error))
      }
      if field(audit, "selection_sha256") != Json::string(expected) ||
        field(audit, "batches_sha256") != batch_hash ||
        field(batch, "id") != Json::string(id) {
        invalid("selection or batch manifest changed during gate")
      }
      let digests = field(batch, "digests")
      let target_digest = field(audit, "target_contract_sha256")
      evidence.push(("digests", digests))
      evidence.push(("target_contract_sha256", target_digest))
      let mut descriptor = None
      for entry in batch_inventory(raw) {
        if field(entry, "id") == Json::string(id) {
          descriptor = Some(entry)
        }
      }
      guard descriptor is Some(entry) else { raise Invalid("unknown batch id") }
      let paths = batch_options(batch_parent(batch_file), entry)
      let target_path = selection + "/target.contract"
      let input = prepare(
        paths.path("--input"),
        paths.path("--source-contract"),
        target_path,
      )
      let queries = read(paths.path("--queries"), maximum=1048576)
      if Json::string(hash(input.raw)) != field(digests, "input_sha256") ||
        Json::string(hash(input.source.to_bytes())) !=
        field(digests, "source_contract_sha256") ||
        Json::string(hash(input.target.to_bytes())) != target_digest ||
        Json::string(hash(queries)) != field(digests, "workload_sha256") {
        invalid("batch input changed after audit")
      }
      if assessment is Some(approved) {
        let keys = keys_sha256(input.rows)
        for batch_id, identity in approved.identities {
          if identity.keys_sha256 == keys {
            invalid("holdout reuses assessed key set: " + batch_id)
          }
        }
        evidence.push(("holdout_keys_sha256", Json::string(keys)))
      }
      stage = "delivery"
      let delivery = options.path("--delivery")
      if @fs.kind(delivery, follow_symlink=false) != @fs.Directory {
        invalid("expected job directory")
      }
      let delivery = @fs.realpath(delivery)
      let lock = lock_job(delivery)
      defer lock.close()
      let result = measure_workload(
        delivery,
        input,
        queries,
        out,
        replay_source=false,
        mode~,
        evidence=true,
      )
      let measured = measured_batch_queries(
        field(field(batch, "target"), "queries"),
        field(result, "queries"),
      )
      if layout_digests(paths) != digests ||
        read(batch_file, maximum=1048576) != raw ||
        read(selection + "/selection.json", maximum=1048576) != selected_raw ||
        Json::string(hash(contract(target_path).to_bytes())) != target_digest {
        invalid("selection or batch changed during gate")
      }
      if assessment is Some(approved) &&
        read(approved.path, maximum=1048576) != approved.raw {
        invalid("assessment changed during gate")
      }
      evidence.push(("queries", measured))
      evidence.push(("manifest_sha256", field(result, "manifest_sha256")))
      evidence.push(
        ("snapshot_rows", Json::number(input.rows.length().to_double())),
      )
      let passed = field(audit, "status") == Json::string("passed") &&
        field(result, "workload_passed") == Json::boolean(true)
      (
        object(
          evidence +
          [
            ("ready", Json::boolean(passed)),
            (
              "status",
              Json::string(if passed { "passed" } else { "regression" }),
            ),
            ("stage", Json::string("complete")),
          ],
        ),
        if passed {
          0
        } else {
          1
        },
      )
    } catch {
      error =>
        (
          object(
            evidence +
            [
              ("ready", Json::boolean(false)),
              ("status", Json::string("invalid")),
              ("stage", Json::string(stage)),
              ("error", Json::string(error_message(error))),
            ],
          ),
          2,
        )
    }
    atomic_json(receipt, result)
    (result, code)
  } catch {
    error =>
      (
        object([
          ("ready", Json::boolean(false)),
          ("status", Json::string("invalid")),
          ("error", Json::string(error_message(error))),
        ]),
        2,
      )
  }
  println(report.stringify())
  if code != 0 {
    exit_process(code)
  }
}
