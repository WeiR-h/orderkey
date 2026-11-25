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
  let bounded = (args.length() == 5 || args.length() == 7) &&
    args[4] == "bounded"
  guard args.length() == 4 || bounded else {
    raise Invalid(
      "usage: approved-consumer SNAPSHOT RECEIPT TRUSTED_RECEIPT_SHA256 [bounded [OTHER_RECEIPT OTHER_SHA256]]",
    )
  }
  let reader = @snapshot.ApprovedReader::open(args[1], args[2], args[3])
  let other = if args.length() == 7 {
    Some(@snapshot.ApprovedReader::open(args[1], args[5], args[6]))
  } else {
    None
  }
  let (id, field, value, expected_rows, expected_scanned) = if bounded {
    ("global-week", b"event_type", b"earthquake", 593, 646)
  } else {
    ("ak-week", b"network", b"ak", 33, 33)
  }
  let query = @orderkey.QuerySpec::new(
    [(field, Binary(value))],
    Some((b"time", Some(Signed(1711929600000L)), Some(Signed(1712534400000L)))),
  )
  let values = []
  let page_sizes = []
  let mut cursor : Bytes? = None
  let mut scanned = 0
  let mut cross_receipt_rejected = false
  while true {
    let page = reader.query(id, query, cursor~)
    if cursor is None && other is Some(second) && page.cursor is Some(_) {
      cross_receipt_rejected = try
        second.query(id, query, cursor=page.cursor)
      catch {
        @orderkey.CursorScopeMismatch => true
        error => raise error
      } noraise {
        _ => false
      }
    }
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
  if values.length() != expected_rows || scanned != expected_scanned {
    raise Invalid("approved USGS result differs")
  }
  if other is Some(_) && !cross_receipt_rejected {
    raise Invalid("expected a cursor scope mismatch under the other receipt")
  }
  println(
    Json::object(
      Map::from_array([
        ("ready", Json::boolean(true)),
        ("scanned", Json::number(scanned.to_double())),
        ("pages", Json::array(page_sizes)),
        ("values", Json::array(values)),
        ("cross_receipt_cursor_rejected", Json::boolean(cross_receipt_rejected)),
      ]),
    ).stringify(),
  )
}
