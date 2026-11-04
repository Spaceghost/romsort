-- dat.lua - load clrmamepro DATs (No-Intro, Redump, headered) into hash indexes.
local U = require('util')
local M = {}

-- Returns { sha1 = {[SHA1]=hit}, crc = {[CRC..':'..size]=hit}, games = {[name]=nroms} }
-- where hit = { game=, rom=, size=, dat= }.
function M.load(paths)
  local idx = { sha1 = {}, crc = {}, games = {} }
  for _, path in ipairs(paths) do
    local s = U.read(path)
    if not s then
      U.log('!! missing DAT %s', path)
    else
      local dat = U.basename(path):gsub('%.dat$', '')
      for block in s:gmatch('\ngame %((.-)\n%)') do
        local game = block:match('\n%s*name "(.-)"\n')
        if game then
          local n = 0
          for rom in block:gmatch('rom %( (.-) %)') do
            n = n + 1
            local hit = {
              game = game,
              rom = rom:match('name "(.-)" size') or rom:match('name (%S+)'),
              size = tonumber(rom:match('size (%d+)')),
              dat = dat,
            }
            local sha1 = rom:match('sha1 (%x+)')
            local crc = rom:match('crc (%x+)')
            if sha1 then idx.sha1[sha1:upper()] = idx.sha1[sha1:upper()] or hit end
            if crc and hit.size then
              local k = crc:upper() .. ':' .. hit.size
              idx.crc[k] = idx.crc[k] or hit
            end
          end
          idx.games[dat .. '\0' .. game] = n
        end
      end
    end
  end
  return idx
end

return M
