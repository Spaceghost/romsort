-- romsort.lua - sort a ROM collection into a LaunchBox library that never breaks.
-- Run through ./romsort, which sets up the module path, the lock and the log.
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
package.path = here .. '/lib/?.lua;' .. here .. '/?.lua;' .. package.path

local U = require('util')
local SCAN = require('scan')
local REPAIR = require('repair')
local LB = require('launchbox')
local PLAN = require('plan')

local USAGE = [[
usage: romsort <command> [--config FILE]

  plan     scan and hash every source, decide every placement, write
           the plan and report into the state directory. Writes nothing
           into the library.
  build    plan, then create or update the sorted LaunchBox library and
           check it. Safe to re-run; only changed work is redone.
  check    verify the sorted library: every LaunchBox path that worked in
           the original still works, and the XML differs only in paths.
  status   show the last run's report.

The library is hardlinks into the sources, so it costs no disk and deleting
it loses nothing. Sources are only ever read.]]

local cmd = arg[1]
local cfg_path = here .. '/config.lua'
for i = 2, #arg do
  if arg[i] == '--config' then cfg_path = arg[i + 1] end
end
if not cmd or cmd == '-h' or cmd == '--help' or cmd == 'help' then
  print(USAGE)
  os.exit(cmd and 0 or 2)
end
local C = dofile(cfg_path)
if C.seven_zip then SCAN.seven_zip = C.seven_zip end

local function stat_one(path)
  local p = io.popen('find ' .. U.q(path) .. ' -maxdepth 0 -type f -printf "%s\\t%T@\\t%i" 2>/dev/null')
  local s = p:read('*a')
  p:close()
  local size, mtime, inode = s:match('^(%d+)\t([%d.]+)\t(%d+)$')
  if size then return { path = path, size = tonumber(size), mtime = mtime, inode = inode } end
end

-- Output listing: rel -> { size, mtime, inode }.
local function list_out()
  local out = {}
  local p = assert(io.popen('cd ' .. U.q(C.out) .. ' 2>/dev/null && find . -type f -printf "%s\\t%T@\\t%i\\t%P\\0"'))
  local data = p:read('*a')
  p:close()
  for rec in data:gmatch('([^%z]+)') do
    local size, mtime, inode, rel = rec:match('^(%d+)\t([%d.]+)\t(%d+)\t(.*)$')
    if rel then out[rel] = { size = tonumber(size), mtime = mtime, inode = inode } end
  end
  return out
end

local function sha1_of(path)
  local p = io.popen('sha1sum -- ' .. U.q(path) .. ' 2>/dev/null')
  local h = (p:read('*l') or ''):match('^\\?(%x+)')
  p:close()
  return h
end

local function plan()
  U.mkdirp(C.state)
  local planner = PLAN.new(C)
  local all, by_path = {}, {}

  for i, src in ipairs(C.sources) do
    local step = string.format('%s (source %d of %d)', src.label, i, #C.sources)
    U.progress('walk ' .. step)
    local files, bad = SCAN.walk(src.root)
    U.log('source %-10s %7d files  %s', src.label, #files, src.root)
    if #bad > 0 then U.log('!! %d names with tab/newline skipped in %s', #bad, src.label) end
    SCAN.hash(files, C.state, C.jobs, step)
    for _, f in ipairs(files) do by_path[f.path] = f end
    all[#all + 1] = { src = src, files = files }
  end
  U.progress('match against DATs')
  for _, s in ipairs(all) do planner:add_source(s.src, s.files) end

  U.progress('walk LaunchBox install')
  local lbfiles = SCAN.walk(C.launchbox)
  U.log('launchbox  %7d files  %s', #lbfiles, C.launchbox)
  planner:add_launchbox(C.launchbox, lbfiles)
  for _, f in ipairs(lbfiles) do by_path[f.path] = by_path[f.path] or f end

  U.progress('read LaunchBox XML')
  local docs = LB.scan(C.launchbox, C.drives, C.path_tag)
  local nref, nres = 0, 0
  for _, d in ipairs(docs) do
    for _, r in ipairs(d.refs) do
      nref = nref + 1
      if r.abs then
        nres = nres + 1
        if not planner.placed[r.abs] then
          local f = by_path[r.abs] or stat_one(r.abs)
          if f then f.label = 'ext'; planner:adopt(r.abs, f) end
        end
      end
    end
  end
  U.log('launchbox paths: %d, resolving at source: %d, already missing at source: %d', nref, nres, nref - nres)
  local nrep = REPAIR.apply(docs, REPAIR.index(all, planner.skip_ext))
  for _, d in ipairs(docs) do
    for _, r in ipairs(d.refs) do
      if r.repair then planner:count('LaunchBox path repaired (' .. r.how .. ')') end
    end
  end
  U.log('launchbox paths already broken but repaired: %d (see launchbox-repaired.tsv)', nrep)
  return planner, docs, by_path
end

local function write_report(planner, docs, extra)
  local lines = { 'romsort report ' .. os.date('%Y-%m-%d %H:%M'), '' }
  for _, k in ipairs(U.sorted_keys(planner.report)) do
    if type(planner.report[k]) == 'number' then
      lines[#lines + 1] = string.format('%8d  %s', planner.report[k], k)
    end
  end
  if planner.report.skipped then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'card folders not placed (source untouched):'
    for _, k in ipairs(U.sorted_keys(planner.report.skipped)) do
      lines[#lines + 1] = string.format('%8d  %s', planner.report.skipped[k], k)
    end
  end
  for _, l in ipairs(extra or {}) do lines[#lines + 1] = l end
  U.write_atomic(C.state .. '/report.txt', table.concat(lines, '\n') .. '\n')

  local miss, rep = {}, {}
  for _, d in ipairs(docs) do
    for _, r in ipairs(d.refs) do
      if r.repair then rep[#rep + 1] = U.tsv_line(d.xml, r.tag, r.value, r.how, r.repair)
      elseif not r.abs then miss[#miss + 1] = U.tsv_line(d.xml, r.tag, r.value) end
    end
  end
  U.write_atomic(C.state .. '/launchbox-missing-at-source.tsv', table.concat(miss))
  U.write_atomic(C.state .. '/launchbox-repaired.tsv', table.concat(rep))

  local pl = {}
  for _, o in ipairs(planner.ops) do pl[#pl + 1] = U.tsv_line(o.op, o.dst, o.src) end
  U.write_atomic(C.state .. '/plan.tsv', table.concat(pl))
end

local function run_apply(records)
  if #records == 0 then return {} end
  local list = C.state .. '/ops.bin'
  local f = assert(io.open(list, 'wb'))
  for _, r in ipairs(records) do f:write(r[1], '\0', r[2], '\0', r[3], '\0') end
  f:close()
  local p = assert(io.popen('bash ' .. U.q(here .. '/lib/apply.sh') .. ' < ' .. U.q(list)))
  local tally, notes = {}, {}
  for line in p:lines() do
    local word = line:match('^(%u+)')
    if word == 'PROGRESS' then
      U.progress('apply library changes', tonumber(line:match('%d+')), #records, 'ops')
    else
      tally[word] = (tally[word] or 0) + 1
      if word ~= 'LINK' and word ~= 'COPY' and word ~= 'UNLINK' then notes[#notes + 1] = line end
    end
  end
  p:close()
  os.remove(list)
  return tally, notes
end

local check -- forward

local function build()
  local planner, docs, by_path = plan()
  local out = list_out()
  local old = {}
  for _, r in ipairs(U.tsv_read(C.state .. '/manifest.tsv', { 'op', 'dst', 'src', 'size', 'mtime' })) do
    old[r.dst] = r
  end

  -- Rewrite LaunchBox XML for the sorted root.
  -- Files map through the plan; folders (platform folders, root folders) map
  -- by prefix onto where their source tree lands.
  local placed = function(abs)
    local rel = planner.placed[abs]
    if rel then return rel end
    for _, src in ipairs(C.sources) do
      if src.layout == 'launchbox' and (abs == src.root or abs:sub(1, #src.root + 1) == src.root .. '/') then
        return 'Games' .. abs:sub(#src.root + 1)
      end
    end
    if abs:sub(1, #C.launchbox + 1) == C.launchbox .. '/' then return abs:sub(#C.launchbox + 2) end
  end
  local gen = {}
  local rewritten = 0
  for _, d in ipairs(docs) do
    local text, n = LB.rewrite(d, placed)
    rewritten = rewritten + n
    gen[d.xml] = text
  end
  U.log('launchbox paths rewritten: %d', rewritten)

  local records, manifest, kept = {}, {}, {}
  local want = {}
  for _, o in ipairs(planner.ops) do
    if not gen[o.dst] then
      want[o.dst] = true
      local abs = C.out .. '/' .. o.dst
      local cur, prev = out[o.dst], old[o.dst]
      if o.op == 'copy' and cur and prev and prev.op == 'copy'
          and tostring(cur.size) == prev.size and cur.mtime == prev.mtime
          and (tostring(o.size) ~= prev.size or by_path[o.src].mtime ~= prev.mtime) then
        records[#records + 1] = { 'recopy', o.src, abs } -- ours, unmodified, source changed
      else
        records[#records + 1] = { o.op, o.src, abs }
      end
      local f = by_path[o.src]
      manifest[#manifest + 1] = U.tsv_line(o.op, o.dst, o.src, o.size, f and f.mtime or '')
    end
  end

  -- Generated XML: never clobber a file LaunchBox has edited since we wrote it.
  local gen_state = {}
  for _, r in ipairs(U.tsv_read(C.state .. '/generated.tsv', { 'rel', 'sha1' })) do gen_state[r.rel] = r.sha1 end
  local gen_out = {}
  for rel, text in pairs(gen) do
    want[rel] = true
    local abs = C.out .. '/' .. rel
    local cur = out[rel] and sha1_of(abs)
    if cur and gen_state[rel] and cur:upper() ~= gen_state[rel]:upper() then
      U.write_atomic(abs .. '.romsort-new', text)
      kept[#kept + 1] = rel .. ' (edited in the sorted library; new version beside it as .romsort-new)'
      gen_out[#gen_out + 1] = U.tsv_line(rel, cur)
    elseif cur and not gen_state[rel] then
      U.write_atomic(abs .. '.romsort-new', text)
      kept[#kept + 1] = rel .. ' (not written by romsort; new version beside it as .romsort-new)'
    else
      U.write_atomic(abs, text)
      local h = sha1_of(abs)
      gen_out[#gen_out + 1] = U.tsv_line(rel, h)
    end
  end

  -- Retire what an earlier build placed and this plan no longer wants.
  for dst, r in pairs(old) do
    if not want[dst] and out[dst] then
      if r.op == 'link' then
        records[#records + 1] = { 'unlink', r.src, C.out .. '/' .. dst }
      elseif tostring(out[dst].size) == r.size and out[dst].mtime == r.mtime then
        records[#records + 1] = { 'drop', r.src, C.out .. '/' .. dst }
      end
    end
  end

  table.sort(records, function(a, b) return a[3] < b[3] end)
  U.log('applying %d ops', #records)
  local tally, notes = run_apply(records)
  local summary = {}
  for k, v in pairs(tally) do summary[#summary + 1] = k:lower() .. '=' .. v end
  table.sort(summary)
  U.log('applied: %s', table.concat(summary, ' '))

  U.write_atomic(C.state .. '/manifest.tsv', table.concat(manifest))
  U.write_atomic(C.state .. '/generated.tsv', table.concat(gen_out))
  local extra = { '', 'last build: ' .. table.concat(summary, ' ') }
  for _, n in ipairs(notes) do extra[#extra + 1] = '  ' .. n end
  for _, k in ipairs(kept) do extra[#extra + 1] = '  kept ' .. k end
  write_report(planner, docs, extra)
  return check(planner, docs, by_path)
end

-- Every LaunchBox path that resolved in the original must resolve in the
-- sorted root to the same content, and the XML may differ only in paths.
check = function(planner, docs, by_path)
  U.progress('check the library')
  if not docs then
    docs = LB.scan(C.launchbox, C.drives, C.path_tag)
  end
  local out = list_out()
  local broken, ok, premissing, repaired, inode_mismatch = {}, 0, 0, 0, 0
  for _, d in ipairs(docs) do
    local text = U.read(C.out .. '/' .. d.xml)
    if not text then
      broken[#broken + 1] = d.xml .. ': missing from the sorted library'
    else
      if LB.skeleton(text, C.path_tag) ~= LB.skeleton(d.text, C.path_tag) then
        broken[#broken + 1] = d.xml .. ': differs from the original outside path values'
      end
      local refs = LB.refs_in(text, C.path_tag)
      if #refs ~= #d.refs then
        broken[#broken + 1] = d.xml .. ': path count changed'
      else
        for i, r in ipairs(refs) do
          local src = d.refs[i]
          if not src.abs and r.value == src.value then
            premissing = premissing + 1
          elseif not src.abs then -- broken in the original, repaired here
            if LB.resolve(r.value, C.out, C.drives) then repaired = repaired + 1
            else broken[#broken + 1] = string.format('%s: %s repaired to %s, which does not resolve', d.xml, r.tag, r.value) end
          else
            local abs = LB.resolve(r.value, C.out, C.drives)
            if not abs then
              broken[#broken + 1] = string.format('%s: %s %s no longer resolves (was %s)', d.xml, r.tag, r.value, src.value)
            else
              ok = ok + 1
              local rel = abs:sub(#C.out + 2)
              local o, s = out[rel], by_path and by_path[src.abs]
              if o and s and o.inode ~= s.inode and o.size ~= s.size then
                inode_mismatch = inode_mismatch + 1
                broken[#broken + 1] = string.format('%s: %s now points at different content (%s)', d.xml, r.tag, rel)
              end
            end
          end
        end
      end
    end
  end
  -- the original install must be byte-for-byte what we read
  for _, d in ipairs(docs) do
    if U.read(C.launchbox .. '/' .. d.xml) ~= d.text then
      broken[#broken + 1] = 'original ' .. d.xml .. ' changed during the run (LaunchBox open on it?)'
    end
  end
  local lines = {
    string.format('check %s: %d paths ok, %d repaired, %d already missing in the original, %d problems',
      #broken == 0 and 'PASSED' or 'FAILED', ok, repaired, premissing, #broken),
  }
  for i = 1, math.min(#broken, 200) do lines[#lines + 1] = '  ' .. broken[i] end
  U.write_atomic(C.state .. '/check.txt', table.concat(lines, '\n') .. '\n')
  for _, l in ipairs(lines) do U.log('%s', l) end
  return #broken == 0
end

if cmd == 'plan' or cmd == 'build' or cmd == 'check' then
  U.mkdirp(C.state)
  U.progress_to(C.state .. '/progress')
end
local function finish(ok)
  U.progress(cmd .. (ok and ' finished' or ' FAILED, see check.txt and run.log'), nil, nil, nil, true)
  os.exit(ok and 0 or 1)
end
if cmd == 'plan' then
  local planner, docs = plan()
  write_report(planner, docs)
  io.write(U.read(C.state .. '/report.txt'))
  finish(true)
elseif cmd == 'build' then
  finish(build())
elseif cmd == 'check' then
  finish(check())
elseif cmd == 'status' then
  io.write(U.read(C.state .. '/report.txt') or 'no run yet\n')
  io.write(U.read(C.state .. '/check.txt') or '')
else
  io.stderr:write(USAGE, '\n')
  os.exit(2)
end
