-- util.lua - shell, path and file helpers shared by every romsort step.
local M = {}

function M.q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.sh(cmd)
  local ok, how, code = os.execute(cmd)
  -- Lua 5.1/LuaJIT return a number; 5.2+ return ok, "exit", code.
  if type(ok) == 'number' then return ok == 0 end
  return ok == true and (code == nil or code == 0)
end

-- Progress: a small file rewritten in place (at most every 10 s) saying which
-- step the run is on, how far through it, and when that step should finish.
-- `romsort status` prints it; nothing needs to watch the run.
local P = { last = 0 }

function M.progress_to(path) P.path = path end

local function dur(s)
  s = math.floor(s + 0.5)
  if s < 90 then return s .. 's' end
  if s < 5400 then return math.floor(s / 60 + 0.5) .. 'm' end
  return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s % 3600 / 60))
end

-- done/total are optional numbers counted in `unit` (files, GiB, ops).
function M.progress(step, done, total, unit, force)
  if not P.path then return end
  local now = os.time()
  if step ~= P.step then P.step, P.t0, P.d0, force = step, now, done or 0, true end
  if not force and now - P.last < 10 then return end
  P.last = now
  P.started = P.started or now
  local lines = { 'step:    ' .. step }
  if done and total and total > 0 then
    local fmt = unit == 'GiB' and '%.1f' or '%d'
    lines[#lines + 1] = string.format('done:    ' .. fmt .. ' / ' .. fmt .. ' %s (%.1f%%)',
      done, total, unit or '', 100 * done / total)
    local el = now - P.t0
    if el >= 30 and done > P.d0 then
      local left = (total - done) / ((done - P.d0) / el)
      lines[#lines + 1] = string.format('eta:     %s (%s left in this step)', os.date('%a %H:%M', now + left), dur(left))
    end
  end
  lines[#lines + 1] = string.format('updated: %s (run started %s, %s ago)',
    os.date('%a %Y-%m-%d %H:%M:%S', now), os.date('%a %H:%M', P.started), dur(now - P.started))
  M.write_atomic(P.path, table.concat(lines, '\n') .. '\n')
end

function M.die(fmt, ...)
  io.stderr:write('romsort: ', string.format(fmt, ...), '\n')
  os.exit(1)
end

function M.log(fmt, ...)
  io.stdout:write(os.date('%Y-%m-%dT%H:%M:%S '), string.format(fmt, ...), '\n')
  io.stdout:flush()
end

function M.exists(p)
  local f = io.open(p, 'rb')
  if f then f:close() return true end
  return false
end

function M.mkdirp(dir)
  if not M.sh('mkdir -p ' .. M.q(dir)) then M.die('mkdir failed: %s', dir) end
end

function M.dirname(p) return (p:match('^(.*)/[^/]*$')) or '.' end
function M.basename(p) return (p:match('([^/]*)$')) end
function M.ext(p) return (M.basename(p):match('%.([^.]+)$') or ''):lower() end
function M.stem(p) return (M.basename(p):gsub('%.[^.]+$', '')) end

function M.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

function M.write_atomic(path, data)
  M.mkdirp(M.dirname(path))
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(data)
  f:close()
  assert(os.rename(tmp, path))
end

-- Read a NUL-separated stream (find -print0 and friends).
function M.nul_lines(cmd)
  local p = assert(io.popen(cmd, 'r'))
  local data = p:read('*a')
  p:close()
  local out = {}
  for item in data:gmatch('([^%z]+)') do out[#out + 1] = item end
  return out
end

-- TSV with a fixed column list; fields never contain tab or newline (callers
-- reject such paths up front).
function M.tsv_read(path, cols)
  local rows = {}
  local f = io.open(path, 'rb')
  if not f then return rows end
  for line in f:lines() do
    local row, i = {}, 1
    for field in (line .. '\t'):gmatch('([^\t]*)\t') do
      row[cols[i] or i] = field
      i = i + 1
    end
    rows[#rows + 1] = row
  end
  f:close()
  return rows
end

function M.tsv_line(...)
  return table.concat({ ... }, '\t') .. '\n'
end

local XML_UNESC = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }
function M.xml_unescape(s)
  return (s:gsub('&(#?x?)(%w+);', function(kind, body)
    if kind == '' then return XML_UNESC[body] end
    local n = tonumber(body, kind == '#x' and 16 or 10)
    if n and n < 128 then return string.char(n) end
  end))
end

function M.xml_escape(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

function M.sorted_keys(t)
  local k = {}
  for key in pairs(t) do k[#k + 1] = key end
  table.sort(k)
  return k
end

return M
