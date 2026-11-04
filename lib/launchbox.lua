-- launchbox.lua - read every path LaunchBox stores in its Data/ XML, resolve it
-- to a file on disk, and rewrite those paths (and nothing else) for the sorted
-- library. Edits are textual so every other byte of the XML is preserved.
local U = require('util')
local M = {}

-- Data/*.xml and Data/**/*.xml, relative to the LaunchBox root.
function M.xml_files(root)
  local out = {}
  for _, p in ipairs(U.nul_lines('cd ' .. U.q(root) .. ' && find Data -type f -iname "*.xml" -print0 2>/dev/null')) do
    out[#out + 1] = p
  end
  table.sort(out)
  return out
end

-- Case-insensitive path lookup, because the paths were written on Windows.
local dir_cache = {}
local function list_dir(dir)
  local l = dir_cache[dir]
  if l then return l end
  l = {}
  for _, name in ipairs(U.nul_lines('find ' .. U.q(dir) .. ' -mindepth 1 -maxdepth 1 -printf "%f\\0" 2>/dev/null')) do
    l[name:lower()] = l[name:lower()] or name
  end
  dir_cache[dir] = l
  return l
end

local function ci_resolve(base, rel)
  local cur = base
  for part in rel:gmatch('[^/]+') do
    local real = list_dir(cur)[part:lower()]
    if not real then return nil end
    cur = cur .. '/' .. real
  end
  return cur
end

-- Windows path value -> absolute path on disk, or nil.
function M.resolve(value, root, drives)
  if value == '' then return nil end
  local drive, rest = value:match('^(%a):[\\/](.*)$')
  local rel = (rest or value):gsub('\\', '/'):gsub('^/+', ''):gsub('/+$', '')
  local bases = drive and (drives[drive:upper()] or {}) or { root }
  for _, b in ipairs(bases) do
    local p = b .. '/' .. rel
    if U.exists(p) then return p end
  end
  for _, b in ipairs(bases) do
    local p = ci_resolve(b, rel)
    if p then return p end
  end
  return nil
end

-- Every path-tag occurrence in one XML text, in order.
-- ref = { tag=, raw=, value=, s=, e= } where s..e spans `raw` in the text.
function M.refs_in(text, is_path_tag)
  local refs = {}
  local pos = 1
  while true do
    local s, e, tag, raw = text:find('<([%w_]+)>([^<]*)</%1>', pos)
    if not s then break end
    if is_path_tag(tag) and raw ~= '' then
      local vs = s + #tag + 2
      refs[#refs + 1] = { tag = tag, raw = raw, value = U.xml_unescape(raw), s = vs, e = vs + #raw - 1 }
    end
    pos = e + 1
  end
  return refs
end

-- Scan the whole Data tree. Returns list of { xml=, text=, refs= } with each
-- ref carrying .abs (resolved source path) or nil.
function M.scan(root, drives, is_path_tag)
  local docs = {}
  for _, rel in ipairs(M.xml_files(root)) do
    local text = U.read(root .. '/' .. rel)
    local refs = M.refs_in(text, is_path_tag)
    for _, r in ipairs(refs) do r.abs = M.resolve(r.value, root, drives) end
    docs[#docs + 1] = { xml = rel, text = text, refs = refs }
  end
  return docs
end

-- Relative output path -> the backslash form LaunchBox writes.
function M.winpath(rel)
  return (rel:gsub('/', '\\'))
end

-- Rewrite refs whose source file was placed somewhere in the output.
-- placed(abs) returns the output-relative path or nil (leave untouched).
function M.rewrite(doc, placed)
  local parts, last, changed = {}, 1, 0
  for _, r in ipairs(doc.refs) do
    local dst = r.abs and placed(r.abs)
    if dst then
      local new = U.xml_escape(M.winpath(dst))
      if new ~= r.raw then
        parts[#parts + 1] = doc.text:sub(last, r.s - 1)
        parts[#parts + 1] = new
        last = r.e + 1
        changed = changed + 1
      end
    end
  end
  parts[#parts + 1] = doc.text:sub(last)
  return table.concat(parts), changed
end

-- The XML with every path value blanked: two docs that differ only in paths
-- have equal skeletons.
function M.skeleton(text, is_path_tag)
  return (text:gsub('<([%w_]+)>([^<]*)</%1>', function(tag, raw)
    if is_path_tag(tag) then return '<' .. tag .. '></' .. tag .. '>' end
  end))
end

return M
