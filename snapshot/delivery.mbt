///|
fn delivery_version(value : Json) -> Unit raise {
  if property(value, "schema_version") != Json::number(1) {
    raise InvalidSnapshot("unsupported delivery metadata version")
  }
}

///|
fn delivery_count(value : Json, name : String) -> Int32 raise {
  match property(value, name) {
    Number(count, ..) if count >= 0.0 &&
      count <= 100000.0 &&
      count == count.to_int().to_double() => count.to_int()
    _ => raise InvalidSnapshot("invalid delivery count " + name)
  }
}

///|
fn check_delivery_queries(
  report : Json,
  workload : Json,
  snapshot_rows : Int32?,
) -> Unit raise {
  guard property(report, "predictions") is Array(predictions) &&
    property(workload, "queries") is Array(results) &&
    predictions.length() == results.length() &&
    !results.is_empty() &&
    results.length() <= 100 else {
    raise InvalidSnapshot("invalid delivery query inventory")
  }
  let seen : Map[String, Unit] = Map([])
  for i, query in results {
    let prediction = predictions[i]
    let id = string(property(query, "id"))
    let scanned = delivery_count(query, "target_scanned")
    let matched = delivery_count(query, "matched")
    if id == "" ||
      seen.contains(id) ||
      property(prediction, "id") != Json::string(id) ||
      delivery_count(prediction, "scanned") != scanned ||
      delivery_count(prediction, "matched") != matched ||
      delivery_count(query, "fst_scanned") != scanned ||
      matched > scanned ||
      scanned > delivery_count(query, "max_target_scanned") {
      raise InvalidSnapshot("delivery query differs: " + id)
    }
    seen[id] = ()
    for flag in ["results_match", "pagination_match", "within_budget"] {
      if property(query, flag) != Json::boolean(true) {
        raise InvalidSnapshot("delivery query did not pass: " + id)
      }
    }
    if snapshot_rows is Some(rows) {
      let plan = property(prediction, "bounded_scan")
      if plan != property(query, "bounded_scan") ||
        property(prediction, "max_target_scanned") !=
        property(query, "max_target_scanned") ||
        delivery_count(plan, "planned_scanned") != scanned ||
        delivery_count(plan, "matched") != matched {
        raise InvalidSnapshot("bounded delivery differs from selection: " + id)
      }
      receipt_windows(plan, rows, scanned) |> ignore
    }
  }
}

///|
/// Opens a selected snapshot only after verifying its workload receipt.
/// An expected digest pins the caller's intended selection.json.
pub async fn Reader::open_selected(
  dir : String,
  expected_selection_sha256? : String,
) -> Reader {
  let receipt_raw = read_file(dir + "/selection-report.json")
  let report = parse(receipt_raw)
  let version = property(report, "schema_version")
  let bounded = version == Json::number(2)
  if version != Json::number(1) && !bounded {
    raise InvalidSnapshot("unsupported delivery metadata version")
  }
  if property(report, "ready") != Json::boolean(true) ||
    property(report, "cutover_ready") != Json::boolean(true) {
    raise InvalidSnapshot("selected workload is not ready for delivery")
  }
  let job_raw = read_file(dir + "/selection-job.json")
  let job = parse(job_raw)
  if property(job, "schema_version") != version ||
    property(report, "job") != job {
    raise InvalidSnapshot("selection job differs from delivery receipt")
  }
  if job is Object(fields) && fields.get("assessment_sha256") is Some(expected) {
    let assessment = read_file(dir + "/assessment.json", maximum=1048576)
    if !bounded || digest(assessment) != string(expected) {
      raise InvalidSnapshot("assessment differs from delivery receipt")
    }
  }
  let selection_sha = string(property(job, "selection_sha256"))
  if selection_sha.length() != 64 ||
    @hex.decode(selection_sha[:]).length() != 32 {
    raise InvalidSnapshot("invalid selection digest")
  }
  if expected_selection_sha256 is Some(expected) &&
    expected.to_lower() != selection_sha {
    raise InvalidSnapshot("delivery does not match the expected selection")
  }
  let verified_raw = read_file(dir + "/report.json")
  let raw = read_file(dir + "/manifest.json")
  let manifest = parse(raw)
  let workload = property(report, "workload")
  delivery_version(workload)
  for flag in ["cutover_ready", "workload_passed", "data_ready"] {
    if property(workload, flag) != Json::boolean(true) {
      raise InvalidSnapshot("workload attestation did not pass")
    }
  }
  let digests = property(job, "digests")
  let files = property(manifest, "files")
  let target = property(job, "target_contract_sha256")
  let selection_raw = if bounded {
    let bytes = read_file(dir + "/selection.json", maximum=1048576)
    let selection = parse(bytes)
    let mode = Json::string("bounded")
    if digest(bytes) != selection_sha ||
      property(selection, "schema_version") != version ||
      property(selection, "scan_mode") != mode ||
      property(job, "scan_mode") != mode ||
      property(workload, "scan_mode") != mode ||
      property(selection, "digests") != digests ||
      property(selection, "target_contract_sha256") != target ||
      property(selection, "predictions") != property(report, "predictions") {
      raise InvalidSnapshot("bounded delivery differs from its selection")
    }
    Some(bytes)
  } else {
    None
  }
  let source = property(digests, "source_contract_sha256")
  let input = property(digests, "input_sha256")
  let fingerprint = digest(
    @utf8.encode(string(input) + string(source) + string(target)),
  )
  let manifest_hash = digest(raw)
  if property(workload, "manifest_sha256") != Json::string(manifest_hash) ||
    property(workload, "manifest") != manifest ||
    property(workload, "fingerprint") != Json::string(fingerprint) ||
    property(manifest, "fingerprint") != Json::string(fingerprint) ||
    property(manifest, "source_sha256") != input ||
    property(workload, "source_contract_sha256") != source ||
    property(workload, "target_contract_sha256") != target ||
    property(workload, "workload_sha256") !=
    property(digests, "workload_sha256") ||
    property(files, "source.contract") != source ||
    property(files, "target.contract") != target {
    raise InvalidSnapshot(
      "delivery metadata belongs to another artifact or workload",
    )
  }
  check_delivery_queries(
    report,
    workload,
    if bounded {
      Some(delivery_count(manifest, "rows"))
    } else {
      None
    },
  )
  let reader = Reader::open(dir)
  if reader.manifest_hash != manifest_hash ||
    read_file(dir + "/selection-report.json") != receipt_raw ||
    read_file(dir + "/selection-job.json") != job_raw ||
    read_file(dir + "/report.json") != verified_raw ||
    read_file(dir + "/manifest.json") != raw ||
    (
      selection_raw is Some(bytes) &&
      read_file(dir + "/selection.json", maximum=1048576) != bytes
    ) {
    raise InvalidSnapshot("delivery changed while opening")
  }
  reader
}
