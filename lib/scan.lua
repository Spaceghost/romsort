-- scan.lua - walk sources, hash files, list archive members. Results are cached
-- by (path, size, mtime) so a re-run only hashes what changed.
local U = require('util')
local M = {}

local FILE_COLS = { 'path', 'size', 'mtime', 'inode', 'sha1', 'hsha1' }
local MEMBER_COLS = { 'path', 'size', 'mtime', 'member', 'msize', 'crc' }

-- Every regular file under root: { path=, size=, mtime=, inode= }.
function M.walk(root)
  local files, bad = {}, {}
  local p = assert(io.popen('find ' .. U.q(root) .. ' -type f -printf "%s\\t%T@\\t%i\\t%p\\0" 2>/dev/null'))
  local data = p:read('*a')
  p:close()
  for rec in data:gmatch('([^%z]+)') do
    local size, mtime, inode, path = rec:match('^(%d+)\t([%d.]+)\t(%d+)\t(.*)$')
    if not path or path:find('[\t\n]') then
      bad[#bad + 1] = rec
    else
      files[#files + 1] = { path = path, size = tonumber(size), mtime = mtime, inode = inode }
    end
  end
  table.sort(files, function(a, b) return a.path < b.path end)
  return files, bad
end

-- Copier/console headers that No-Intro strips before hashing.
local function header_len(path, size)
  local e = U.ext(path)
  if size % 1024 == 512 and (e == 'smc' or e == 'sfc' or e == 'swc' or e == 'fig') then return 512 end
  if e ~= 'nes' and e ~= 'fds' and e ~= 'lnx' and e ~= 'a78' then return 0 end
  local f = io.open(path, 'rb')
  if not f then return 0 end
  local head = f:read(16) or ''
  f:close()
  if head:sub(1, 4) == 'NES\26' or head:sub(1, 4) == 'FDS\26' then return 16 end
  if head:sub(1, 4) == 'LYNX' then return 64 end
  if head:sub(2, 10) == 'ATARI7800' then return 128 end
  return 0
end

-- Handheld packs often ship GBA ROMs "trimmed": the padding up to the chip
-- size cut off. No-Intro hashes the full chip, so pad back to the next power
-- of two with 0xFF and with 0x00 (both occur) and hash each.
local function trimmed(path, size)
  if U.ext(path) ~= 'gba' or size > 32 * 2 ^ 20 then return nil end
  local full = 256 * 1024
  while full < size do full = full * 2 end
  if full == size then return nil end
  return full - size
end

local function sha1_of(cmd)
  local p = io.popen(cmd .. ' | sha1sum')
  local h = (p:read('*l') or ''):match('^(%x+)')
  p:close()
  return h and h:upper()
end

-- Extra hashes a DAT may know this file by, comma-separated, or nil: the hash
-- without a copier header, or of the untrimmed ROM.
local function alt_hashes(path, size)
  local hl = header_len(path, size)
  if hl > 0 then return sha1_of('tail -c +' .. (hl + 1) .. ' -- ' .. U.q(path)) end
  local pad = trimmed(path, size)
  if pad then
    local ff = sha1_of('{ cat -- ' .. U.q(path) .. '; head -c ' .. pad .. " /dev/zero | tr '\\000' '\\377'; }")
    local zero = sha1_of('{ cat -- ' .. U.q(path) .. '; head -c ' .. pad .. ' /dev/zero; }')
    if ff and zero then return ff .. ',' .. zero end
  end
  return nil
end

local function load_cache(path, cols)
  local cache = {}
  for _, r in ipairs(U.tsv_read(path, cols)) do
    if cols == MEMBER_COLS then
      local key = r.path .. '\0' .. r.size .. '\0' .. r.mtime
      local list = cache[key] or {}
      if r.member ~= '' then list[#list + 1] = r
      elseif r.crc == '' and U.ext(r.path) ~= 'zip' then list.unlisted = true end
      cache[key] = list
    else
      cache[r.path] = r -- last row wins: the file is append-only
    end
  end
  return cache
end

-- sha1sum escapes names containing a backslash: "\HASH  na\\me".
local function parse_sha1_line(line)
  local esc = line:sub(1, 1) == '\\'
  if esc then line = line:sub(2) end
  local h, name = line:match('^(%x+)  (.*)$')
  if h and esc then name = name:gsub('\\\\', '\\') end
  return h, name
end

local ARCHIVE = { zip = true, ['7z'] = true, rar = true }
local unzip
function M.have_unzip()
  if unzip == nil then unzip = U.sh('command -v unzip >/dev/null 2>&1') end
  return unzip
end

local function list_members(path, have7z)
  local out = {}
  local e = U.ext(path)
  if e == 'zip' and (not have7z or M.have_unzip()) then -- local unzip: fast, no container
    local p = io.popen('unzip -lv -- ' .. U.q(path) .. ' 2>/dev/null')
    for line in p:lines() do
      local len, crc, name = line:match('^%s*(%d+)%s+%S+%s+%d+%s+%S+%s+%S+%s+%S+%s+(%x%x%x%x%x%x%x%x)%s+(.+)$')
      if len and not name:match('/$') then out[#out + 1] = { member = name, msize = len, crc = crc:upper() } end
    end
    p:close()
  elseif have7z then
    local p = io.popen(have7z .. ' l -slt -ba -- ' .. U.q(path) .. ' 2>/dev/null')
    local cur = {}
    for line in p:lines() do
      local k, v = line:match('^(%w+) = (.*)$')
      if k == 'Path' then
        if cur.member and cur.crc then out[#out + 1] = cur end
        cur = { member = v }
      elseif k == 'Size' then cur.msize = v
      elseif k == 'CRC' and v ~= '' then cur.crc = v:upper()
      elseif k == 'Folder' and v == '+' then cur.crc = nil end
    end
    if cur.member and cur.crc then out[#out + 1] = cur end
    p:close()
  end
  return out
end

-- The command that lists .7z/.rar archives, or nil. M.seven_zip (set from
-- config) is a list of candidate commands, tried in order; each must accept
-- `l -slt -ba -- <host path>`. Probed once per run.
M.seven_zip = { '7zz', '7z' }
local lister
function M.lister()
  if lister ~= nil then return lister or nil end
  lister = false
  for _, cmd in ipairs(M.seven_zip) do
    if U.sh(cmd .. ' i >/dev/null 2>&1') then lister = cmd break end
  end
  if lister then U.log('archives: .7z/.rar listed with: %s', lister)
  else U.log('note: no working 7z (%s), so .7z/.rar contents are not matched this run (zip still is);'
    .. ' they are listed on the first run that has one', table.concat(M.seven_zip, ' | ')) end
  return lister or nil
end

-- Hash every file in `files` that the cache does not already know. Appends to
-- the cache files as it goes, so an interrupted scan resumes where it stopped.
function M.hash(files, state, jobs, label)
  label = label or ''
  U.mkdirp(state)
  local fpath, mpath = state .. '/files.tsv', state .. '/members.tsv'
  local fcache = load_cache(fpath, FILE_COLS)
  local mcache = load_cache(mpath, MEMBER_COLS)

  local todo, bytes, by_path, rehash = {}, 0, {}, {}
  for _, f in ipairs(files) do
    local c = fcache[f.path]
    if c and c.size == tostring(f.size) and c.mtime == f.mtime and c.sha1 and #c.sha1 == 40 then
      f.sha1, f.hsha1 = c.sha1, c.hsha1 ~= '-' and c.hsha1 or nil
      -- cached before untrimming existed: only the extra hashes are missing
      if c.hsha1 == '-' and trimmed(f.path, f.size) then rehash[#rehash + 1] = f end
    else
      todo[#todo + 1] = f
      bytes = bytes + f.size
    end
    by_path[f.path] = f
  end
  U.log('hash: %d cached, %d to hash (%.1f GiB)', #files - #todo, #todo, bytes / 2 ^ 30)

  local fout = assert(io.open(fpath, 'ab'))
  if #todo > 0 then
    local list = state .. '/todo.lst'
    local lf = assert(io.open(list, 'wb'))
    for _, f in ipairs(todo) do lf:write(f.path, '\0') end
    lf:close()
    local p = assert(io.popen('xargs -0 -P' .. jobs .. ' -n 16 sha1sum -- < ' .. U.q(list)))
    local n, done = 0, 0
    for line in p:lines() do
      local h, name = parse_sha1_line(line)
      local f = name and by_path[name]
      if f then
        f.sha1 = h:upper()
        f.hsha1 = alt_hashes(f.path, f.size)
        fout:write(U.tsv_line(f.path, f.size, f.mtime, f.inode, f.sha1, f.hsha1 or '-'))
        fout:flush() -- every hash survives a crash or reboot
        n, done = n + 1, done + f.size
        U.progress('hash ' .. label, done / 2 ^ 30, bytes / 2 ^ 30, 'GiB')
        if n % 500 == 0 then
          U.log('hash: %d/%d files, %.1f/%.1f GiB', n, #todo, done / 2 ^ 30, bytes / 2 ^ 30)
        end
      end
    end
    p:close()
    os.remove(list)
  end
  if #rehash > 0 then U.log('hash: %d trimmed ROMs get untrimmed hashes', #rehash) end
  for i, f in ipairs(rehash) do
    f.hsha1 = alt_hashes(f.path, f.size)
    fout:write(U.tsv_line(f.path, f.size, f.mtime, f.inode, f.sha1, f.hsha1 or '-'))
    fout:flush()
    U.progress('untrim ' .. label, i, #rehash, 'ROMs')
  end
  fout:close()

  local have7z
  for _, f in ipairs(files) do
    local e = U.ext(f.path)
    if e == '7z' or e == 'rar' or (e == 'zip' and not M.have_unzip()) then have7z = M.lister() break end
  end
  local mout = assert(io.open(mpath, 'ab'))
  local listed, narch, seen = 0, 0, 0
  for _, f in ipairs(files) do if ARCHIVE[U.ext(f.path)] then narch = narch + 1 end end
  for _, f in ipairs(files) do
    if ARCHIVE[U.ext(f.path)] then
      seen = seen + 1
      U.progress('list archives ' .. label, seen, narch, 'archives')
      local key = f.path .. '\0' .. f.size .. '\0' .. f.mtime
      local m = mcache[key]
      -- A 7z/rar seen while no 7z was available was never really listed.
      if m and m.unlisted and #m == 0 and have7z then m = nil end
      if not m and (have7z or U.ext(f.path) == 'zip') then
        m = list_members(f.path, have7z)
        if #m == 0 then -- crc '-' marks "listed, and it really is empty"
          mout:write(U.tsv_line(f.path, f.size, f.mtime, '', '', '-'))
        end
        for _, r in ipairs(m) do
          mout:write(U.tsv_line(f.path, f.size, f.mtime, r.member, r.msize, r.crc))
        end
        mout:flush()
        listed = listed + 1
      end
      f.members = m or {}
    end
  end
  mout:close()
  U.log('archives: listed %d new', listed)
  local missing = 0
  for _, f in ipairs(files) do if not f.sha1 then missing = missing + 1 end end
  if missing > 0 then U.log('!! %d files could not be hashed (unreadable?)', missing) end
end

return M
