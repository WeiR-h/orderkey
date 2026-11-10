///|
fn build_snapshot(
  rows : Array[@moonlsm.KvPair],
) -> (@fst.FstMap, Int32) raise @fst.FstError {
  let builder = @fst.Builder::map()
  for ordinal, row in rows {
    builder.insert(row.key, ordinal.to_uint64())
  }
  let image = builder.finish()
  (@fst.FstMap::from_bytes(image), image.length())
}

///|
fn scan_snapshot(
  snapshot : @fst.FstMap,
  range : @orderkey.ByteRange,
  limit : Int32,
) -> Array[@fst.Entry] raise @fst.FstError {
  let stream = match range {
    Empty => return []
    Span(start, None) if start.is_empty() => snapshot.stream()
    Span(start, Some(end)) =>
      snapshot.stream(range=@fst.KeyRange::between(start, end))
    Span(_, None) =>
      abort("this fixture requires a finite upper bound for nonempty starts")
  }
  let entries = stream.take(limit)
  stream.close()
  entries
}
