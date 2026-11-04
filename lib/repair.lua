-- repair.lua - point LaunchBox entries that were already broken at a file that
-- really is there. Libraries get reorganised by hand: scene releases end up in
-- their own folders, ROM packs get extracted and renamed. LaunchBox then keeps
-- the old path and the game will not start.
--
-- Only ApplicationPath values that do not resolve in the original are
-- considered, and only files from LaunchBox-shaped sources under the same
-- platform folder (Games/<Platform>/) are candidates. A repair needs exactly
-- one candidate (copies with identical content count as one):
--   'same file name'  the file's own name, now in another folder
--   'same title'      the title with pack numbering, punctuation and
--                     extension ignored, e.g.
--                     Pack.0001.to.0500\0294 - True Swing Golf (USA).zip
--                     -> True Swing Golf (USA) (En,Ja,Fr,De,Es,It).nds
-- Anything else stays as it was. The original XML is never touched; only the
-- sorted library's copy is rewritten.
local U = require('util')
local M = {}

local TAGS = { ApplicationPath = true }

-- Title key: no extension, no leading pack number ("0294 - "), lowercase,
-- letters, digits and parentheses only.
function M.title(name)
  name = name:gsub('%.[%w]+$', ''):lower()
  name = name:gsub('^%d%d%d%d? ?%- ?', '')
  return (name:gsub('[^%w%(%)]', ''))
end

local MIN_TITLE = 6 -- shorter keys are too easy to match by accident

local function platform_of(value)
  local v = value:gsub('\\', '/')
  return v:match('^%a:/[Gg]ames/([^/]+)/') or v:match('^[Gg]ames/([^/]+)/')
end

-- sources: list of { src=, files= } as built by plan(). skip_ext: set.
function M.index(sources, skip_ext)
  local by_plat = {}
  for _, s in ipairs(sources) do
    if s.src.layout == 'launchbox' then
      local root = s.src.root .. '/'
      for _, f in ipairs(s.files) do
        local rel = f.path:sub(1, #root) == root and f.path:sub(#root + 1)
        local plat, rest = (rel or ''):match('^([^/]+)/(.+)$')
        if plat and f.sha1 and not skip_ext[U.ext(f.path)] then
          local key = plat:lower()
          local p = by_plat[key]
          if not p then p = { base = {}, title = {} }; by_plat[key] = p end
          local base = rest:match('([^/]+)$')
          local b = base:lower()
          p.base[b] = p.base[b] or {}
          table.insert(p.base[b], f)
          local t = M.title(base)
          local bucket = t:sub(1, MIN_TITLE)
          p.title[bucket] = p.title[bucket] or {}
          table.insert(p.title[bucket], { t = t, f = f })
        end
      end
    end
  end
  return by_plat
end

-- The one file among `list` (copies of the same content count once), or nil.
local function only(list)
  local f
  for _, c in ipairs(list) do
    if f and c.sha1 ~= f.sha1 then return nil end
    f = f or c
  end
  return f
end

-- Sets r.repair (source path) and r.how on refs that can be repaired.
-- Returns the number repaired.
function M.apply(docs, index)
  local n = 0
  for _, d in ipairs(docs) do
    for _, r in ipairs(d.refs) do
      local plat = not r.abs and TAGS[r.tag] and platform_of(r.value)
      local p = plat and index[plat:lower()]
      if p then
        local base = r.value:match('([^\\/]+)$')
        local hit, how = only(p.base[base:lower()] or {}), 'same file name'
        if not hit and not p.base[base:lower()] then
          local t = M.title(base)
          if #t >= MIN_TITLE then
            local found = {}
            for _, c in ipairs(p.title[t:sub(1, MIN_TITLE)] or {}) do
              if c.t:sub(1, #t) == t then found[#found + 1] = c.f end
            end
            hit, how = only(found), 'same title'
          end
        end
        if hit then
          r.repair, r.how = hit.path, how
          n = n + 1
        end
      end
    end
  end
  return n
end

return M
