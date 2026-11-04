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

local function load_cache(path, cols)
  local cache = {}
  for _, r in ipairs(U.tsv_read(path, cols)) do
    if cols == MEMBER_COLS then
      local key = r.path .. '\0' .. r.size .. '\0' .. r.mtime
      local list = cache[key] or {}
      if r.member ~= '' then list[#list + 1] = r end
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

local function list_members(path, have7z)
  local out = {}
  local e = U.ext(path)
  if e == 'zip' and not have7z then
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

-- Hash every file in `files` that the cache does not already know. Appends to
-- the cache files as it goes, so an interrupted scan resumes where it stopped.
function M.hash(files, state, jobs)
  U.mkdirp(state)
  local fpath, mpath = state .. '/files.tsv', state .. '/members.tsv'
  local fcache = load_cache(fpath, FILE_COLS)
  local mcache = load_cache(mpath, MEMBER_COLS)
  local have7z
  for _, t in ipairs({ '7zz', '7z' }) do
    if U.sh('command -v ' .. t .. ' >/dev/null 2>&1') then have7z = t break end
  end
  if not have7z then U.log('note: no 7z, so .7z/.rar contents are not matched (zip still is)') end

  local todo, bytes, by_path = {}, 0, {}
  for _, f in ipairs(files) do
    local c = fcache[f.path]
    if c and c.size == tostring(f.size) and c.mtime == f.mtime and c.sha1 ~= '' then
      f.sha1, f.hsha1 = c.sha1, c.hsha1 ~= '-' and c.hsha1 or nil
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
        local hl = header_len(f.path, f.size)
        if hl > 0 then
          local hp = io.popen('tail -c +' .. (hl + 1) .. ' -- ' .. U.q(f.path) .. ' | sha1sum')
          f.hsha1 = (hp:read('*l') or ''):match('^(%x+)')
          hp:close()
          if f.hsha1 then f.hsha1 = f.hsha1:upper() end
        end
        fout:write(U.tsv_line(f.path, f.size, f.mtime, f.inode, f.sha1, f.hsha1 or '-'))
        n, done = n + 1, done + f.size
        if n % 500 == 0 then
          fout:flush()
          U.log('hash: %d/%d files, %.1f/%.1f GiB', n, #todo, done / 2 ^ 30, bytes / 2 ^ 30)
        end
      end
    end
    p:close()
    os.remove(list)
  end
  fout:close()

  local mout = assert(io.open(mpath, 'ab'))
  local listed = 0
  for _, f in ipairs(files) do
    if ARCHIVE[U.ext(f.path)] then
      local key = f.path .. '\0' .. f.size .. '\0' .. f.mtime
      local m = mcache[key]
      if not m then
        m = list_members(f.path, have7z)
        if #m == 0 then
          mout:write(U.tsv_line(f.path, f.size, f.mtime, '', '', ''))
        end
        for _, r in ipairs(m) do
          mout:write(U.tsv_line(f.path, f.size, f.mtime, r.member, r.msize, r.crc))
        end
        listed = listed + 1
      end
      f.members = m
    end
  end
  mout:close()
  U.log('archives: listed %d new', listed)
  local missing = 0
  for _, f in ipairs(files) do if not f.sha1 then missing = missing + 1 end end
  if missing > 0 then U.log('!! %d files could not be hashed (unreadable?)', missing) end
end

return M
