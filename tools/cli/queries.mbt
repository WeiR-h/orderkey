///|
fn only_fields(value : Json, allowed : Array[String]) -> Unit raise {
  guard value is Object(fields) else {
    invalid("expected object")
    return
  }
  for name, _ in fields {
    if !allowed.contains(name) {
      invalid("unknown property " + name)
    }
  }
}

///|
fn optional(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn predicate_value(value : Json) -> @orderkey.Value raise {
  only_fields(value, ["bytes_hex", "int64"])
  match (optional(value, "bytes_hex"), optional(value, "int64")) {
    (Some(bytes), None) => Binary(decode(text(bytes)))
    (None, Some(number)) => Signed(@string.parse_int64(text(number)))
    _ => raise Invalid("value must have exactly one of bytes_hex or int64")
  }
}

///|
fn parse_query(value : Json) -> @orderkey.QuerySpec raise {
  only_fields(value, ["id", "eq", "range", "page_size", "max_target_scanned"])
  let equalities = []
  match optional(value, "eq") {
    None => ()
    Some(Object(fields)) =>
      for id, value in fields {
        equalities.push((@utf8.encode(id), predicate_value(value)))
      }
    _ => invalid("eq must be an object")
  }
  let interval = match optional(value, "range") {
    None => None
    Some(range) => {
      only_fields(range, ["field", "lower", "upper"])
      Some(
        (
          @utf8.encode(text(field(range, "field"))),
          optional(range, "lower").map(predicate_value),
          optional(range, "upper").map(predicate_value),
        ),
      )
    }
  }
  @orderkey.QuerySpec::new(equalities, interval)
}

///|
fn plan_json(plan : @orderkey.QueryPlan) -> Json {
  let (leading, blocked, residual) = plan.pushdown_fields()
  object([
    ("access", Json::string(plan.access())),
    ("prefix_fields", Json::number(plan.prefix_fields().to_double())),
    ("residual_fields", Json::number(plan.residual_fields().to_double())),
    (
      "prefix_field_ids_hex",
      Json::array(leading.map(id => Json::string(hex(id)))),
    ),
    (
      "blocking_field_id_hex",
      blocked.map(id => Json::string(hex(id))).unwrap_or(Json::null()),
    ),
    (
      "residual_field_ids_hex",
      Json::array(residual.map(id => Json::string(hex(id)))),
    ),
    (
      "byte_range",
      match plan.byte_range() {
        Empty => Json::null()
        Span(first, last) =>
          object([
            ("start_hex", Json::string(hex(first))),
            (
              "end_hex",
              last.map(x => Json::string(hex(x))).unwrap_or(Json::null()),
            ),
          ])
      },
    ),
  ])
}

///|
async fn explain(args : Array[String]) -> Unit {
  let query = parse_query(json_file(option(args, "--where")))
  let source = query.plan(contract(option(args, "--source-contract")))
  let target = query.plan(contract(option(args, "--target-contract")))
  println(
    object([
      ("source", plan_json(source)),
      ("target", plan_json(target)),
      ("query_sha256", Json::string(hash(query.to_bytes()))),
    ]).stringify(),
  )
}

///|
fn segmented_mode(mode : String) -> Bool raise {
  match mode {
    "single" => false
    "segmented" => true
    _ => raise Invalid("scan mode must be single or segmented")
  }
}

///|
fn segmented_scan_json(scan : @orderkey.SegmentedScan) -> Json {
  object([
    ("single_scanned", Json::number(scan.single_scanned.to_double())),
    ("planned_scanned", Json::number(scan.planned_scanned.to_double())),
    ("planning_probes", Json::number(scan.planning_probes.to_double())),
    ("ranges", Json::number(scan.windows.length().to_double())),
    ("fallback", scan.fallback.map(Json::string).unwrap_or(Json::null())),
  ])
}

///|
async fn semantic_query(args : Array[String], dir : String) -> Unit {
  if args.contains("--start-hex") || args.contains("--end-hex") {
    invalid("--where cannot be combined with byte bounds")
  }
  let query = parse_query(json_file(option(args, "--where")))
  let reader = @snapshot.Reader::open(dir)
  let token = option(args, "--cursor")
  let limit = @string.parse_int(option(args, "--limit", fallback="100"))
  let cursor = if token == "" { None } else { Some(decode(token)) }
  let (page, scan) = if segmented_mode(
      option(args, "--scan-mode", fallback="single"),
    ) {
    let plan = reader.plan_segmented(query)
    (
      reader.query_segmented(plan, limit~, cursor~),
      [("segmented_scan", segmented_scan_json(plan.scan()))],
    )
  } else {
    (reader.query(query, limit~, cursor~), [])
  }
  println(
    object(
      [
        (
          "rows",
          Json::array(
            page.rows.map(row => {
              object([
                ("key_hex", Json::string(hex(row.key))),
                ("value_hex", Json::string(hex(row.value))),
              ])
            }),
          ),
        ),
        (
          "cursor",
          page.cursor
          .map(token => Json::string(hex(token)))
          .unwrap_or(Json::null()),
        ),
        ("scanned", Json::number(page.scanned.to_double())),
        ("plan", plan_json(reader.plan(query))),
      ] +
      scan,
    ).stringify(),
  )
}
