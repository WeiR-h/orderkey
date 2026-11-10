///|
#derive(Debug)
pub suberror ReindexError {
  DifferentIndex
  InvalidGeneration
  IncompatibleFields
}

///|
pub extend ReindexError with @debug.Debug::{to_repr}

///|
/// A checked projection from a frozen source index to its replacement.
pub struct ReindexPlan {
  priv source_spec : KeySpec
  priv target_spec : KeySpec
  priv positions : Array[Int32]
}

///|
fn Field::same_kind(self : Field, other : Field) -> Bool {
  match (self, other) {
    (BytesField(_), BytesField(_)) | (Int64Field(_), Int64Field(_)) => true
    _ => false
  }
}

///|
pub fn ReindexPlan::new(
  source : IndexContract,
  target : IndexContract,
) -> ReindexPlan raise ReindexError {
  if source.index_id != target.index_id {
    raise DifferentIndex
  }
  if target.generation <= source.generation {
    raise InvalidGeneration
  }
  if source.field_ids.length() != target.field_ids.length() {
    raise IncompatibleFields
  }
  let by_id : Map[Bytes, Int32] = Map([])
  for position, id in source.field_ids {
    by_id[id] = position
  }
  let positions = []
  for position, id in target.field_ids {
    match by_id.get(id) {
      Some(old) if source.spec.fields[old].same_kind(
          target.spec.fields[position],
        ) => positions.push(old)
      _ => raise IncompatibleFields
    }
  }
  { source_spec: source.spec, target_spec: target.spec, positions, }
}

///|
pub fn ReindexPlan::rekey(
  self : ReindexPlan,
  key : Bytes,
) -> Bytes raise KeyError {
  let old_values = self.source_spec.decode(key)
  self.target_spec.encode(self.positions.map(fn(index) { old_values[index] }))
}
