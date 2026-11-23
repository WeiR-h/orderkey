///|
pub suberror QueryError {
  InvalidQuery(String)
}

///|
/// Equality predicates and at most one natural-order [lower, upper) interval.
pub struct QuerySpec {
  priv equalities : Array[(Bytes, Value)]
  priv interval : (Bytes, Value?, Value?)?
}

///|
pub struct QueryPlan {
  priv contract : IndexContract
  priv query : QuerySpec
  priv window : ByteRange
  priv prefix_count : Int32
  priv pushed_range : Bool
}

///|
pub fn QuerySpec::new(
  equalities : Array[(Bytes, Value)],
  interval : (Bytes, Value?, Value?)?,
) -> QuerySpec raise QueryError {
  let seen : Map[Bytes, Unit] = Map([])
  for (id, _) in equalities {
    if id.is_empty() || seen.contains(id) {
      raise InvalidQuery("empty or repeated equality field")
    }
    seen[id] = ()
  }
  if interval is Some((id, _, _)) {
    if id.is_empty() || seen.contains(id) {
      raise InvalidQuery("range field is empty or already has equality")
    }
  }
  let sorted = equalities.copy()
  sorted.sort_by((a, b) => a.0.lexical_compare(b.0))
  { equalities: sorted, interval, }
}

///|
fn validate_query_value(field : Field, value : Value) -> Unit raise QueryError {
  match (field, value) {
    (BytesField(_), Binary(_)) | (Int64Field(_), Signed(_)) => ()
    _ => raise InvalidQuery("predicate type differs from contract")
  }
}

///|
pub fn QuerySpec::plan(
  self : QuerySpec,
  contract : IndexContract,
) -> QueryPlan raise {
  let fields = contract.fields()
  let kinds = Map::from_array(fields)
  for (id, value) in self.equalities {
    guard kinds.get(id) is Some(kind) else {
      raise InvalidQuery("unknown equality field")
    }
    validate_query_value(kind, value)
  }
  if self.interval is Some((id, lower, upper)) {
    guard kinds.get(id) is Some(kind) else {
      raise InvalidQuery("unknown range field")
    }
    if lower is Some(value) {
      validate_query_value(kind, value)
    }
    if upper is Some(value) {
      validate_query_value(kind, value)
    }
  }
  let equalities = Map::from_array(self.equalities)
  let prefix = []
  for (id, _) in fields {
    match equalities.get(id) {
      Some(value) => prefix.push(value)
      None => break
    }
  }
  let pushed_range = match self.interval {
    Some((id, _, _)) =>
      prefix.length() < fields.length() && fields[prefix.length()].0 == id
    None => false
  }
  let window = if pushed_range {
    guard self.interval is Some((_, lower, upper)) else { abort("unreachable") }
    contract
    .key_spec()
    .field_range(
      prefix,
      match lower {
        Some(value) => Inclusive(value)
        None => Unbounded
      },
      match upper {
        Some(value) => Exclusive(value)
        None => Unbounded
      },
    )
  } else {
    contract.key_spec().prefix_range(prefix)
  }
  {
    contract,
    query: self,
    window,
    prefix_count: prefix.length(),
    pushed_range,
  }
}

///|
pub fn QueryPlan::byte_range(self : QueryPlan) -> ByteRange {
  self.window
}

///|
pub fn QueryPlan::prefix_fields(self : QueryPlan) -> Int32 {
  self.prefix_count
}

///|
pub fn QueryPlan::residual_fields(self : QueryPlan) -> Int32 {
  let extra = match self.query.interval {
    Some(_) if !self.pushed_range => 1
    _ => 0
  }
  self.query.equalities.length() - self.prefix_count + extra
}

///|
/// Field identities in index order, the field blocking range pushdown, and residual predicates.
pub fn QueryPlan::pushdown_fields(
  self : QueryPlan,
) -> (Array[Bytes], Bytes?, Array[Bytes]) {
  let fields = self.contract.fields()
  let leading = fields[:self.prefix_count].to_owned().map(field => field.0)
  let residual = self.query.equalities
    .filter(pair => !leading.contains(pair.0))
    .map(pair => pair.0)
  let blocked = match self.query.interval {
    Some((id, _, _)) if !self.pushed_range => {
      residual.push(id)
      Some(fields[self.prefix_count].0)
    }
    _ => None
  }
  (leading, blocked, residual)
}

///|
pub fn QueryPlan::access(self : QueryPlan) -> String {
  if self.pushed_range {
    "range"
  } else if self.prefix_count > 0 {
    "prefix"
  } else {
    "full_scan"
  }
}

///|
fn compare_query_values(a : Value, b : Value) -> Int32 {
  match (a, b) {
    (Binary(a), Binary(b)) => a.lexical_compare(b)
    (Signed(a), Signed(b)) => if a < b { -1 } else if a > b { 1 } else { 0 }
    _ => abort("validated predicate types")
  }
}

///|
/// Evaluate typed predicates without consulting the planned byte range.
pub fn QueryPlan::matches(self : QueryPlan, key : Bytes) -> Bool raise KeyError {
  let values = self.contract.key_spec().decode(key)
  let fields = self.contract.fields()
  let logical = Map::from_array(fields.mapi((i, f) => (f.0, values[i])))
  for (id, value) in self.query.equalities {
    if logical[id] != value {
      return false
    }
  }
  if self.query.interval is Some((id, lower, upper)) {
    let value = logical[id]
    if lower is Some(minimum) && compare_query_values(value, minimum) < 0 {
      return false
    }
    if upper is Some(maximum) && compare_query_values(value, maximum) >= 0 {
      return false
    }
  }
  true
}

///|
fn write_query_value(output : @buffer.Buffer, value : Value) -> Unit {
  match value {
    Binary(bytes) => {
      output.write_byte(0)
      write_part(output, bytes)
    }
    Signed(number) => {
      output.write_byte(1)
      output.write_uint64_be(number.reinterpret_as_uint64())
    }
  }
}

///|
/// Canonical, length-delimited predicate identity; independent of JSON order.
pub fn QuerySpec::to_bytes(self : QuerySpec) -> Bytes {
  let output = @buffer.Buffer()
  output.write_bytes(b"OKQ\x01"[:])
  output.write_uint64_be(self.equalities.length().to_uint64())
  for (id, value) in self.equalities {
    write_part(output, id)
    write_query_value(output, value)
  }
  match self.interval {
    None => output.write_byte(0)
    Some((id, lower, upper)) => {
      output.write_byte(1)
      write_part(output, id)
      for bound in [lower, upper] {
        match bound {
          None => output.write_byte(0)
          Some(value) => {
            output.write_byte(1)
            write_query_value(output, value)
          }
        }
      }
    }
  }
  output.to_bytes()
}

///|
/// Stable row identity across field permutations and direction changes.
pub fn IndexContract::logical_key(
  self : IndexContract,
  key : Bytes,
) -> Bytes raise KeyError {
  let values = self.key_spec().decode(key)
  let fields = self.fields().mapi((i, f) => (f.0, values[i]))
  fields.sort_by((a, b) => a.0.lexical_compare(b.0))
  let output = @buffer.Buffer()
  for (id, value) in fields {
    write_part(output, id)
    write_query_value(output, value)
  }
  output.to_bytes()
}
