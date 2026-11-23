///|
/// Prepared ranges bound to the immutable snapshot and original query.
pub struct SegmentedQuery {
  priv plan : @orderkey.QueryPlan
  priv scan : @orderkey.SegmentedScan
  priv manifest : String
  priv scope : Bytes
}

///|
pub fn SegmentedQuery::scan(self : SegmentedQuery) -> @orderkey.SegmentedScan {
  { ..self.scan, windows: self.scan.windows.copy(), }
}

///|
pub fn Reader::plan_segmented(
  self : Reader,
  query : @orderkey.QuerySpec,
) -> SegmentedQuery raise {
  let plan = query.plan(self.contract)
  let scan = plan.segment_ranges(self.keys)
  let windows = scan.windows
    .map(window => {
      match window {
        Empty => "-"
        Span(first, last) =>
          @hex.encode(first[:]) +
          ":" +
          last.map(key => @hex.encode(key[:])).unwrap_or("*")
      }
    })
    .join(",")
  let scope = @utf8.encode(
    digest(
      @utf8.encode(
        "OrderKey/segmented/v1:" +
        self.manifest_hash +
        digest(query.to_bytes()) +
        windows,
      ),
    ),
  )
  { plan, scan, manifest: self.manifest_hash, scope, }
}

///|
pub fn Reader::query_segmented(
  self : Reader,
  plan : SegmentedQuery,
  limit~ : Int32 = 100,
  cursor~ : Bytes? = None,
) -> Page raise {
  if self.manifest_hash != plan.manifest {
    raise InvalidSnapshot("segmented plan belongs to another snapshot")
  }
  self.read_page(plan.plan, plan.scan.windows, plan.scope, limit, cursor)
}
