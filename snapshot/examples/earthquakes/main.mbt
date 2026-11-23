///|
async fn main {
  let args = @env.args()
  guard args.length() == 3 else {
    abort("usage: earthquakes DELIVERY APPROVED_SELECTION_SHA256")
  }
  let reader = @snapshot.Reader::open_selected(
    args[1],
    expected_selection_sha256=args[2],
  )
  let query = @orderkey.QuerySpec::new(
    [(b"network", Binary(b"ak"))],
    Some((b"time", Some(Signed(1711929600000L)), Some(Signed(1712534400000L)))),
  )
  let values = []
  let plan = reader.plan_segmented(query)
  let mut cursor : Bytes? = None
  while true {
    let page = reader.query_segmented(plan, limit=7, cursor~)
    for row in page.rows {
      values.push(@hex.encode(row.value[:]))
    }
    cursor = page.cursor
    if cursor is None {
      break
    }
  }
  if values.length() != 33 {
    abort("ComCat consumer mismatch")
  }
  println(Json::array(values.map(Json::string)).stringify())
}
