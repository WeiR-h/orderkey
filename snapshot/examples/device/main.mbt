///|
async fn main {
  let args = @env.args()
  let begin = @async.now()
  let reader = @snapshot.Reader::open(args[1])
  let opened = @async.now()
  let predicate = @orderkey.QuerySpec::new(
    [(b"tenant", Binary(b"t3")), (b"device", Binary(b"pump\x00A"))],
    Some((b"time", Some(Signed(-2L)), Some(Signed(4L)))),
  )
  let matches = []
  let benchmark_only = args.length() > 2
  let mut cursor : Bytes? = None
  while !benchmark_only {
    let page = reader.query(predicate, limit=5, cursor~)
    for row in page.rows {
      matches.push(@hex.encode(row.key[:]))
    }
    cursor = page.cursor
    if cursor is None {
      break
    }
  }
  if !benchmark_only && matches.length() != 18 {
    abort("device query expected 18 records")
  }
  let page_start = @async.now()
  let all = @orderkey.QuerySpec::new([], None)
  cursor = None
  let mut returned = 0
  let mut scanned = 0
  for _ in 0..<100 {
    let page = reader.query(all, limit=1, cursor~)
    returned += page.rows.length()
    scanned += page.scanned
    cursor = page.cursor
  }
  println(
    Json::object(
      Map::from_array([
        ("ready", Json::boolean(returned == 100 && scanned == 100)),
        ("open_ms", Json::number((opened - begin).to_double())),
        ("pages_100_ms", Json::number((@async.now() - page_start).to_double())),
        ("loaded_bytes", Json::number(reader.loaded_bytes().to_double())),
        ("page_rows", Json::number(returned.to_double())),
        ("page_scanned", Json::number(scanned.to_double())),
        ("keys", Json::array(matches.map(Json::string))),
      ]),
    ).stringify(),
  )
}
