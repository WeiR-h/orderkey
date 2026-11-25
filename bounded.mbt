///|
/// An optimal cover of the matches in one frozen, ordered key inventory.
pub(all) struct BoundedScan {
  rank_windows : Array[(Int32, Int32)]
  single_scanned : Int32
  planned_scanned : Int32
  matched : Int32
  keys_examined : Int32
}

///|
/// Cover every match with at most max_windows disjoint half-open rank intervals.
/// Keys must be the complete, strictly increasing inventory for the contract.
pub fn QueryPlan::bounded_ranges(
  self : QueryPlan,
  keys : Array[Bytes],
  max_windows : Int32,
) -> BoundedScan raise {
  if max_windows < 1 || max_windows > 16 {
    raise InvalidQuery("max windows must be in 1..16")
  }
  for i in 1..<keys.length() {
    if keys[i - 1].lexical_compare(keys[i]) >= 0 {
      raise InvalidQuery("bounded planning requires strictly sorted keys")
    }
  }
  let (begin, end) = key_window(keys, self.window, Ref(0))
  let gaps : Array[(Int32, Int32)] = []
  let mut first = -1
  let mut last = -1
  let mut matched = 0
  for i in begin..<end {
    if !self.matches(keys[i]) {
      continue
    }
    matched += 1
    if first < 0 {
      first = i
    } else if i > last + 1 && max_windows > 1 {
      let size = i - last - 1
      let mut position = 0
      while position < gaps.length() &&
            gaps[position].1 - gaps[position].0 >= size {
        position += 1
      }
      // Gaps arrive left to right. Retain the earlier one when sizes tie.
      if position < max_windows - 1 {
        gaps.insert(position, (last + 1, i))
        if gaps.length() == max_windows {
          gaps.pop() |> ignore
        }
      }
    }
    last = i
  }
  let rank_windows = []
  let mut planned_scanned = 0
  if first >= 0 {
    // After trimming the ends, each cut can omit at most one gap.
    gaps.sort_by((left, right) => left.0.compare(right.0))
    let mut cursor = first
    for (gap_start, gap_end) in gaps {
      rank_windows.push((cursor, gap_start))
      planned_scanned += gap_start - cursor
      cursor = gap_end
    }
    rank_windows.push((cursor, last + 1))
    planned_scanned += last + 1 - cursor
  }
  {
    rank_windows,
    single_scanned: end - begin,
    planned_scanned,
    matched,
    keys_examined: end - begin,
  }
}
