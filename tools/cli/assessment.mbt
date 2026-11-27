///|
struct AssessedIdentity {
  digests : Json
  keys_sha256 : String
}

///|
struct Assessment {
  path : String
  raw : Bytes
  sha256 : String
  batches_sha256 : String
  anchor : String
  identities : Map[String, AssessedIdentity]
}

///|
async fn read_assessment(
  dir : String,
  approved : String,
  selection : Json,
  selection_sha256 : String,
) -> Assessment {
  let path = dir + "/assessment.json"
  let raw = read(path, maximum=1048576)
  let sha256 = hash(raw)
  if sha256 != approved.to_lower() {
    invalid("assessment differs from approved SHA-256")
  }
  let evidence = @json.parse(@utf8.decode(raw), reject_duplicate_keys=true)
  only_fields(evidence, [
    "schema_version", "anchor", "batches_sha256", "selection_sha256", "target_contract_sha256",
    "batches",
  ])
  if field(evidence, "schema_version") != Json::number(1) ||
    !(selection_mode(selection) is Bounded) ||
    field(evidence, "selection_sha256") != Json::string(selection_sha256) ||
    field(evidence, "target_contract_sha256") !=
    field(selection, "target_contract_sha256") {
    invalid("assessment does not bind the selected layout")
  }
  guard field(evidence, "batches") is Array(batches) &&
    batches.length() >= 2 &&
    batches.length() <= 5 else {
    raise Invalid("invalid assessment batch inventory")
  }
  let anchor = text(field(evidence, "anchor"))
  let selected = field(selection, "digests")
  let scope = layout_scope(selected)
  let identities : Map[String, AssessedIdentity] = Map([])
  let key_sets = []
  for batch in batches {
    let id = text(field(batch, "id"))
    let hashes = field(batch, "digests")
    let keys = text(field(batch, "keys_sha256"))
    if id == "" ||
      identities.contains(id) ||
      keys != keys.to_lower() ||
      keys.length() != 64 ||
      decode(keys).length() != 32 ||
      key_sets.contains(keys) ||
      layout_scope(hashes) != scope {
      invalid("invalid assessment batch " + id)
    }
    identities[id] = { digests: hashes, keys_sha256: keys, }
    key_sets.push(keys)
  }
  guard identities.get(anchor) is Some(identity) && identity.digests == selected else {
    raise Invalid("assessment anchor differs from selected input")
  }
  {
    path,
    raw,
    sha256,
    batches_sha256: text(field(evidence, "batches_sha256")),
    anchor,
    identities,
  }
}

///|
struct AssessmentInputs {
  assessment : Assessment
  batches : LayoutBatches
}

///|
async fn AssessmentInputs::check(self : AssessmentInputs) -> Unit {
  let { assessment, batches, } = self
  if read(assessment.path, maximum=1048576) != assessment.raw {
    invalid("assessment changed during the job")
  }
  if hash(batches.raw) != assessment.batches_sha256 ||
    read(batches.path, maximum=1048576) != batches.raw ||
    batches.entries.length() != assessment.identities.length() {
    invalid("batch manifest differs from approved assessment")
  }
  for batch in batches.entries {
    guard assessment.identities.get(batch.id) is Some(identity) &&
      identity.digests == layout_digests(batch.options) else {
      raise Invalid("assessed batch changed: " + batch.id)
    }
  }
}
