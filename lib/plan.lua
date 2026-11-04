-- plan.lua - decide where every source file goes in the sorted LaunchBox root.
--
-- Rules, in order:
--   * Sources are never written. The output is hardlinks (or copies of small
--     mutable files) so deleting the sorted tree loses nothing.
--   * Identical content (same SHA-1) is placed once; later copies point at it.
--   * A file is renamed to its DAT name only when it is a single-file game that
--     sits directly in its platform folder, its platform allows renaming, and
--     nothing in its folder is part of a multi-file disc image.
--   * LaunchBox-layout sources keep their platform folder and subpaths; card
--     sources are mapped onto LaunchBox platform names, matched ROMs go to the
--     platform of the DAT that matched them, unmatched ones to Unverified/.
local U = require('util')
local DAT = require('dat')
local M = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v:lower()] = true end
  return s
end

-- Characters Windows forbids in names; LaunchBox users may run this tree there.
local function winsafe(name)
  return (name:gsub('[<>:"/\\|%?%*]', function(c) return c == ':' and ' -' or '_' end):gsub('[ .]+$', ''))
end

function M.new(C)
  local self = { C = C, placed = {}, by_sha1 = {}, taken = {}, ops = {}, report = {} }
  self.multi = set(C.multi_ext)
  self.skip_dirs = set(C.skip_dirs)
  self.skip_ext = set(C.skip_ext)
  self.copy_ext = set(C.copy_ext)
  self.copy_dirs = set(C.copy_dirs)
  self.alias, self.by_name, self.dat_platform = {}, {}, {}
  for _, p in ipairs(C.platforms) do
    self.by_name[p.name:lower()] = p
    self.alias[p.name:lower()] = p
    for _, a in ipairs(p.aliases or {}) do self.alias[a:lower()] = self.alias[a:lower()] or p end
    for _, d in ipairs(p.dats or {}) do
      self.dat_platform[U.basename(d):gsub('%.dat$', '')] = self.dat_platform[U.basename(d):gsub('%.dat$', '')] or p
    end
  end
  self.idx = {}
  return setmetatable(self, { __index = M })
end

function M:count(key, n)
  self.report[key] = (self.report[key] or 0) + (n or 1)
end

function M:dat_index(p)
  if not p or not p.dats then return nil end
  if not self.idx[p.name] then
    local paths = {}
    for _, d in ipairs(p.dats) do paths[#paths + 1] = self.C.dats .. '/' .. d end
    self.idx[p.name] = DAT.load(paths)
  end
  return self.idx[p.name]
end

-- Does this file (or the archive's full member list) match one DAT game?
function M:match(f, idx)
  if not idx then return nil end
  if f.members and #f.members > 0 then
    local game, dat
    for _, m in ipairs(f.members) do
      local hit = idx.crc[m.crc .. ':' .. m.msize]
      if not hit then return nil end
      if game and (hit.game ~= game or hit.dat ~= dat) then return nil end
      game, dat = hit.game, hit.dat
    end
    if idx.games[dat .. '\0' .. game] ~= #f.members then return nil end
    return { game = game, dat = dat, archive = true }
  end
  local hit = (f.sha1 and idx.sha1[f.sha1]) or (f.hsha1 and idx.sha1[f.hsha1])
  if hit and idx.games[hit.dat .. '\0' .. hit.game] == 1 then return hit end
  return nil
end

-- Reserve an output-relative path for content `sha1`, uniquifying on clashes.
function M:claim(rel, sha1, label)
  local key = rel:lower() -- LaunchBox runs on case-insensitive Windows
  local owner = self.taken[key]
  if not owner or owner == sha1 then
    self.taken[key] = sha1
    return rel
  end
  local dir, base = U.dirname(rel), U.basename(rel)
  local stem, ext = base:match('^(.*)(%.[^.]+)$')
  stem, ext = stem or base, ext or ''
  for i = 1, 999 do
    local cand = dir .. '/' .. stem .. (i == 1 and (' [' .. label .. ']') or (' [' .. label .. ' ' .. i .. ']')) .. ext
    if not self.taken[cand:lower()] then
      self.taken[cand:lower()] = sha1
      self:count('name clash, suffixed')
      return cand
    end
  end
  error('cannot uniquify ' .. rel)
end

-- `dedupe` is only for standalone files: a disc track or a port's data file
-- must stay beside its siblings even when identical content exists elsewhere
-- (hardlinks cost nothing, so this only trims clutter).
function M:place(f, rel, mode, dedupe)
  local id = f.sha1 or ('inode:' .. f.inode)
  if dedupe and f.sha1 and self.by_sha1[f.sha1] then
    self.placed[f.path] = self.by_sha1[f.sha1]
    self:count('duplicate content, linked to first copy')
    return
  end
  rel = self:claim(rel, id, f.label)
  self.placed[f.path] = rel
  if dedupe and f.sha1 then self.by_sha1[f.sha1] = rel end
  self.ops[#self.ops + 1] = { op = mode, src = f.path, dst = rel, inode = f.inode, size = f.size }
end

-- Folders holding a multi-file disc image: nothing in them is renamed.
function M:multi_dirs(files)
  local d = {}
  for _, f in ipairs(files) do
    if self.multi[U.ext(f.path)] then d[U.dirname(f.path)] = true end
  end
  return d
end

-- One source tree.
function M:add_source(src, files)
  local multi_dir = self:multi_dirs(files)
  local root = src.root
  for _, f in ipairs(files) do
    f.label = src.label
    local rel = f.path:sub(#root + 2)
    local top, sub = rel:match('^([^/]+)/(.+)$')
    local p = top and self.alias[top:lower()]
    if src.layout == 'launchbox' then
      if not top then
        self:count('launchbox: file outside a platform folder, kept')
        self:place(f, 'Games/' .. rel, 'link')
      else
        p = self.by_name[top:lower()] or p
        local folder = top -- keep LaunchBox's own folder name verbatim
        local flat = not sub:find('/')
        local hit = flat and p and p.rename ~= false and not multi_dir[U.dirname(f.path)]
          and self:match(f, self:dat_index(p))
        if hit then
          local name = hit.archive and (hit.game .. '.' .. U.ext(f.path))
            or (U.stem(hit.rom) .. '.' .. U.ext(f.path))
          self:count('renamed to DAT name')
          self:place(f, 'Games/' .. folder .. '/' .. winsafe(name), 'link', true)
        else
          self:count(p and 'kept original name' or 'kept original name (no platform rules)')
          self:place(f, 'Games/' .. folder .. '/' .. sub, 'link', flat and not multi_dir[U.dirname(f.path)])
        end
      end
    else
      local parts = {}
      for part in rel:gmatch('[^/]+') do parts[#parts + 1] = part end
      local skip = not p or not sub
      for i = 2, #parts - 1 do if self.skip_dirs[parts[i]:lower()] then skip = true end end
      if not skip and self.skip_ext[U.ext(f.path)] then skip = true end
      if skip then
        self:count('card: not a game here (skipped, source untouched)')
        self.report.skipped = self.report.skipped or {}
        local k = src.label .. '/' .. (top or '.')
        self.report.skipped[k] = (self.report.skipped[k] or 0) + 1
      elseif p.keep_tree then
        self:place(f, 'Games/' .. p.name .. '/' .. sub, 'link')
      else
        local flat = not sub:find('/')
        local hit = p.rename ~= false and not multi_dir[U.dirname(f.path)] and self:match(f, self:dat_index(p))
        if hit then
          local dest = self.dat_platform[hit.dat] or p
          local name = hit.archive and (hit.game .. '.' .. U.ext(f.path))
            or (U.stem(hit.rom) .. '.' .. U.ext(f.path))
          self:count('renamed to DAT name')
          self:place(f, 'Games/' .. dest.name .. '/' .. winsafe(name), 'link', true)
        elseif p.rename == false or not flat or multi_dir[U.dirname(f.path)] then
          self:count('kept original name')
          self:place(f, 'Games/' .. p.name .. '/' .. sub, 'link', flat and not multi_dir[U.dirname(f.path)])
        else
          self:count('unverified (no DAT match)')
          self:place(f, 'Games/' .. p.name .. '/Unverified/' .. sub, 'link', true)
        end
      end
    end
  end
end

-- Everything in the LaunchBox install outside Games/ is mirrored at the same
-- path. Data/ and mutable files are copied so LaunchBox writing them in the
-- sorted root never touches the original.
function M:add_launchbox(root, files)
  for _, f in ipairs(files) do
    local rel = f.path:sub(#root + 2)
    if not rel:match('^Games/') then
      f.label = 'LB'
      local top = rel:match('^([^/]+)/')
      local copy = (top and self.copy_dirs[top:lower()]) or self.copy_ext[U.ext(rel)]
      self.taken[rel:lower()] = 'inode:' .. f.inode
      self.placed[f.path] = rel
      self.ops[#self.ops + 1] = { op = copy and 'copy' or 'link', src = f.path, dst = rel, inode = f.inode, size = f.size }
    end
  end
end

-- A LaunchBox path that resolved to a file no source covers (another drive):
-- give it a home under its drive-relative path so the reference survives.
function M:adopt(abs, f)
  if self.placed[abs] then return end
  local rel = 'External/' .. abs:gsub('^/+', '')
  self:count('referenced by LaunchBox outside every source, adopted')
  self:place(f, rel, 'link', false)
end

return M
