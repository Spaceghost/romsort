-- plugin/romsort.lua - :Romsort inside your own Neovim.
--
-- Put this checkout on 'runtimepath' (any plugin manager, or
-- vim.opt.rtp:append('/path/to/romsort')) and you get:
--
--   :Romsort                  the live dashboard in its own tab (q closes it)
--   :Romsort status           the one-screen summary
--   :Romsort build|plan|check start that run detached (it survives reboots)
--   :Romsort stop             stop the detached run
--   :Romsort log | report     open the full log or report in a tab
--
-- Set vim.g.romsort_config to use a config other than the checkout's config.lua.
if vim.g.loaded_romsort then return end
vim.g.loaded_romsort = 1

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function opts()
  local cfg = vim.g.romsort_config or (root .. '/config.lua')
  local ok, C = pcall(dofile, cfg)
  if not ok or type(C) ~= 'table' or not C.state then
    vim.notify('romsort: cannot read config ' .. cfg .. ': ' .. tostring(C), vim.log.levels.ERROR)
    return nil
  end
  return { state = C.state, bin = root .. '/romsort', cfg = cfg }
end

local subs = {
  status = function(o) require('romsort.dashboard').run(o, 'status') end,
  build = function(o) require('romsort.dashboard').run(o, 'start', 'build') end,
  plan = function(o) require('romsort.dashboard').run(o, 'start', 'plan') end,
  check = function(o) require('romsort.dashboard').run(o, 'start', 'check') end,
  stop = function(o) require('romsort.dashboard').run(o, 'stop') end,
  log = function(o) vim.cmd('tabnew ' .. vim.fn.fnameescape(o.state .. '/run.log') .. ' | normal! G') end,
  report = function(o) vim.cmd('tabnew ' .. vim.fn.fnameescape(o.state .. '/report.txt')) end,
}

vim.api.nvim_create_user_command('Romsort', function(c)
  local o = opts()
  if not o then return end
  if c.args == '' then return require('romsort.dashboard').open(o) end
  local f = subs[c.args]
  if not f then return vim.notify('romsort: unknown :Romsort ' .. c.args, vim.log.levels.ERROR) end
  f(o)
end, {
  nargs = '?',
  desc = 'romsort: ROM library dashboard and runs',
  complete = function(lead)
    local keys = vim.tbl_keys(subs)
    table.sort(keys)
    return vim.tbl_filter(function(k) return k:find(lead, 1, true) == 1 end, keys)
  end,
})
