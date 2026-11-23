///|
suberror ConsumerError {
  Invalid(String)
}

///|
async fn main {
  read_approved() catch {
    Invalid(message) | @snapshot.InvalidSnapshot(message) => {
      @stdio.stderr.write(message + "\n")
      exit_process(1)
    }
    error => {
      @stdio.stderr.write(error.to_string() + "\n")
      exit_process(1)
    }
  }
}

///|
extern "C" fn exit_process(code : Int32) -> Unit = "exit"

///|
async fn read_approved() -> Unit {
  let args = @env.args()
  guard args.length() == 4 else {
    raise Invalid(
      "usage: approved-consumer SNAPSHOT RECEIPT TRUSTED_RECEIPT_SHA256",
    )
  }
  let reader = @snapshot.ApprovedReader::open(args[1], args[2], args[3])
  let query = @orderkey.QuerySpec::new(
    [(b"network", Binary(b"ak"))],
    Some((b"time", Some(Signed(1711929600000L)), Some(Signed(1712534400000L)))),
  )
  let values = []
  let page_sizes = []
  let mut cursor : Bytes? = None
  let mut scanned = 0
  while true {
    let page = reader.query("ak-week", query, cursor~)
    scanned += page.scanned
    for row in page.rows {
      values.push(Json::string(@hex.encode(row.value[:])))
    }
    page_sizes.push(Json::number(page.rows.length().to_double()))
    cursor = page.cursor
    if cursor is None {
      break
    }
  }
  if values.length() != 33 || scanned != 33 {
    raise Invalid("approved USGS result differs")
  }
  println(
    Json::object(
      Map::from_array([
        ("ready", Json::boolean(true)),
        ("scanned", Json::number(scanned.to_double())),
        ("pages", Json::array(page_sizes)),
        ("values", Json::array(values)),
      ]),
    ).stringify(),
  )
}
