-- dashboard.lua - a live romsort dashboard that runs inside Neovim.
--
--   romsort ui            (runs: nvim --clean -c "lua require'dashboard'.open(...)")
--
-- Four windows, refreshed every two seconds from the files a run writes in the
-- state directory, so it can be opened and closed at any time without touching
-- the run itself:
--
--   +-- Run ----------------+-- Totals -------------+
--   | state, step, bar, ETA | report counts         |
--   +-- Check --------------+                       |
--   | last check result     |                       |
--   +-- Log ----------------------------------------+
--   | tail of run.log, follows                      |
--   +-----------------------------------------------+
--
-- Keys: q quit · r refresh · b start build · p start plan · x stop the run
--       L full log · R full report · ? help
local M = {}
local api, uv = vim.api, vim.uv or vim.loop

local S = {} -- state: paths, windows, buffers, timer

local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function lines_of(s)
  local t = {}
  for l in ((s or '') .. '\n'):gmatch('(.-)\r?\n') do t[#t + 1] = l end
  if t[#t] == '' then t[#t] = nil end
  return t
end

local function tail(path, n)
  local f = io.open(path, 'rb')
  if not f then return {} end
  local size = f:seek('end')
  f:seek('set', math.max(0, size - 64 * 1024))
  local t = lines_of(f:read('*a'))
  f:close()
  if size > 64 * 1024 then table.remove(t, 1) end -- first line is partial
  while #t > n do table.remove(t, 1) end
  return t
end

local function running()
  local lock = S.state .. '/lock'
  if not uv.fs_stat(lock) then return false end
  local r = vim.system({ 'flock', '-n', lock, 'true' }):wait()
  return r.code ~= 0
end

local function bar(pct, width)
  local full = math.floor(pct / 100 * width + 0.5)
  return string.rep('█', full) .. string.rep('░', width - full)
end

local function age(t)
  local s = os.time() - t
  if s < 90 then return s .. 's' end
  if s < 5400 then return math.floor(s / 60) .. 'm' end
  return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s % 3600 / 60))
end

-- Each pane: a function returning lines plus a list of {line, hl} highlights.
local panes = {}

function panes.run(width)
  local out, hl = {}, {}
  local goal = read(S.state .. '/goal')
  local what = goal and lines_of(goal)[1]
  local state, group
  if running() then
    state, group = 'RUNNING  ' .. (what or ''), 'RomsortRun'
  elseif what then
    state, group = 'INTERRUPTED  ' .. what .. '  (romsort resume continues it)', 'RomsortWarn'
  elseif uv.fs_stat(S.state .. '/goal.failed') then
    state, group = 'FAILED 3 times  (see the log, then start again)', 'RomsortBad'
  else
    state, group = 'IDLE', 'RomsortDim'
  end
  out[#out + 1] = ' ' .. state
  hl[#hl + 1] = { #out, group }
  out[#out + 1] = ''

  local prog = read(S.state .. '/progress')
  for _, l in ipairs(lines_of(prog)) do
    local k, v = l:match('^(%w+):%s*(.*)$')
    if k == 'step' then
      out[#out + 1] = ' ' .. v
      hl[#hl + 1] = { #out, (v:find('FAILED') and 'RomsortBad') or (v:find('finished') and 'RomsortOk') or 'RomsortHead' }
    elseif k == 'done' then
      local pct = tonumber(v:match('%(([%d.]+)%%%)')) or 0
      out[#out + 1] = ' ' .. bar(pct, math.max(10, math.min(width - 12, 60))) .. string.format(' %5.1f%%', pct)
      hl[#hl + 1] = { #out, 'RomsortBar' }
      out[#out + 1] = ' ' .. v:gsub('%s*%([%d.]+%%%)', '')
    elseif k == 'eta' then
      out[#out + 1] = ' eta ' .. v
    elseif k == 'updated' then
      local st = uv.fs_stat(S.state .. '/progress')
      out[#out + 1] = ' ' .. v
      hl[#hl + 1] = { #out, 'RomsortDim' }
      if st and running() and os.time() - st.mtime.sec > 300 then
        out[#out + 1] = ' no progress written for ' .. age(st.mtime.sec) .. ' (a big file, or stuck?)'
        hl[#hl + 1] = { #out, 'RomsortWarn' }
      end
    end
  end
  if not prog then out[#out + 1] = ' no run has written progress yet' end
  out[#out + 1] = ''
  out[#out + 1] = ' q quit  r refresh  b build  p plan  x stop  L log  R report  ? help'
  hl[#hl + 1] = { #out, 'RomsortDim' }
  return out, hl
end

function panes.totals()
  local out, hl = {}, {}
  local rep = lines_of(read(S.state .. '/report.txt'))
  if #rep == 0 then return { ' no report yet: run a plan or build' }, {} end
  local blanks = 0
  out[#out + 1] = ' ' .. rep[1]
  hl[#hl + 1] = { #out, 'RomsortHead' }
  for i = 2, #rep do
    local l = rep[i]
    if l == '' then blanks = blanks + 1 end
    if blanks < 2 and l ~= '' then
      out[#out + 1] = l
      if l:find('unverified') or l:find('clash') then hl[#hl + 1] = { #out, 'RomsortWarn' } end
      if l:find('renamed to DAT') then hl[#hl + 1] = { #out, 'RomsortOk' } end
    end
    if l:find('^last build:') then
      out[#out + 1] = ''
      out[#out + 1] = ' ' .. l
      hl[#hl + 1] = { #out, l:find('conflict=') and 'RomsortWarn' or 'RomsortDim' }
    end
  end
  return out, hl
end

function panes.check()
  local out, hl = {}, {}
  local c = lines_of(read(S.state .. '/check.txt'))
  if #c == 0 then return { ' no check yet: it runs at the end of every build' }, {} end
  for i, l in ipairs(c) do
    out[#out + 1] = ' ' .. l
    if i == 1 then hl[#hl + 1] = { #out, l:find('PASSED') and 'RomsortOk' or 'RomsortBad' } end
  end
  local miss = S.state .. '/launchbox-missing-at-source.tsv'
  if uv.fs_stat(miss) then
    out[#out + 1] = ''
    out[#out + 1] = ' paths already broken before romsort: ' .. miss
    hl[#hl + 1] = { #out, 'RomsortDim' }
  end
  return out, hl
end

function panes.log(_, height)
  local out, hl = {}, {}
  for _, l in ipairs(tail(S.state .. '/run.log', math.max(height, 20) * 4)) do
    out[#out + 1] = l
    if l:find('^===') then hl[#hl + 1] = { #out, 'RomsortHead' }
    elseif l:find('!!') or l:find('FAIL') or l:find('CONFLICT') then hl[#hl + 1] = { #out, 'RomsortBad' } end
  end
  return out, hl
end

local ns = api.nvim_create_namespace('romsort')

local function paint(name)
  local w = S.wins[name]
  if not (w and api.nvim_win_is_valid(w)) then return end
  local buf = api.nvim_win_get_buf(w)
  local out, hl = panes[name](api.nvim_win_get_width(w), api.nvim_win_get_height(w))
  local key = table.concat(out, '\n')
  if S.last[name] == key then return end
  S.last[name] = key
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    api.nvim_buf_set_extmark(buf, ns, h[1] - 1, 0, { line_hl_group = h[2] })
  end
  if name == 'log' then api.nvim_win_set_cursor(w, { math.max(1, #out), 0 }) end
end

local function refresh()
  for name in pairs(S.wins) do paint(name) end
end

local function romsort(...)
  local r = vim.system({ S.bin, ..., '--config', S.cfg }, { text = true }):wait()
  local msg = vim.trim((r.stdout or '') .. (r.stderr or ''))
  if msg ~= '' then vim.notify(msg, r.code == 0 and vim.log.levels.INFO or vim.log.levels.WARN) end
  S.last = {}
  refresh()
end

local function scratch(name, title)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  pcall(api.nvim_buf_set_name, buf, 'romsort://' .. name)
  return buf, title
end

local function dress(win, title)
  local o = vim.wo[win]
  o.number, o.relativenumber, o.signcolumn, o.foldcolumn = false, false, 'no', '0'
  o.wrap, o.cursorline, o.list, o.spell = false, false, false, false
  o.winbar = '%#RomsortTitle# ' .. title .. ' %*'
  o.winfixbuf = true
end

local function help()
  vim.notify(table.concat({
    'romsort dashboard',
    '  q quit (the run keeps going)   r refresh now',
    '  b start a build   p start a plan   x stop the run',
    '  L open the full log   R open the full report',
  }, '\n'))
end

function M.open(state, bin, cfg)
  if vim.v.vim_did_enter == 0 then -- -c runs before startup finishes; wait for it
    api.nvim_create_autocmd('VimEnter', { once = true, callback = function() M.open(state, bin, cfg) end })
    return
  end
  S = { state = state, bin = bin, cfg = cfg, wins = {}, last = {} }

  for g, spec in pairs({
    RomsortTitle = { link = 'TabLineSel' }, RomsortHead = { link = 'Title' },
    RomsortOk = { link = 'DiagnosticOk' }, RomsortWarn = { link = 'DiagnosticWarn' },
    RomsortBad = { link = 'DiagnosticError' }, RomsortDim = { link = 'Comment' },
    RomsortRun = { link = 'DiagnosticInfo' }, RomsortBar = { link = 'DiagnosticInfo' },
  }) do api.nvim_set_hl(0, g, vim.tbl_extend('keep', spec, { default = true })) end

  vim.o.laststatus, vim.o.showmode, vim.o.ruler, vim.o.cmdheight = 0, false, false, 1
  vim.o.mouse = 'a'
  vim.cmd('silent! only')

  local run = api.nvim_get_current_win()
  vim.cmd('botright split')
  local log = api.nvim_get_current_win()
  api.nvim_win_set_height(log, math.max(8, math.floor(vim.o.lines * 0.4)))
  api.nvim_set_current_win(run)
  vim.cmd('rightbelow vsplit')
  local totals = api.nvim_get_current_win()
  api.nvim_set_current_win(run)
  vim.cmd('rightbelow split')
  local check = api.nvim_get_current_win()
  api.nvim_win_set_height(run, 11)

  for name, spec in pairs({ run = { run, 'Run' }, totals = { totals, 'Totals' },
                            check = { check, 'Check' }, log = { log, 'Log  ' .. state .. '/run.log' } }) do
    local buf = scratch(name)
    vim.wo[spec[1]].winfixbuf = false
    api.nvim_win_set_buf(spec[1], buf)
    dress(spec[1], spec[2])
    S.wins[name] = spec[1]
    local function map(lhs, fn) vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true }) end
    map('q', function() vim.cmd('qa!') end)
    map('r', function() S.last = {}; refresh() end)
    map('b', function() if vim.fn.confirm('Start a build?', '&Yes\n&No', 2) == 1 then romsort('start', 'build') end end)
    map('p', function() if vim.fn.confirm('Start a plan (dry run)?', '&Yes\n&No', 2) == 1 then romsort('start', 'plan') end end)
    map('x', function() if vim.fn.confirm('Stop the run? It will not resume.', '&Yes\n&No', 2) == 1 then romsort('stop') end end)
    map('L', function() vim.cmd('tabnew ' .. vim.fn.fnameescape(state .. '/run.log') .. ' | normal! G') end)
    map('R', function() vim.cmd('tabnew ' .. vim.fn.fnameescape(state .. '/report.txt')) end)
    map('?', help)
  end
  api.nvim_set_current_win(run)

  refresh()
  S.timer = uv.new_timer()
  S.timer:start(2000, 2000, vim.schedule_wrap(refresh))
  api.nvim_create_autocmd('VimResized', { callback = function() S.last = {}; refresh() end })
end

-- For tests and `romsort ui --print`: render every pane once as plain text.
function M.render(state)
  S = { state = state, wins = {}, last = {} }
  local t = {}
  for _, name in ipairs({ 'run', 'totals', 'check', 'log' }) do
    t[#t + 1] = '== ' .. name
    for _, l in ipairs((panes[name](80, 10))) do t[#t + 1] = l end
  end
  return table.concat(t, '\n')
end

return M
