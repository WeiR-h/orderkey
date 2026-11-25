///|
/// A rank plan prepared against one immutable snapshot.
pub struct BoundedQuery {
  priv plan : @orderkey.QueryPlan
  priv scan : @orderkey.BoundedScan
  priv windows : Array[@orderkey.ByteRange]
  priv manifest : String
  priv scope : Bytes
}

///|
pub fn BoundedQuery::scan(self : BoundedQuery) -> @orderkey.BoundedScan {
  { ..self.scan, rank_windows: self.scan.rank_windows.copy(), }
}

///|
pub fn BoundedQuery::windows(self : BoundedQuery) -> Array[@orderkey.ByteRange] {
  self.windows.copy()
}

///|
fn Reader::ranked_windows(
  self : Reader,
  original : @orderkey.ByteRange,
  ranks : Array[(Int32, Int32)],
) -> Array[@orderkey.ByteRange] raise {
  ranks.map(window => {
    let (start, end) = window
    if start < 0 ||
      start >= end ||
      end > self.keys.length() ||
      !original.contains(self.keys[start]) ||
      !original.contains(self.keys[end - 1]) {
      raise InvalidSnapshot("rank window is outside the query range")
    }
    let upper = self.keys.get(end)
    let end_key = match (original, upper) {
      (Span(_, Some(stop)), Some(next)) if stop.lexical_compare(next) < 0 =>
        Some(stop)
      (Span(_, Some(stop)), None) => Some(stop)
      _ => upper
    }
    @orderkey.Span(self.keys[start], end_key)
  })
}

///|
pub fn Reader::plan_bounded(
  self : Reader,
  query : @orderkey.QuerySpec,
  max_windows : Int32,
) -> BoundedQuery raise {
  let plan = self.plan(query)
  let scan = plan.bounded_ranges(self.keys, max_windows)
  let windows = self.ranked_windows(plan.byte_range(), scan.rank_windows)
  let scope = @utf8.encode(
    digest(
      @utf8.encode(
        "OrderKey/bounded/v1:" +
        self.manifest_hash +
        digest(query.to_bytes()) +
        max_windows.to_string(),
      ),
    ),
  )
  { plan, scan, windows, manifest: self.manifest_hash, scope, }
}

///|
pub fn Reader::query_bounded(
  self : Reader,
  query : BoundedQuery,
  limit~ : Int32 = 100,
  cursor~ : Bytes? = None,
) -> Page raise {
  if self.manifest_hash != query.manifest {
    raise InvalidSnapshot("bounded plan belongs to another snapshot")
  }
  self.read_page(query.plan, query.windows, query.scope, limit, cursor)
}
