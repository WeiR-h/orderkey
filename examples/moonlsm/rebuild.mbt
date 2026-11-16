///|
suberror RebuildError {
  DuplicateTargetKey
}

///|
fn write_reindexed(
  writer : @moonlsm.Db[@moonlsm.MemStorage],
  plan : @orderkey.ReindexPlan,
  rows : Array[(Bytes, Bytes)],
) -> Unit raise {
  for row in rows {
    let (old_key, value) = row
    let key = plan.rekey(old_key)
    if writer.get(storage_key(key)) is Some(_) {
      raise DuplicateTargetKey
    }
    writer.put_deferred(storage_key(key), value) |> ignore
  }
}

///|
fn stage_reindexed(
  writer : @moonlsm.Db[@moonlsm.MemStorage],
  plan : @orderkey.ReindexPlan,
  rows : Array[(Bytes, Bytes)],
) -> Unit raise {
  write_reindexed(writer, plan, rows)
  writer.sync()
  writer.flush()
}

///|
fn verify_rebuild_failures(
  plan : @orderkey.ReindexPlan,
  row : @moonlsm.KvPair,
) -> Unit raise {
  let pair = (row.key, row.value)
  let storage = @moonlsm.MemStorage::new()
  let writer = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  assert_true(
    (Ok(write_reindexed(writer, plan, [(b"", row.value)])) catch {
      error => Err(error)
    })
    is Err(@orderkey.TruncatedKey(_)),
  )
  assert_true(
    (Ok(write_reindexed(writer, plan, [pair, pair])) catch {
      error => Err(error)
    })
    is Err(DuplicateTargetKey),
  )
  writer.close()
  let storage = @moonlsm.MemStorage::new()
  let writer = @moonlsm.Db::open(storage, MEMTABLE_LIMIT)
  storage.set_fail_write(true)
  assert_true(
    (Ok(stage_reindexed(writer, plan, [pair])) catch { error => Err(error) })
    is Err(_),
  )
  storage.set_fail_write(false)
  writer.close()
  println("checks,bad-key,duplicate-target,write-failure")
}

///|
fn emit_raw(label : String, rows : Array[@moonlsm.KvPair]) -> Unit {
  for row in rows {
    println("\{label},\{@hex.encode(row.key[:])},\{@hex.encode(row.value[:])}")
  }
}

///|
fn emit_reindexed(
  label : String,
  spec : @orderkey.KeySpec,
  rows : Array[@moonlsm.KvPair],
  swap : Bool,
) -> Unit raise {
  for row in rows {
    match spec.decode(row.key) {
      [Binary(first), Binary(second), Signed(time), Signed(seq)] => {
        let (tenant, device) = if swap {
          (second, first)
        } else {
          (first, second)
        }
        println(
          "\{label},\{@hex.encode(tenant[:])},\{@hex.encode(device[:])},\{time},\{seq},\{@hex.encode(row.value[:])},\{@hex.encode(row.key[:])}",
        )
      }
      _ => abort("unexpected target key shape")
    }
  }
}

///|
fn validate_rebuilt_snapshot(
  rows : Array[@moonlsm.KvPair],
  matches : Array[@moonlsm.KvPair],
  target : @orderkey.IndexContract,
  range : @orderkey.ByteRange,
) -> Unit raise {
  let (snapshot, image_bytes) = build_snapshot(rows)
  assert_eq(snapshot.len(), rows.length().to_uint64())
  let stream = snapshot.stream()
  let entries = stream.take(rows.length() + 1)
  stream.close()
  assert_eq(entries.length(), rows.length())
  for index, entry in entries {
    assert_eq(entry.value, index.to_uint64())
    assert_eq(entry.key, rows[index].key)
  }
  let whole_range = scan_snapshot(snapshot, range, rows.length() + 1)
  assert_eq(
    whole_range.map(fn(entry) { entry.key }),
    matches.map(fn(row) { row.key }),
  )
  let paged = []
  let mut window = range
  while true {
    let page = scan_snapshot(snapshot, window, PAGE_SIZE)
    paged.append(page)
    if page.length() < PAGE_SIZE {
      break
    }
    let token = target.issue_cursor(
      b"fst-2",
      range,
      page[page.length() - 1].key,
    )
    window = target.resume_cursor(b"fst-2", range, token)
  }
  assert_eq(
    paged.map(fn(entry) { (entry.key, entry.value) }),
    whole_range.map(fn(entry) { (entry.key, entry.value) }),
  )
  println("snapshot-bytes,\{image_bytes}")
  println("checks,fst-reloaded,fst-ordinals,fst-pages")
  for entry in paged {
    let row = rows[entry.value.to_int()]
    println("fst,\{@hex.encode(entry.key[:])},\{@hex.encode(row.value[:])}")
  }
}

///|
fn run_reindex(
  source_db : @moonlsm.Db[@moonlsm.MemStorage],
  source_rows : Array[@moonlsm.KvPair],
  weather : Bool,
) -> Unit raise {
  let source_fields : Array[(Bytes, @orderkey.Field)] = [
    (b"tenant", BytesField(Asc)),
    (b"device", BytesField(Asc)),
    (b"time", Int64Field(Desc)),
    (b"seq", Int64Field(Asc)),
  ]
  let target_fields = if weather {
    [
      source_fields[0],
      source_fields[1],
      (b"time", Int64Field(Asc)),
      source_fields[3],
    ]
  } else {
    [source_fields[1], source_fields[0], source_fields[2], source_fields[3]]
  }
  let index_id = if weather { b"weather" } else { b"telemetry" }
  let source = @orderkey.IndexContract::new(index_id, 1UL, source_fields)
  let target = @orderkey.IndexContract::new(index_id, 2UL, target_fields)
  match source_db.get(layout_key) {
    Some(bytes) => source.key_spec().require_layout(bytes)
    None => abort("source layout is missing")
  }
  let plan = @orderkey.ReindexPlan::new(source, target)
  let spec = target.key_spec()
  let (tenant, device, first, last) = if weather {
    (b"ghcnd", b"USW00094846", 20240201L, 20240301L)
  } else {
    (b"t3", b"pump\x00A", -2L, 4L)
  }
  let lower = @orderkey.Inclusive(Signed(first))
  let upper = @orderkey.Exclusive(Signed(last))
  let range = spec.field_range(
    if weather {
      [Binary(tenant), Binary(device)]
    } else {
      [Binary(device), Binary(tenant)]
    },
    lower,
    upper,
  )
  if !weather {
    let wrong = @orderkey.IndexContract::new(index_id, 1UL, target_fields)
    wrong.key_spec().require_layout(source.key_spec().layout())
    assert_eq(scan_range(source_db, range, 1).length(), 0)
    assert_true(
      (Ok(wrong.require_same(source.to_bytes())) catch { error => Err(error) })
      is Err(@orderkey.ContractMismatch),
    )
    println("checks,legacy-accepted,wrong-prefix-empty,contract-rejected")
  }
  let source_range = source
    .key_spec()
    .field_range([Binary(tenant), Binary(device)], lower, upper)
  let source_page = scan_range(source_db, source_range, PAGE_SIZE)
  let token = source.issue_cursor(
    b"fixture-1",
    source_range,
    source_page[source_page.length() - 1].key,
  )
  assert_true(
    (Ok(target.resume_cursor(b"fixture-1", range, token)) catch {
      error => Err(error)
    })
    is Err(@orderkey.CursorScopeMismatch),
  )
  println("checks,stale-cursor")
  verify_rebuild_failures(plan, source_rows[0])

  let staging = @moonlsm.MemStorage::new()
  let writer = @moonlsm.Db::open(staging, MEMTABLE_LIMIT)
  stage_reindexed(
    writer,
    plan,
    source_rows.map(fn(row) { (row.key, row.value) }),
  )
  writer.close()
  staging.write_file("orderkey.contract", target.to_bytes())
  staging.sync_file("orderkey.contract")
  let db = @moonlsm.Db::open(staging, MEMTABLE_LIMIT)
  match staging.read_file("orderkey.contract") {
    Some(bytes) => target.require_same(bytes)
    None => abort("target contract is missing")
  }
  let rows = scan_fixture(db, source_rows.length())
  assert_eq(rows.length(), source_rows.length())
  let matches = scan_range(db, range, rows.length() + 1)
  let paged = []
  let mut window = range
  while true {
    let page = scan_range(db, window, PAGE_SIZE)
    paged.append(page)
    if page.length() < PAGE_SIZE {
      break
    }
    let cursor = target.issue_cursor(
      b"fixture-2",
      range,
      page[page.length() - 1].key,
    )
    window = target.resume_cursor(b"fixture-2", range, cursor)
  }
  assert_eq(
    paged.map(fn(row) { (row.key, row.value) }),
    matches.map(fn(row) { (row.key, row.value) }),
  )
  println("checks,moonlsm-pages")
  validate_rebuilt_snapshot(rows, matches, target, range)
  let source_contract = source.to_bytes()
  let target_contract = target.to_bytes()
  println(
    "contracts,\{@hex.encode(source_contract[:])},\{@hex.encode(target_contract[:])}",
  )
  emit_raw("source-before", source_rows)
  emit_raw("source-after", scan_fixture(source_db, source_rows.length()))
  emit_reindexed("target", spec, rows, !weather)
  emit_raw("match", matches)
  db.close()
}
