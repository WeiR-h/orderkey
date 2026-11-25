///|
struct ApprovedQuery {
  predicate_sha256 : String
  page_size : Int32
  scanned : Int32
  rank_windows : Array[(Int32, Int32)]?
}

///|
/// Opens and reads a portable snapshot under a trusted batch receipt.
pub struct ApprovedReader {
  priv reader : Reader
  priv receipt_sha256 : String
  priv segmented : Bool
  priv queries : Map[String, ApprovedQuery]
}

///|
fn receipt_count(value : Json, name : String, minimum : Int32) -> Int32 raise {
  receipt_integer(property(value, name), name, minimum)
}

///|
fn receipt_integer(value : Json, name : String, minimum : Int32) -> Int32 raise {
  guard value is Number(n, ..) &&
    n >= minimum.to_double() &&
    n <= 100000.0 &&
    n == n.to_int().to_double() else {
    raise InvalidSnapshot("invalid receipt count: " + name)
  }
  n.to_int()
}

///|
fn receipt_windows(
  entry : Json,
  snapshot_rows : Int32,
  scanned : Int32,
) -> Array[(Int32, Int32)] raise {
  let maximum = receipt_count(entry, "max_target_windows", 1)
  let matched = receipt_count(entry, "matched", 0)
  guard property(entry, "rank_windows") is Array(windows) &&
    maximum <= 16 &&
    windows.length() <= maximum &&
    matched <= scanned &&
    (matched == 0) == windows.is_empty() else {
    raise InvalidSnapshot("inconsistent approved rank windows")
  }
  let mut previous_end = -1
  let mut total = 0
  let spans = []
  for window in windows {
    guard window is Array([first, last]) else {
      raise InvalidSnapshot("expected a half-open rank pair")
    }
    let start = receipt_integer(first, "rank start", 0)
    let end = receipt_integer(last, "rank end", 1)
    if start <= previous_end || start >= end || end > snapshot_rows {
      raise InvalidSnapshot(
        "rank windows must be ordered, separated, and within the snapshot",
      )
    }
    spans.push((start, end))
    previous_end = end
    total += end - start
  }
  if total != scanned {
    raise InvalidSnapshot("approved rank windows differ from scan count")
  }
  spans
}

///|
/// Obtain expected_sha256 independently of the delivered receipt and snapshot.
pub async fn ApprovedReader::open(
  snapshot : String,
  receipt : String,
  expected_sha256 : String,
) -> ApprovedReader {
  let raw = read_file(receipt, maximum=4194304)
  let receipt_sha256 = digest(raw)
  if receipt_sha256 != expected_sha256.to_lower() {
    raise InvalidSnapshot("batch receipt SHA-256 differs from approval")
  }
  let result = parse(raw)
  let schema_version = property(result, "schema_version")
  if property(result, "kind") != Json::string("batch-delivery") ||
    property(result, "ready") != Json::boolean(true) ||
    property(result, "status") != Json::string("passed") {
    raise InvalidSnapshot("batch receipt is not approved")
  }
  let (segmented, bounded) = match
    (schema_version, string(property(result, "scan_mode"))) {
    (Number(1.0, ..), "single") => (false, false)
    (Number(1.0, ..), "segmented") => (true, false)
    (Number(2.0, ..), "bounded") => (false, true)
    _ => raise InvalidSnapshot("unknown approved scan mode")
  }
  guard property(result, "queries") is Array(entries) &&
    !entries.is_empty() &&
    entries.length() <= 100 else {
    raise InvalidSnapshot("invalid approved query set")
  }
  let snapshot_rows = receipt_count(result, "snapshot_rows", 0)
  let queries = Map([])
  for entry in entries {
    let id = string(property(entry, "id"))
    let predicate_sha256 = string(property(entry, "query_sha256"))
    let page_size = receipt_count(entry, "page_size", 1)
    let scanned = receipt_count(entry, "fst_scanned", 0)
    if id == "" ||
      queries.contains(id) ||
      predicate_sha256.length() != 64 ||
      receipt_count(entry, "predicted_scanned", 0) != scanned ||
      receipt_count(entry, "target_scanned", 0) != scanned ||
      receipt_count(entry, "max_target_scanned", 1) < scanned ||
      property(entry, "results_match") != Json::boolean(true) ||
      property(entry, "pagination_match") != Json::boolean(true) ||
      property(entry, "within_budget") != Json::boolean(true) {
      raise InvalidSnapshot("inconsistent approved query evidence")
    }
    let rank_windows = if bounded {
      Some(receipt_windows(entry, snapshot_rows, scanned))
    } else {
      None
    }
    queries[id] = { predicate_sha256, page_size, scanned, rank_windows, }
  }
  let expected_manifest = string(property(result, "manifest_sha256"))
  let reader = open_candidate(
    snapshot,
    expected_manifest=Some(expected_manifest),
  )
  if property(result, "target_contract_sha256") !=
    Json::string(digest(reader.contract().to_bytes())) ||
    snapshot_rows != reader.row_count() {
    raise InvalidSnapshot(
      "batch receipt does not match snapshot contract or row count",
    )
  }
  { reader, receipt_sha256, segmented, queries, }
}

///|
/// Uses the receipt's scan mode and page size for this exact typed predicate.
pub fn ApprovedReader::query(
  self : ApprovedReader,
  id : String,
  query : @orderkey.QuerySpec,
  cursor~ : Bytes? = None,
) -> Page raise {
  guard self.queries.get(id) is Some(approved) else {
    raise InvalidSnapshot("query ID is absent from batch receipt")
  }
  if digest(query.to_bytes()) != approved.predicate_sha256 {
    raise InvalidSnapshot("query predicate differs from batch receipt")
  }
  let (plan, windows) = if approved.rank_windows is Some(ranks) {
    let plan = self.reader.plan(query)
    (plan, self.reader.ranked_windows(plan.byte_range(), ranks))
  } else if self.segmented {
    let split = self.reader.plan_segmented(query)
    if split.scan.planned_scanned != approved.scanned {
      raise InvalidSnapshot("segmented scan differs from batch receipt")
    }
    (split.plan, split.scan.windows)
  } else {
    let plan = self.reader.plan(query)
    (plan, [plan.byte_range()])
  }
  let scope = @utf8.encode(
    digest(
      @utf8.encode(
        "OrderKey/approved/v1:" +
        self.receipt_sha256 +
        self.reader.manifest_hash +
        approved.predicate_sha256 +
        id,
      ),
    ),
  )
  self.reader.read_page(plan, windows, scope, approved.page_size, cursor)
}
