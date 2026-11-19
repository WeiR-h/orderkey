///|
async fn main {
  let reader = @snapshot.Reader::open(@env.args()[1])
  let predicate = @orderkey.QuerySpec::new(
    [(b"tenant", Binary(b"ghcnd")), (b"device", Binary(b"USW00094846"))],
    Some((b"time", Some(Signed(20240201L)), Some(Signed(20240301L)))),
  )
  let keys = []
  let mut cursor : Bytes? = None
  while true {
    let page = reader.query(predicate, limit=5, cursor~)
    for row in page.rows {
      keys.push(@hex.encode(row.key[:]))
    }
    cursor = page.cursor
    if cursor is None {
      break
    }
  }
  println(
    Json::object(
      Map::from_array([
        ("ready", Json::boolean(keys.length() == 29)),
        ("keys", Json::array(keys.map(Json::string))),
      ]),
    ).stringify(),
  )
}
