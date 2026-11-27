///|
suberror WeatherError {
  BadWeatherInput(String)
}

///|
struct Observation {
  station : Bytes
  date : Int64
  payload : Bytes
}

///|
fn json(fields : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(fields))
}

///|
fn weather_contract() -> @orderkey.IndexContract raise {
  @orderkey.IndexContract::new(b"weather", 1UL, [
    (b"tenant", BytesField(Asc)),
    (b"device", BytesField(Asc)),
    (b"time", Int64Field(Desc)),
    (b"seq", Int64Field(Asc)),
  ])
}

///|
async fn observations(path : String, month : String) -> Array[Observation] {
  let lines = @fs.read_file(path).text().split("\n").collect()
  if lines.is_empty() ||
    lines[0].trim() != "\"STATION\",\"DATE\",\"TMAX\",\"TMIN\"" {
    raise BadWeatherInput("expected the bundled NOAA daily-summaries columns")
  }
  if month != "all" &&
    (month.length() != 6 || @string.parse_int(month) < 100001) {
    raise BadWeatherInput("month must be YYYYMM or all")
  }
  let rows = []
  for i, raw in lines {
    let line = raw.trim()
    if i == 0 || line.is_empty() {
      continue
    }
    let fields = line
      .split(",")
      .collect()
      .map(field => {
        if field.length() < 2 ||
          !field.has_prefix("\"") ||
          !field.has_suffix("\"") {
          raise BadWeatherInput("unexpected NOAA field")
        }
        field[1:field.length() - 1].to_owned()
      })
    if fields.length() != 4 {
      raise BadWeatherInput("expected four NOAA columns")
    }
    let date = fields[1]
      .split("-")
      .map(part => part.to_owned())
      .collect()
      .join("")
    if month != "all" && !date.has_prefix(month) {
      continue
    }
    rows.push({
      station: @utf8.encode(fields[0]),
      date: @string.parse_int64(date),
      payload: @utf8.encode(fields[2] + "," + fields[3]),
    })
  }
  rows
}

///|
fn source_key(spec : @orderkey.KeySpec, row : Observation) -> Bytes raise {
  spec.encode([
    Binary(b"ghcnd"),
    Binary(row.station),
    Signed(row.date),
    Signed(0L),
  ])
}

///|
async fn export_rows(csv : String, month : String, out : String) -> Unit {
  let observations = observations(csv, month)
  let contract = weather_contract()
  let spec = contract.key_spec()
  let output = @buffer.Buffer()
  for row in observations {
    let key = source_key(spec, row)
    let line = json([
      ("key_hex", Json::string(@hex.encode(key[:]))),
      ("value_hex", Json::string(@hex.encode(row.payload[:]))),
    ])
    output.write_bytesview(@utf8.encode(line.stringify())[:])
    output.write_byte(10)
  }
  @fs.mkdir(out, allow_exist=false)
  @fs.write_file(
    out + "/source.contract",
    contract.to_bytes(),
    create_mode=CreateNew,
  )
  @fs.write_file(out + "/input.jsonl", output.to_bytes(), create_mode=CreateNew)
  println(
    json([("exported", Json::number(observations.length().to_double()))]).stringify(),
  )
}

///|
fn requested(
  station : Bytes,
  dates : (String, String)?,
) -> @orderkey.QuerySpec raise {
  let interval = dates.map(pair => {
    (
      b"time",
      Some(@orderkey.Signed(@string.parse_int64(pair.0))),
      Some(@orderkey.Signed(@string.parse_int64(pair.1))),
    )
  })
  @orderkey.QuerySpec::new([(b"device", Binary(station))], interval)
}

///|
fn reading(date : Int64, payload : Bytes) -> Json raise {
  json([
    ("date", Json::string(date.to_string())),
    ("temperatures", Json::string(@utf8.decode(payload))),
  ])
}

///|
async fn capture_query(
  csv : String,
  month : String,
  station_id : String,
  trace : String,
  dates : (String, String)?,
) -> Unit {
  let station = @utf8.encode(station_id)
  let source = weather_contract()
  let plan = requested(station, dates).plan(source)
  let rows = observations(csv, month).filter(row => {
    plan.matches(source_key(source.key_spec(), row))
  })
  rows.sort_by((a, b) => b.date.compare(a.date))
  if trace != "-" {
    let fields = [
      (
        "eq",
        json([
          (
            "device",
            json([("bytes_hex", Json::string(@hex.encode(station[:])))]),
          ),
        ]),
      ),
      ("page_size", Json::number(5)),
      ("max_target_scanned", Json::number(if month == "all" { 91 } else { 31 })),
    ]
    if dates is Some((from, until)) {
      fields.push(
        (
          "range",
          json([
            ("field", Json::string("time")),
            ("lower", json([("int64", Json::string(from))])),
            ("upper", json([("int64", Json::string(until))])),
          ]),
        ),
      )
    }
    @fs.write_file(
      trace,
      json(fields).stringify() + "\n",
      append=true,
      create_mode=OpenOrCreate,
    )
  }
  println(
    Json::array(rows.map(row => reading(row.date, row.payload))).stringify(),
  )
}

///|
async fn selected_query(
  dir : String,
  station : String,
  dates : (String, String)?,
) -> Unit {
  let reader = @snapshot.Reader::open_selected(dir)
  let predicate = requested(@utf8.encode(station), dates)
  let rows = []
  let mut cursor = None
  // This example's selected layout comes from the same four-field contract.
  // Resolve the date from the selected order by decoding named fields.
  let contract = reader.contract()
  let fields = contract.fields()
  guard fields.map(entry => entry.0).search(b"time") is Some(date_index) else {
    raise BadWeatherInput("missing date field in snapshot")
  }
  while true {
    let page = reader.query(predicate, limit=5, cursor~)
    for record in page.rows {
      let values = contract.key_spec().decode(record.key)
      guard values[date_index] is Signed(date) else {
        raise BadWeatherInput("expected signed date")
      }
      rows.push(reading(date, record.value))
    }
    cursor = page.cursor
    if cursor is None {
      break
    }
  }
  println(Json::array(rows).stringify())
}

///|
async fn main {
  let args = @env.args()
  match args[:] {
    [_, "export", csv, month, out] => export_rows(csv, month, out)
    [_, "query", csv, month, station, trace] =>
      capture_query(csv, month, station, trace, None)
    [_, "query", csv, month, station, trace, from, until] =>
      capture_query(csv, month, station, trace, Some((from, until)))
    [_, "query-selected", dir, station] => selected_query(dir, station, None)
    [_, "query-selected", dir, station, from, until] =>
      selected_query(dir, station, Some((from, until)))
    _ =>
      raise BadWeatherInput(
        "usage: export CSV MONTH DIR | query CSV MONTH STATION TRACE [FROM UNTIL] | query-selected DIR STATION [FROM UNTIL]",
      )
  }
}
