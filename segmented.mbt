///|
/// An ordered scan over a complete sorted inventory of one frozen index.
pub(all) struct SegmentedScan {
  windows : Array[ByteRange]
  single_scanned : Int32
  planned_scanned : Int32
  planning_probes : Int32
  fallback : String?
}

///|
fn key_bound(keys : Array[Bytes], bound : Bytes, probes : Ref[Int32]) -> Int32 {
  let mut low = 0
  let mut high = keys.length()
  while low < high {
    let middle = low + (high - low) / 2
    probes.val += 1
    if keys[middle].lexical_compare(bound) < 0 {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low
}

///|
fn key_window(
  keys : Array[Bytes],
  window : ByteRange,
  probes : Ref[Int32],
) -> (Int32, Int32) {
  match window {
    Empty => (0, 0)
    Span(lower, upper) =>
      (
        key_bound(keys, lower, probes),
        upper.map(key => key_bound(keys, key, probes)).unwrap_or(keys.length()),
      )
  }
}

///|
/// Plan from all keys of the contract in ascending encoded order.
/// Binary searches visit one representative per preceding group, with a 16-group cap.
pub fn QueryPlan::segment_ranges(
  self : QueryPlan,
  keys : Array[Bytes],
) -> SegmentedScan raise {
  let probes = Ref(0)
  let (begin, end) = key_window(keys, self.window, probes)
  let baseline = end - begin
  let single = fn(reason) {
    {
      windows: [self.window],
      single_scanned: baseline,
      planned_scanned: baseline,
      planning_probes: probes.val,
      fallback: Some(reason),
    }
  }
  let fields = self.contract.fields()
  let next = self.prefix_count + 1
  guard self.query.interval is Some((id, lower, upper)) &&
    next < fields.length() &&
    id == fields[next].0 &&
    (lower is Some(_) || upper is Some(_)) else {
    return single("unsupported_query_shape")
  }
  let missing = fields[self.prefix_count].0
  let spec = self.contract.key_spec()
  let windows = []
  let mut groups = 0
  let mut candidate = begin
  let mut scanned = 0
  while candidate < end {
    if groups == 16 {
      return single("group_limit")
    }
    groups += 1
    probes.val += 1
    let values = spec.decode(keys[candidate])
    let part = QuerySpec::new(
        self.query.equalities + [(missing, values[self.prefix_count])],
        self.query.interval,
      )
      .plan(self.contract)
      .byte_range()
    let (first, last) = key_window(keys, part, probes)
    if first < last {
      scanned += last - first
      windows.push(part)
    }
    candidate = match spec.prefix_range(values[:next].to_owned()) {
      Span(_, Some(upper)) => key_bound(keys, upper, probes)
      _ => end
    }
  }
  if scanned >= baseline {
    return single("no_scan_reduction")
  }
  {
    windows,
    single_scanned: baseline,
    planned_scanned: scanned,
    planning_probes: probes.val,
    fallback: None,
  }
}
