///|
struct CapturedQuery {
  id : String
  predicate : Array[(String, Json)]
  page_size : Int32
  mut budget : Int32
  mut count : Int32
}

///|
fn captured_value(value : Json) -> Json raise {
  match predicate_value(value) {
    Binary(bytes) => object([("bytes_hex", Json::string(hex(bytes)))])
    Signed(number) => object([("int64", Json::string(number.to_string()))])
  }
}

///|
fn captured_predicate(query : Json) -> Array[(String, Json)] raise {
  let fields = []
  if optional(query, "eq") is Some(Object(eq)) && !eq.is_empty() {
    let ids = eq.keys().collect()
    ids.sort_by((a, b) => a.compare(b))
    let values = ids.map(id => (id, captured_value(eq[id])))
    fields.push(("eq", object(values)))
  }
  if optional(query, "range") is Some(range) {
    let bounds = [("field", Json::string(text(field(range, "field"))))]
    for end in ["lower", "upper"] {
      if optional(range, end) is Some(value) {
        bounds.push((end, captured_value(value)))
      }
    }
    fields.push(("range", object(bounds)))
  }
  fields
}

///|
async fn collect_queries(args : Array[String]) -> Unit {
  let options = layout_options(
    args,
    ["--trace", "--source-contract", "--out"],
    [],
  )
  let source = contract(options.path("--source-contract"))
  let raw = read(options.path("--trace"))
  let lines = @utf8.decode(raw).split("\n").collect()
  let groups : Map[String, CapturedQuery] = Map([])
  let mut events = 0
  for i, line in lines {
    if line.is_empty() && i == lines.length() - 1 {
      break
    }
    if @utf8.encode(line).length() > 1048576 || events >= 100000 {
      invalid("capture exceeds 100000 events or 1 MiB per event")
    }
    try {
      let query = @json.parse(line, reject_duplicate_keys=true)
      if optional(query, "max_target_windows") is Some(_) {
        invalid("set max_target_windows in the frozen workload after capture")
      }
      let predicate = parse_query(query)
      predicate.plan(source) |> ignore
      let page_size = positive_integer(query, "page_size", 100)
      let budget = positive_integer(query, "max_target_scanned", 100000)
      let identity = hex(predicate.to_bytes()) + ":" + page_size.to_string()
      let id = hash(@utf8.encode(identity))
      match groups.get(id) {
        Some(entry) => {
          entry.count += 1
          if budget < entry.budget {
            entry.budget = budget
          }
        }
        None => {
          if groups.length() == 100 {
            invalid("over 100 distinct queries; split the capture into batches")
          }
          groups[id] = {
            id,
            predicate: captured_predicate(query),
            page_size,
            budget,
            count: 1,
          }
        }
      }
      events += 1
    } catch {
      error =>
        raise Invalid(
          "capture line " + (i + 1).to_string() + ": " + error_message(error),
        )
    }
  }
  if groups.is_empty() {
    invalid("capture contains no queries")
  }
  let ordered = groups.values().collect()
  ordered.sort_by((a, b) => a.id.compare(b.id))
  let queries = ordered.map(entry => {
    object(
      [
        ("id", Json::string(entry.id)),
        ("page_size", Json::number(entry.page_size.to_double())),
        ("max_target_scanned", Json::number(entry.budget.to_double())),
      ] +
      entry.predicate,
    )
  })
  let workload = object([
    ("schema_version", Json::number(1)),
    ("queries", Json::array(queries)),
  ])
  if @utf8.encode(workload.stringify()).length() > 1048576 {
    invalid("collected workload exceeds 1 MiB; split the capture into batches")
  }
  let policy = object([
    (
      "weights",
      object(
        ordered.map(entry => (entry.id, Json::number(entry.count.to_double()))),
      ),
    ),
  ])
  let out = options.path("--out")
  @fs.mkdir(out, allow_exist=false)
  atomic_json(out + "/workload.json", workload)
  atomic_json(out + "/policy.json", policy)
  println(
    object([
      ("events", Json::number(events.to_double())),
      ("queries", Json::number(queries.length().to_double())),
      ("trace_sha256", Json::string(hash(raw))),
    ]).stringify(),
  )
}
