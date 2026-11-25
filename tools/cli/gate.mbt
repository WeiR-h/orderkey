///|
async fn check_gate_output(options : LayoutOptions, out : String) -> Unit {
  let parts = path_slashes(out)
    .split("/")
    .map(part => part.to_owned())
    .collect()
  let parent = parts[:parts.length() - 1].to_owned().join("/")
  let absolute = path_slashes(
    @fs.realpath(if parent == "" { "." } else { parent }),
  ).to_lower()
  for flag in ["--selection", "--delivery"] {
    if options.paths.get(flag) is Some(paths) && @fs.exists(paths[0]) {
      let root = path_slashes(@fs.realpath(paths[0])).to_lower()
      if absolute == root || absolute.has_prefix(root + "/") {
        invalid("gate reports require a separate output directory")
      }
    }
  }
}

///|
fn summarize_gate_batches(audit : Json) -> Json raise {
  guard field(audit, "batches") is Array(batches) else {
    raise Invalid("missing audit batches")
  }
  Json::array(
    batches.map(batch => {
      let summary = [
        ("id", field(batch, "id")),
        ("status", field(batch, "status")),
      ]
      if optional(batch, "error") is Some(error) {
        summary.push(("error", error))
      } else {
        summary.push(("digests", field(batch, "digests")))
        guard field(field(batch, "target"), "queries") is Array(queries) else {
          raise Invalid("missing audit queries")
        }
        summary.push(
          (
            "queries",
            Json::array(
              queries.map(query => {
                let scanned = field(query, "scanned")
                let budget = field(query, "budget")
                guard scanned is Number(count, ..) &&
                  budget is Number(limit, ..) else {
                  raise Invalid("missing scan or budget count")
                }
                object(
                  [
                    ("id", field(query, "id")),
                    ("predicted_scanned", scanned),
                    ("matched", field(query, "matched")),
                    ("budget", budget),
                    (
                      "over_budget_by",
                      Json::number(
                        if count > limit {
                          count - limit
                        } else {
                          0.0
                        },
                      ),
                    ),
                    ("failures", field(query, "failures")),
                  ] +
                  optional(query, "segmented_scan")
                  .map(scan => [("segmented_scan", scan)])
                  .unwrap_or([]),
                )
              }),
            ),
          ),
        )
      }
      object(summary)
    }),
  )
}

///|
async fn gate_selected(args : Array[String]) -> Unit {
  let (report, code) = try {
    let options = layout_options(
      args,
      [
        "--selection", "--selection-sha256", "--batches", "--delivery", "--out",
        "--scan-mode",
      ],
      [],
    )
    let out = options.path("--out")
    check_gate_output(options, out)
    @fs.mkdir(out, allow_exist=false)
    let path = out + "/gate-report.json"
    let evidence = [
      ("schema_version", Json::number(1)),
      ("run_id", Json::string(@async.now().to_string())),
    ]
    atomic_json(
      path,
      object(
        evidence +
        [("ready", Json::boolean(false)), ("status", Json::string("running"))],
      ),
    )
    let mut stage = "selection"
    let (report, code) = try {
      let mode = option(args, "--scan-mode", fallback="single")
      let strategy = legacy_scan_mode(mode)
      evidence.push(("scan_mode", Json::string(mode)))
      let expected = options.path("--selection-sha256").to_lower()
      let selection_path = options.path("--selection") + "/selection.json"
      let raw = read(selection_path, maximum=1048576)
      if hash(raw) != expected {
        invalid("selection differs from approved SHA-256")
      }
      evidence.push(("selection_sha256", Json::string(expected)))
      let selection = @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
      if field(selection, "schema_version") != Json::number(1) {
        invalid("unsupported selection version")
      }
      stage = "delivery"
      let delivery = @fs.realpath(options.path("--delivery"))
      let manifest = read(delivery + "/manifest.json")
      let receipt_path = delivery + "/selection-report.json"
      let receipt = read(receipt_path)
      let reader = @snapshot.Reader::open_selected(
        delivery,
        expected_selection_sha256=expected,
      )
      let job = json_file(delivery + "/selection-job.json")
      let results = @json.parse(
        @utf8.decode(receipt),
        reject_duplicate_keys=true,
      )
      if field(job, "digests") != field(selection, "digests") ||
        field(job, "target_contract_sha256") !=
        field(selection, "target_contract_sha256") ||
        field(results, "job") != job ||
        field(results, "predictions") != field(selection, "predictions") ||
        Json::string(hash(reader.contract().to_bytes())) !=
        field(selection, "target_contract_sha256") {
        invalid("delivery identity or predictions differ from selection")
      }
      evidence.push(("delivery_manifest_sha256", Json::string(hash(manifest))))
      evidence.push(("delivery_receipt_sha256", Json::string(hash(receipt))))
      evidence.push(
        ("training_measured_queries", field(selection, "predictions")),
      )
      stage = "audit"
      let audit = audit_report(options, true, mode=strategy)
      evidence.push(("batches", summarize_gate_batches(audit)))
      if optional(audit, "error") is Some(error) {
        invalid(text(error))
      }
      if field(audit, "selection_sha256") != Json::string(expected) ||
        read(selection_path, maximum=1048576) != raw ||
        read(delivery + "/manifest.json") != manifest ||
        read(receipt_path) != receipt ||
        json_file(delivery + "/selection-job.json") != job {
        invalid("selection or delivery changed during gate")
      }
      evidence.push(("batches_sha256", field(audit, "batches_sha256")))
      let status = text(field(audit, "status"))
      let passed = status == "passed"
      (
        object(
          evidence +
          [
            ("ready", Json::boolean(passed)),
            ("status", Json::string(status)),
            ("stage", Json::string(stage)),
          ],
        ),
        if passed {
          0
        } else if status == "regression" {
          1
        } else {
          2
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
    atomic_json(path, report)
    (report, code)
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
