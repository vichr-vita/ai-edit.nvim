local M = {}

local uv = vim.uv or vim.loop
local health_state = require 'ai_edit.health_state'
local activity_limit = { max_bytes = 8192, max_lines = 120, entry_bytes = 2048, entry_lines = 24 }
local history_limit = 100
local hidden_cursor_segment = 'n-v-ve-o-i-r-sm:AIEditHiddenCursor'
local jobs = {}
local instruction_history = {}
local status_timer
local status_frame = 1
local mapped_keymap
local cursor_state = {
  base = nil,
  scheduled = false,
  writing = false,
}
local options = {
  keymap = '<leader>ai',
  command = 'pi',
  config_dir = vim.fn.stdpath 'config' .. '/ai-edit/pi',
  model = false,
  thinking = 'off',
  timeout_ms = 5 * 60 * 1000,
  max_bytes = 1024 * 1024,
  width = 0.5,
  height = 0.2,
  status = {
    text = 'AI is Working...',
    color = '#d946ef',
    interval_ms = 80,
    frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
  },
}

local function notify(message, level)
  vim.notify('AI edit: ' .. message, level or vim.log.levels.INFO)
end

local function redraw_statusline()
  if vim.in_fast_event() then
    vim.schedule(redraw_statusline)
    return
  end
  local lualine = package.loaded.lualine
  if lualine and type(lualine.refresh) == 'function' then
    pcall(lualine.refresh, { scope = 'tabpage', place = { 'statusline' }, force = true })
  end
  pcall(vim.cmd, 'redrawstatus')
end

local function statusline_literal(value)
  return value:gsub('%%', '%%%%')
end

local function strip_hidden_cursor(value)
  local segments = {}
  for segment in tostring(value or ''):gmatch '[^,]+' do
    if segment ~= hidden_cursor_segment then
      table.insert(segments, segment)
    end
  end
  return table.concat(segments, ',')
end

local function current_target_locked()
  local job = jobs[vim.api.nvim_get_current_buf()]
  return job ~= nil and not job.done and job.locked == true
end

local function set_guicursor(value)
  if vim.o.guicursor == value then
    return
  end
  cursor_state.writing = true
  local ok = pcall(vim.cmd, 'noautocmd let &guicursor = ' .. vim.fn.string(value))
  cursor_state.writing = false
  return ok
end

local function sync_caret()
  local clean = strip_hidden_cursor(vim.o.guicursor)
  if clean ~= vim.o.guicursor or cursor_state.base == nil then
    cursor_state.base = clean
  elseif not current_target_locked() then
    cursor_state.base = clean
  end

  local desired = cursor_state.base or ''
  if current_target_locked() then
    desired = desired == '' and hidden_cursor_segment or (desired .. ',' .. hidden_cursor_segment)
  end
  set_guicursor(desired)
end

local function schedule_caret_sync()
  if cursor_state.scheduled then
    return
  end
  cursor_state.scheduled = true
  vim.schedule(function()
    cursor_state.scheduled = false
    cursor_state.base = strip_hidden_cursor(vim.o.guicursor)
    sync_caret()
  end)
end

local function valid_activity_window(job)
  return job.activity_window and vim.api.nvim_win_is_valid(job.activity_window)
end

local function close_activity_window(job)
  if valid_activity_window(job) then
    pcall(vim.api.nvim_win_close, job.activity_window, true)
  end
  job.activity_window = nil
  job.activity_target_window = nil
end

local function visible_target_window(job)
  if not vim.api.nvim_buf_is_valid(job.buffer) then
    return nil
  end
  local current_tab = vim.api.nvim_get_current_tabpage()
  local candidates = {}
  for _, window in ipairs(vim.fn.win_findbuf(job.buffer)) do
    if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_tabpage(window) == current_tab and vim.api.nvim_win_get_config(window).relative == '' then
      candidates[window] = true
    end
  end
  local current = vim.api.nvim_get_current_win()
  if candidates[current] then
    return current
  end
  if job.target_window and candidates[job.target_window] then
    return job.target_window
  end
  return next(candidates)
end

local function activity_window_config(target_window)
  local target_width = vim.api.nvim_win_get_width(target_window)
  local target_height = vim.api.nvim_win_get_height(target_window)
  if target_width < 3 or target_height < 3 then
    return nil
  end
  local width = math.max(1, math.min(42, math.floor(target_width * 0.42), target_width - 2))
  local height = math.max(1, math.min(12, math.floor(target_height * 0.5), target_height - 2))
  return {
    relative = 'win',
    win = target_window,
    row = 0,
    col = math.max(0, target_width - width - 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' AI edit ',
    title_pos = 'center',
    focusable = false,
    mouse = false,
    noautocmd = true,
    zindex = 45,
  }
end

local function scroll_activity(job)
  if not valid_activity_window(job) or not job.activity_buffer or not vim.api.nvim_buf_is_valid(job.activity_buffer) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(job.activity_buffer)
  pcall(vim.api.nvim_win_set_cursor, job.activity_window, { math.max(1, line_count), 0 })
end

local function sync_activity_view(job)
  if job.done or not job.activity_buffer or not vim.api.nvim_buf_is_valid(job.activity_buffer) then
    close_activity_window(job)
    return
  end
  local target_window = visible_target_window(job)
  if not target_window then
    close_activity_window(job)
    return
  end

  local config = activity_window_config(target_window)
  if not config then
    close_activity_window(job)
    return
  end
  if valid_activity_window(job) then
    local current_config = vim.api.nvim_win_get_config(job.activity_window)
    if job.activity_target_window ~= target_window or current_config.width ~= config.width or current_config.height ~= config.height then
      local ok = pcall(vim.api.nvim_win_set_config, job.activity_window, config)
      if not ok then
        close_activity_window(job)
      end
    end
  end
  if not valid_activity_window(job) then
    local ok, window = pcall(vim.api.nvim_open_win, job.activity_buffer, false, config)
    if not ok then
      return
    end
    job.activity_window = window
    vim.wo[window].wrap = true
    vim.wo[window].cursorline = false
  end
  job.activity_target_window = target_window
  scroll_activity(job)
end

local function sync_activity_views()
  for _, job in pairs(jobs) do
    sync_activity_view(job)
  end
end

local function sanitize_activity_text(text)
  text = tostring(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  return text:gsub('[%z\1-\9\11\12\14-\31\127]', ' ')
end

local function utf8_tail(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  local first = #text - max_bytes + 1
  while first <= #text do
    local byte = text:byte(first)
    if not byte or byte < 128 or byte >= 192 then
      break
    end
    first = first + 1
  end
  return text:sub(first)
end

local function bounded_activity_entry(text)
  local marker = '[earlier entry truncated]'
  text = sanitize_activity_text(text)
  local lines = vim.split(text, '\n', { plain = true })
  local truncated = false
  if #lines > activity_limit.entry_lines then
    local kept = {}
    for index = #lines - activity_limit.entry_lines + 2, #lines do
      table.insert(kept, lines[index])
    end
    lines = kept
    truncated = true
  end
  text = table.concat(lines, '\n')
  if #text > activity_limit.entry_bytes then
    text = utf8_tail(text, activity_limit.entry_bytes - #marker - 1)
    truncated = true
  end
  if truncated then
    text = marker .. '\n' .. text
  end
  return vim.split(text, '\n', { plain = true })
end

local function activity_rendered_lines(job)
  local lines = {}
  if job.activity_truncated then
    table.insert(lines, '[earlier activity truncated]')
  end
  for _, entry in ipairs(job.activity_entries) do
    vim.list_extend(lines, entry.lines)
  end
  if #lines == 0 then
    return { '' }
  end
  return lines
end

local function activity_size(lines)
  local bytes = math.max(0, #lines - 1)
  for _, line in ipairs(lines) do
    bytes = bytes + #line
  end
  return bytes, #lines
end

local function render_activity(job)
  if not job.activity_buffer or not vim.api.nvim_buf_is_valid(job.activity_buffer) then
    return
  end
  local lines = activity_rendered_lines(job)
  local ok = pcall(vim.api.nvim_buf_call, job.activity_buffer, function()
    vim.cmd 'noautocmd setlocal modifiable noreadonly'
    vim.api.nvim_buf_set_lines(job.activity_buffer, 0, -1, false, lines)
    vim.cmd 'noautocmd setlocal nomodifiable readonly'
  end)
  if not ok then
    return
  end
  sync_activity_view(job)
end

local function redact_activity(job, text)
  text = tostring(text or '')
  for _, value in ipairs { job.stage_root, job.stage_target, job.stage_context } do
    if type(value) == 'string' and value ~= '' then
      text = text:gsub(vim.pesc(value), '[private path]')
    end
  end
  return text
end

local function add_activity(job, text, key)
  if not job.activity_entries then
    return
  end
  local entry = { key = key, lines = bounded_activity_entry(redact_activity(job, text)) }
  local replaced = false
  if key then
    for index, current in ipairs(job.activity_entries) do
      if current.key == key then
        job.activity_entries[index] = entry
        replaced = true
        break
      end
    end
  end
  if not replaced then
    table.insert(job.activity_entries, entry)
  end
  while true do
    local lines = activity_rendered_lines(job)
    local bytes, line_count = activity_size(lines)
    if bytes <= activity_limit.max_bytes and line_count <= activity_limit.max_lines then
      break
    end
    if #job.activity_entries <= 1 then
      break
    end
    table.remove(job.activity_entries, 1)
    job.activity_truncated = true
  end
  render_activity(job)
end

local function activity_phase(job, phase)
  add_activity(job, 'Phase: ' .. phase, 'phase:' .. phase)
end

local function create_activity(job)
  local buffer = vim.api.nvim_create_buf(false, true)
  job.activity_buffer = buffer
  job.activity_entries = {}
  job.activity_truncated = false
  vim.api.nvim_buf_set_name(buffer, 'ai-edit-activity://' .. job.agent)
  vim.bo[buffer].buftype = 'nofile'
  vim.bo[buffer].bufhidden = 'hide'
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = 'markdown'
  vim.b[buffer].ai_edit_activity = true
  vim.b[buffer].ai_edit_target = job.buffer
  vim.b[buffer].ai_edit_max_bytes = activity_limit.max_bytes
  vim.b[buffer].ai_edit_max_lines = activity_limit.max_lines
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  add_activity(job, 'Request:\n' .. job.instruction, 'request')
end

local function destroy_activity(job)
  close_activity_window(job)
  if job.activity_buffer and vim.api.nvim_buf_is_valid(job.activity_buffer) then
    pcall(vim.api.nvim_buf_delete, job.activity_buffer, { force = true })
  end
  job.activity_buffer = nil
  job.activity_entries = nil
end

local function sync_statusline()
  redraw_statusline()
  if next(jobs) then
    if status_timer then
      return
    end
    status_frame = 1
    local timer = uv.new_timer()
    if not timer then
      return
    end
    status_timer = timer
    timer:start(options.status.interval_ms, options.status.interval_ms, function()
      vim.schedule(function()
        if status_timer ~= timer or timer:is_closing() then
          return
        end
        status_frame = status_frame % #options.status.frames + 1
        redraw_statusline()
      end)
    end)
    return
  end

  if status_timer then
    status_timer:stop()
    status_timer:close()
    status_timer = nil
  end
  status_frame = 1
end

local function random_id()
  return vim.fn.sha256(vim.fn.tempname() .. tostring(uv.hrtime()) .. tostring(vim.fn.getpid())):sub(1, 24)
end

local function copy_table(value)
  return vim.deepcopy(value)
end

local function buffer_text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n')
end

local function absolute_buffer_path(buffer)
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == '' then
    return nil
  end
  return vim.fn.fnamemodify(name, ':p')
end

local function eligible(buffer, max_bytes)
  if not vim.api.nvim_buf_is_valid(buffer) or not vim.api.nvim_buf_is_loaded(buffer) then
    return nil, 'target buffer is no longer available'
  end
  if vim.bo[buffer].buftype ~= '' then
    return nil, 'current buffer is not a file buffer'
  end
  local path = absolute_buffer_path(buffer)
  if not path then
    return nil, 'current buffer has no file name'
  end
  if vim.bo[buffer].readonly then
    return nil, 'current buffer is readonly'
  end
  if not vim.bo[buffer].modifiable then
    return nil, 'current buffer is not writable'
  end
  if vim.bo[buffer].binary then
    return nil, 'binary buffers are unsupported'
  end
  local text = buffer_text(buffer)
  if #text > max_bytes then
    return nil, string.format('buffer size exceeds %d-byte limit', max_bytes)
  end
  return { path = path, text = text }
end

local function set_owned_modifiable(job, value)
  if not vim.api.nvim_buf_is_valid(job.buffer) then
    return nil, 'target buffer is no longer available'
  end
  local command = value and 'noautocmd setlocal modifiable' or 'noautocmd setlocal nomodifiable'
  local ok, error_message
  if vim.api.nvim_buf_is_loaded(job.buffer) then
    ok, error_message = pcall(vim.api.nvim_buf_call, job.buffer, function()
      vim.cmd(command)
    end)
  else
    ok, error_message = pcall(vim.cmd, string.format('noautocmd call setbufvar(%d, "&modifiable", %d)', job.buffer, value and 1 or 0))
  end
  if not ok then
    return nil, tostring(error_message)
  end
  return true
end

local function validate_target(job, expected_modifiable)
  if not vim.api.nvim_buf_is_valid(job.buffer) or not vim.api.nvim_buf_is_loaded(job.buffer) then
    return nil, 'target buffer is no longer available'
  end
  if vim.bo[job.buffer].buftype ~= '' then
    return nil, 'target buffer is no longer a file buffer'
  end
  if vim.bo[job.buffer].modifiable ~= expected_modifiable then
    return nil, expected_modifiable and 'target buffer could not be unlocked' or 'target buffer lock was released; staged result is stale'
  end
  local path = absolute_buffer_path(job.buffer)
  if path ~= job.path then
    return nil, 'target buffer now refers to another file'
  end
  if buffer_text(job.buffer) ~= job.full_text then
    return nil, 'target buffer text changed while Pi was running'
  end
  if vim.api.nvim_buf_get_changedtick(job.buffer) ~= job.changedtick then
    return nil, 'target buffer changed while Pi was running'
  end
  return true
end

local function acquire_target_lock(job)
  job.original_modifiable = vim.bo[job.buffer].modifiable
  local locked, lock_error = set_owned_modifiable(job, false)
  if not locked then
    return nil, 'could not lock target buffer: ' .. tostring(lock_error)
  end
  job.lock_owned = true
  job.locked = true
  local valid, validation_error = validate_target(job, false)
  if not valid then
    return nil, validation_error
  end
  sync_caret()
  return true
end

local function release_target_lock(job)
  job.locked = false
  if not job.lock_owned then
    sync_caret()
    return true
  end
  if not vim.api.nvim_buf_is_valid(job.buffer) then
    job.lock_owned = false
    sync_caret()
    return true
  end
  local restored, restore_error = set_owned_modifiable(job, job.original_modifiable)
  sync_caret()
  if not restored then
    return nil, 'could not restore target buffer option: ' .. tostring(restore_error)
  end
  job.lock_owned = false
  return true
end

local function project_root(path)
  local directory = vim.fs.dirname(path)
  local current = directory
  while current and current ~= '' do
    if uv.fs_stat(current .. '/.git') then
      return current
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      break
    end
    current = parent
  end
  return directory
end

local function capture_visual(buffer, mode)
  if mode == '\22' then
    return nil, 'blockwise selections are unsupported'
  end
  if mode ~= 'v' and mode ~= 'V' then
    return nil, 'unsupported visual selection'
  end

  local anchor = vim.fn.getpos 'v'
  local cursor = vim.fn.getpos '.'
  local first = { row = anchor[2], col = anchor[3] }
  local last = { row = cursor[2], col = cursor[3] }
  if first.row > last.row or (first.row == last.row and first.col > last.col) then
    first, last = last, first
  end

  if mode == 'V' then
    return {
      kind = 'line',
      start_row = first.row - 1,
      end_row = last.row,
      label = string.format('lines %d-%d', first.row, last.row),
    }
  end

  local region_options = {
    type = 'v',
    exclusive = vim.o.selection == 'exclusive',
  }
  local lines = vim.fn.getregion(anchor, cursor, region_options)
  region_options.eol = true
  local positions = vim.fn.getregionpos(anchor, cursor, region_options)
  if #lines == 0 or #positions == 0 then
    return nil, 'visual selection is empty'
  end

  local start_position = positions[1][1]
  local start_row = start_position[2] - 1
  local start_col = math.max(0, start_position[3] - 1)
  local end_row = start_row + #lines - 1
  local end_col = #lines == 1 and start_col + #lines[1] or #lines[#lines]
  local selected = table.concat(lines, '\n')
  local valid_range, actual_lines = pcall(vim.api.nvim_buf_get_text, buffer, start_row, start_col, end_row, end_col, {})
  if not valid_range or table.concat(actual_lines, '\n') ~= selected then
    return nil, 'visual selection does not map to an exact buffer byte range'
  end

  return {
    kind = 'character',
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    text = selected,
    label = string.format('%d:%d-%d:%d', first.row, first.col, last.row, last.col),
  }
end

local function selection_text(buffer, target)
  if target.text ~= nil then
    return target.text
  end
  if target.kind == 'line' then
    return table.concat(vim.api.nvim_buf_get_lines(buffer, target.start_row, target.end_row, false), '\n')
  end
  return table.concat(vim.api.nvim_buf_get_text(buffer, target.start_row, target.start_col, target.end_row, target.end_col, {}), '\n')
end

local function read_file(path)
  local file, error_message = io.open(path, 'rb')
  if not file then
    return nil, error_message
  end
  local value = file:read '*a'
  file:close()
  return value
end

local function write_file(path, text, mode)
  local descriptor, open_error = uv.fs_open(path, 'w', mode or tonumber('600', 8))
  if not descriptor then
    return nil, open_error
  end

  local offset = 0
  local operation_error
  while offset < #text do
    local written, write_error = uv.fs_write(descriptor, text:sub(offset + 1), -1)
    if not written then
      operation_error = write_error
      break
    end
    if written <= 0 or written > #text - offset then
      operation_error = 'invalid short write result: ' .. tostring(written)
      break
    end
    offset = offset + written
  end
  if not operation_error then
    local synced, sync_error = uv.fs_fsync(descriptor)
    if not synced then
      operation_error = sync_error
    end
  end
  local closed, close_error = uv.fs_close(descriptor)
  if operation_error then
    return nil, operation_error
  end
  if not closed then
    return nil, close_error
  end
  return true
end

local function create_directory_recursive(path)
  local status = uv.fs_lstat(path)
  if status then
    if status.type ~= 'directory' then
      return nil, 'path is not a directory'
    end
    return true
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    local ok, error_message = create_directory_recursive(parent)
    if not ok then
      return nil, error_message
    end
  end
  local created, mkdir_error = uv.fs_mkdir(path, tonumber('700', 8))
  if created then
    return true
  end
  status = uv.fs_lstat(path)
  if not status or status.type ~= 'directory' then
    return nil, mkdir_error
  end
  return true
end

local function private_directory(path)
  local created, mkdir_error = create_directory_recursive(path)
  if not created then
    return nil, mkdir_error
  end
  local ok, error_message = uv.fs_chmod(path, tonumber('700', 8))
  if not ok then
    return nil, error_message
  end
  return true
end

local function cleanup(job)
  if job.cleaned then
    return
  end
  job.cleaned = true
  if job.stage_root then
    vim.fn.delete(job.stage_root, 'rf')
  end
end

-- Each run gets a buffer snapshot and a fixed configuration, with no project discovery.
local function create_staging(job)
  local parent = vim.fn.stdpath 'cache' .. '/nvim-ai-edit/staging'
  local ok, error_message = private_directory(parent)
  if not ok then
    return nil, 'cannot create private staging parent: ' .. tostring(error_message)
  end
  job.stage_root = parent .. '/' .. random_id()
  ok, error_message = private_directory(job.stage_root)
  if not ok then
    return nil, 'cannot create private staging directory: ' .. tostring(error_message)
  end

  local extension = vim.fn.fnamemodify(job.path, ':e'):gsub('[^%w_-]', '')
  job.stage_target = job.stage_root .. '/reference' .. (extension == '' and '' or '.' .. extension)
  ok, error_message = write_file(job.stage_target, job.full_text, tonumber('400', 8))
  if not ok then
    return nil, 'cannot write reference file: ' .. tostring(error_message)
  end

  local agent_dir = job.stage_root .. '/pi'
  ok, error_message = private_directory(agent_dir)
  if not ok then
    return nil, 'cannot create Pi configuration: ' .. tostring(error_message)
  end
  local settings = {
    defaultThinkingLevel = job.options.thinking,
    defaultTools = vim.json.decode '[]',
    compaction = { enabled = false },
    retry = { enabled = false, provider = { maxRetries = 0 } },
    cacheWarming = 'off',
    quietStartup = true,
    enableInstallTelemetry = false,
    enableAnalytics = false,
  }
  local config_dir = vim.fn.fnamemodify(vim.fn.expand(job.options.config_dir), ':p'):gsub('/$', '')
  local configured = read_file(config_dir .. '/settings.json')
  if configured then
    local decoded, value = pcall(vim.json.decode, configured)
    if not decoded or type(value) ~= 'table' then
      return nil, 'invalid Pi settings.json in ' .. config_dir
    end
    for _, key in ipairs { 'defaultProvider', 'defaultModel' } do
      if value[key] ~= nil then
        if type(value[key]) ~= 'string' or value[key] == '' then
          return nil, 'Pi ' .. key .. ' must be non-empty text'
        end
        settings[key] = value[key]
      end
    end
  end
  ok, error_message = write_file(agent_dir .. '/settings.json', vim.json.encode(settings))
  if not ok then
    return nil, 'cannot write Pi settings: ' .. tostring(error_message)
  end
  -- Keep OAuth refreshes in the dedicated local config; no credentials enter the prompt.
  for _, name in ipairs { 'auth.json', 'models.json' } do
    local source = config_dir .. '/' .. name
    if uv.fs_stat(source) then
      ok, error_message = uv.fs_symlink(source, agent_dir .. '/' .. name)
      if not ok then
        return nil, 'cannot link Pi ' .. name .. ': ' .. tostring(error_message)
      end
    end
  end

  job.environment = vim.fn.environ()
  job.environment.PI_CODING_AGENT_DIR = agent_dir
  job.environment.PI_CODING_AGENT_SESSION_DIR = nil
  job.environment.PI_OFFLINE = '1'
  job.environment.PI_SKIP_VERSION_CHECK = '1'
  job.environment.PI_TELEMETRY = '0'
  job.environment.NVIM = ''
  job.environment.NVIM_LISTEN_ADDRESS = nil
  return true
end

local function show_error(message)
  local lines = vim.split(message ~= '' and message or 'Unknown Pi failure', '\n', { plain = true })
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = 'nofile'
  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].swapfile = false
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local width = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.7)))
  local height = math.max(3, math.min(vim.o.lines - 4, #lines + 2))
  vim.api.nvim_open_win(buffer, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' AI edit error ',
    title_pos = 'center',
  })
end

local function job_process(channel, detached)
  local process_id = vim.fn.jobpid(channel)
  return {
    kill = function(_, signal)
      return uv.kill(detached and -process_id or process_id, signal)
    end,
  }
end

local function parse_event(job, event)
  if type(event) ~= 'table' then
    job.parse_error = true
    table.insert(job.errors, 'invalid Pi event')
    return
  end
  local update = event.assistantMessageEvent
  if event.type == 'message_update' and type(update) == 'table' and update.type == 'text_delta' and type(update.delta) == 'string' then
    -- Only the bounded tail is needed for the activity view; message_end owns the result.
    job.preview = utf8_tail(job.preview .. update.delta, activity_limit.entry_bytes)
    add_activity(job, 'Assistant:\n' .. job.preview, 'response')
  elseif event.type == 'message_end' and type(event.message) == 'table' and event.message.role == 'assistant' then
    local message = event.message
    job.response_count = job.response_count + 1
    if message.stopReason ~= 'stop' then
      job.event_error = true
      table.insert(job.errors, message.errorMessage or ('Pi response ended with ' .. tostring(message.stopReason)))
      return
    end
    local parts = {}
    for _, part in ipairs(message.content or {}) do
      if part.type == 'text' and type(part.text) == 'string' then
        table.insert(parts, part.text)
      elseif part.type ~= 'thinking' then
        job.event_error = true
        table.insert(job.errors, 'Pi returned non-text output')
        return
      end
    end
    job.result = table.concat(parts)
  elseif event.type == 'tool_execution_start' or event.type == 'error' then
    job.event_error = true
    table.insert(job.errors, 'unexpected Pi event: ' .. event.type)
  end
end

local function consume_stdout(job, data, final)
  if data then
    job.stdout_buffer = job.stdout_buffer .. data
    if #job.stdout_buffer > job.options.max_bytes * 12 + 65536 then
      job.parse_error = true
      table.insert(job.errors, 'Pi event exceeds configured size limit')
      job.stdout_buffer = ''
      return
    end
  end
  while true do
    local newline = job.stdout_buffer:find('\n', 1, true)
    if not newline then
      break
    end
    local line = job.stdout_buffer:sub(1, newline - 1)
    job.stdout_buffer = job.stdout_buffer:sub(newline + 1)
    if line:match '%S' then
      local ok, event = pcall(vim.json.decode, line)
      if ok then
        parse_event(job, event)
      else
        job.parse_error = true
        table.insert(job.errors, 'invalid JSON event: ' .. line)
      end
    end
  end
  if final and job.stdout_buffer:match '%S' then
    local line = job.stdout_buffer
    job.stdout_buffer = ''
    local ok, event = pcall(vim.json.decode, line)
    if ok then
      parse_event(job, event)
    else
      job.parse_error = true
      table.insert(job.errors, 'invalid JSON event: ' .. line)
    end
  end
end

local function response_text(job)
  if job.response_count ~= 1 or type(job.result) ~= 'string' then
    return nil, 'expected exactly one completed Pi response'
  end
  if #job.result > job.options.max_bytes then
    return nil, 'Pi response exceeds configured size limit'
  end
  if job.result:find '%z' or not pcall(vim.str_utfindex, job.result) then
    return nil, 'Pi response contains invalid buffer text'
  end
  return job.result
end

local function split_result(text, strip_final_newline)
  if strip_final_newline and text:sub(-1) == '\n' then
    text = text:sub(1, -2)
  end
  if text == '' then
    return {}
  end
  return vim.split(text, '\n', { plain = true })
end

local function apply_result(job, text)
  local valid, validation_error = validate_target(job, false)
  if not valid then
    return nil, validation_error, 'stale'
  end
  if text == job.target_text then
    return 'noop'
  end

  local unlocked, unlock_error = release_target_lock(job)
  if not unlocked then
    return nil, unlock_error, 'error'
  end
  valid, validation_error = validate_target(job, true)
  if not valid then
    return nil, validation_error, 'stale'
  end

  local applied, application_error = pcall(function()
    if job.target.kind == 'whole' then
      vim.api.nvim_buf_set_lines(job.buffer, 0, -1, false, split_result(text, true))
      vim.bo[job.buffer].endofline = job.endofline
    elseif job.target.kind == 'line' then
      vim.api.nvim_buf_set_lines(job.buffer, job.target.start_row, job.target.end_row, false, split_result(text, false))
    else
      vim.api.nvim_buf_set_text(job.buffer, job.target.start_row, job.target.start_col, job.target.end_row, job.target.end_col, split_result(text, false))
    end
  end)
  if not applied then
    return nil, 'could not apply staged result: ' .. tostring(application_error), 'error'
  end
  return 'applied'
end

local function finish(job, outcome, result)
  if job.done then
    return
  end
  job.done = true
  if job.timer then
    job.timer:stop()
    if not job.timer:is_closing() then
      job.timer:close()
    end
  end
  destroy_activity(job)
  local restored, restoration_error = release_target_lock(job)
  if not restored then
    restored, restoration_error = release_target_lock(job)
  end
  if not restored then
    result = table.concat({ result or '', restoration_error }, '\n'):gsub('^\n', '')
    outcome = 'error'
  end
  if jobs[job.buffer] == job then
    jobs[job.buffer] = nil
  end
  sync_caret()
  sync_statusline()

  if outcome == 'cancelled' then
    notify('cancelled', vim.log.levels.WARN)
  elseif outcome == 'timeout' then
    notify('timed out', vim.log.levels.ERROR)
  elseif outcome == 'error' then
    local details = result or table.concat(job.errors, '\n')
    local summary = details:match '([^\n]+)' or 'Pi failed'
    notify('Pi failed: ' .. summary, vim.log.levels.ERROR)
    show_error(details)
  elseif outcome == 'stale' then
    notify(result or 'target changed; staged result discarded', vim.log.levels.WARN)
  elseif outcome == 'noop' then
    notify 'no changes produced'
  elseif outcome == 'applied' then
    notify 'buffer changed; use u to revert'
  end
  cleanup(job)
end

local function stop_job(job, outcome)
  if job.done then
    return
  end
  if job.process then
    local process = job.process
    pcall(process.kill, process, 15)
    local kill_timer = uv.new_timer()
    kill_timer:start(500, 0, function()
      pcall(process.kill, process, 9)
      kill_timer:stop()
      kill_timer:close()
    end)
  end
  finish(job, outcome)
end

local function launch_run(job)
  activity_phase(job, 'Running model')
  local stdout_done = false
  local stderr_done = false
  local exit_code
  local completed = false

  local function complete()
    if completed or job.done or exit_code == nil or not stdout_done or not stderr_done then
      return
    end
    completed = true
    consume_stdout(job, nil, true)
    if exit_code ~= 0 then
      table.insert(job.errors, string.format('Pi exited with status %d', exit_code))
    end
    local stderr = table.concat(job.stderr)
    if stderr:match '%S' then
      table.insert(job.errors, stderr)
    end
    if exit_code ~= 0 or job.event_error or job.parse_error then
      finish(job, 'error', table.concat(job.errors, '\n'))
      return
    end
    local text, stage_error = response_text(job)
    if not text then
      finish(job, 'error', stage_error)
      return
    end
    local application, application_error, application_outcome = apply_result(job, text)
    if not application then
      finish(job, application_outcome or 'stale', application_error)
      return
    end
    finish(job, application)
  end

  local stdout_callback = function(_, data)
    vim.schedule(function()
      if #data == 1 and data[1] == '' then
        stdout_done = true
      else
        consume_stdout(job, table.concat(data, '\n'), false)
      end
      complete()
    end)
  end
  local stderr_callback = function(_, data)
    vim.schedule(function()
      if #data == 1 and data[1] == '' then
        stderr_done = true
      else
        table.insert(job.stderr, table.concat(data, '\n'))
      end
      complete()
    end)
  end

  local prompt_path = vim.api.nvim_get_runtime_file('lua/ai_edit/prompt.md', false)[1]
  if not prompt_path then
    finish(job, 'error', 'code-only prompt is missing')
    return
  end
  local arguments = {
    job.options.command,
    '--print',
    '--mode',
    'json',
    '--no-session',
    '--no-tools',
    '--no-extensions',
    '--no-skills',
    '--no-prompt-templates',
    '--no-themes',
    '--no-context-files',
    '--no-approve',
    '--offline',
    '--thinking',
    job.options.thinking,
    '--system-prompt',
    prompt_path,
  }
  if job.options.model then
    vim.list_extend(arguments, { '--model', job.options.model })
  end
  vim.list_extend(arguments, { '--', '@' .. job.stage_target })
  local request = 'Replace the entire reference file. Output its complete replacement code.'
  if job.target.kind ~= 'whole' then
    request = 'The reference file is read-only context. Replace only the selection at '
      .. job.target.label
      .. '. Output only the replacement code for this selection.'
      .. '\nSelected text, JSON encoded:\n'
      .. vim.json.encode(job.target_text)
  end
  request = request .. '\nRequest:\n' .. job.instruction

  local ok, channel = pcall(vim.fn.jobstart, arguments, {
    cwd = job.stage_root,
    env = job.environment,
    clear_env = true,
    on_stdout = stdout_callback,
    on_stderr = stderr_callback,
    on_exit = function(_, code)
      vim.schedule(function()
        exit_code = code
        complete()
      end)
    end,
  })
  if not ok or channel <= 0 then
    finish(job, 'error', 'could not start Pi: ' .. tostring(channel))
    return
  end
  job.process = job_process(channel, false)
  local sent, send_result = pcall(vim.fn.chansend, channel, request)
  local closed, close_result = pcall(vim.fn.chanclose, channel, 'stdin')
  if not sent or send_result == 0 or not closed or close_result == 0 then
    pcall(job.process.kill, job.process, 9)
    finish(job, 'error', 'could not send Pi instruction')
  end
end

local function start_job(snapshot, instruction)
  local buffer = snapshot.buffer
  if jobs[buffer] then
    notify('an edit is already running for this buffer', vim.log.levels.WARN)
    return
  end
  local current, validation_error = eligible(buffer, options.max_bytes)
  if not current then
    notify(validation_error, vim.log.levels.WARN)
    return
  end
  if current.path ~= snapshot.path then
    notify('target buffer now refers to another file', vim.log.levels.WARN)
    return
  end
  if vim.api.nvim_buf_get_changedtick(buffer) ~= snapshot.changedtick or current.text ~= snapshot.text then
    notify('target buffer changed while prompt was open', vim.log.levels.WARN)
    return
  end

  local job = {
    buffer = buffer,
    target_window = snapshot.window,
    path = snapshot.path,
    full_text = snapshot.text,
    target_text = snapshot.target_text,
    target = snapshot.target,
    changedtick = snapshot.changedtick,
    endofline = snapshot.endofline,
    instruction = instruction,
    options = copy_table(options),
    agent = 'nvim-ai-edit-' .. random_id(),
    errors = {},
    stderr = {},
    stdout_buffer = '',
    response_count = 0,
    preview = '',
  }
  jobs[buffer] = job
  local locked, lock_error = acquire_target_lock(job)
  if not locked then
    finish(job, 'error', lock_error)
    return
  end
  table.insert(instruction_history, instruction)
  if #instruction_history > history_limit then
    table.remove(instruction_history, 1)
  end
  create_activity(job)
  activity_phase(job, 'Preparing staging')
  sync_statusline()

  local staged, staging_error = create_staging(job)
  if not staged then
    finish(job, 'error', staging_error)
    return
  end
  job.timer = uv.new_timer()
  job.timer:start(job.options.timeout_ms, 0, function()
    vim.schedule(function()
      stop_job(job, 'timeout')
    end)
  end)
  notify 'running'
  launch_run(job)
end

local function close_window(window)
  if type(window) == 'number' and vim.api.nvim_win_is_valid(window) then
    pcall(vim.api.nvim_win_close, window, true)
  end
end

local function source_screen_position(window)
  if vim.api.nvim_get_current_win() ~= window then
    return nil
  end
  local row_ok, row = pcall(vim.fn.screenrow)
  local col_ok, col = pcall(vim.fn.screencol)
  row = tonumber(row)
  col = tonumber(col)
  local usable_rows = vim.o.lines - vim.o.cmdheight
  if not row_ok or not col_ok or not row or not col or row < 1 or col < 1 or row > usable_rows or col > vim.o.columns then
    return nil
  end
  return { row = row - 1, col = col - 1 }
end

local function prompt_geometry(source)
  local columns = vim.o.columns
  local rows = vim.o.lines - vim.o.cmdheight
  if columns < 5 or rows < 1 or source.row < 0 or source.row >= rows or source.col < 0 or source.col >= columns then
    return nil
  end

  local width = math.min(math.max(20, math.floor(columns * options.width)), columns - 2)
  if width < 3 then
    return nil
  end
  local desired_height = math.max(3, math.floor(rows * options.height))
  local capacity = {
    above = source.row - 3,
    below = rows - source.row - 4,
  }
  local preferred = source.row < vim.o.lines / 2 and 'below' or 'above'
  local opposite = preferred == 'below' and 'above' or 'below'
  local side
  local height
  if capacity[preferred] >= desired_height then
    side = preferred
    height = desired_height
  elseif capacity[opposite] >= desired_height then
    side = opposite
    height = desired_height
  else
    side = capacity[preferred] >= capacity[opposite] and preferred or opposite
    height = math.min(desired_height, capacity[side])
  end
  if height < 3 then
    return nil
  end

  local total_width = width + 2
  local col = source.col - math.floor(total_width / 2)
  col = math.max(0, math.min(columns - total_width, col))
  local row = side == 'below' and source.row + 2 or source.row - height - 3
  return { row = row, col = col, width = width, height = height }
end

local function open_prompt(snapshot)
  local buffer = snapshot.buffer
  local target = snapshot.target
  local root = project_root(snapshot.path)
  local relative_path = vim.fs.relpath(root, snapshot.path) or vim.fn.fnamemodify(snapshot.path, ':t')
  local title = ' AI edit: ' .. relative_path
  if target.label then
    title = title .. ' [' .. target.label .. ']'
  end
  title = title .. ' '

  local geometry = prompt_geometry(snapshot.source)
  if not geometry then
    return nil, 'prompt cannot fit without covering the cursor'
  end

  local frame_buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[frame_buffer].buftype = 'nofile'
  vim.bo[frame_buffer].bufhidden = 'wipe'
  vim.bo[frame_buffer].swapfile = false
  vim.bo[frame_buffer].modifiable = false
  vim.b[frame_buffer].ai_edit_prompt_frame = true
  local prompt = vim.api.nvim_create_buf(false, true)
  vim.bo[prompt].buftype = 'nofile'
  vim.bo[prompt].bufhidden = 'wipe'
  vim.bo[prompt].swapfile = false
  vim.bo[prompt].filetype = 'markdown'
  vim.b[prompt].ai_edit_prompt = true

  local frame
  local window
  local closed = false
  local function cleanup_prompt()
    if closed then
      return
    end
    closed = true
    close_window(window)
    close_window(frame)
    for _, owned_buffer in ipairs { prompt, frame_buffer } do
      if vim.api.nvim_buf_is_valid(owned_buffer) then
        pcall(vim.api.nvim_buf_delete, owned_buffer, { force = true })
      end
    end
  end

  local function watch_window(owned_window)
    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(owned_window),
      once = true,
      callback = function()
        if not closed then
          vim.schedule(cleanup_prompt)
        end
      end,
    })
  end

  local frame_ok
  frame_ok, frame = pcall(vim.api.nvim_open_win, frame_buffer, false, {
    relative = 'editor',
    row = geometry.row,
    col = geometry.col,
    width = geometry.width,
    height = geometry.height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
    focusable = false,
    mouse = false,
    zindex = 50,
  })
  if not frame_ok then
    cleanup_prompt()
    return nil, 'could not open prompt frame: ' .. tostring(frame)
  end
  watch_window(frame)
  local input_ok
  input_ok, window = pcall(vim.api.nvim_open_win, prompt, true, {
    relative = 'editor',
    row = geometry.row + 2,
    col = geometry.col + 2,
    width = geometry.width - 2,
    height = geometry.height - 2,
    style = 'minimal',
    border = 'none',
    zindex = 51,
  })
  if not input_ok then
    cleanup_prompt()
    return nil, 'could not open prompt input: ' .. tostring(window)
  end
  watch_window(window)
  if not vim.api.nvim_win_is_valid(frame) or not vim.api.nvim_win_is_valid(window) then
    cleanup_prompt()
    return nil, 'prompt closed while opening'
  end

  local function prompt_text()
    if not vim.api.nvim_buf_is_valid(prompt) then
      return ''
    end
    return table.concat(vim.api.nvim_buf_get_lines(prompt, 0, -1, false), '\n')
  end

  local navigation = { snapshot = nil, index = nil, draft = nil }
  local function replace_prompt(text)
    if not vim.api.nvim_buf_is_valid(prompt) or not vim.api.nvim_win_is_valid(window) then
      return
    end
    local lines = vim.split(text, '\n', { plain = true })
    if #lines == 0 then
      lines = { '' }
    end
    vim.api.nvim_buf_set_lines(prompt, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(window, { #lines, #lines[#lines] })
  end

  local function older_history()
    if not navigation.snapshot then
      if #instruction_history == 0 then
        return false
      end
      navigation.snapshot = copy_table(instruction_history)
      navigation.index = #navigation.snapshot
      navigation.draft = prompt_text()
    elseif navigation.index > 1 then
      navigation.index = navigation.index - 1
    end
    replace_prompt(navigation.snapshot[navigation.index])
    return true
  end

  local function newer_history()
    if not navigation.snapshot then
      return false
    end
    if navigation.index < #navigation.snapshot then
      navigation.index = navigation.index + 1
      replace_prompt(navigation.snapshot[navigation.index])
      return true
    end
    local draft = navigation.draft
    navigation.snapshot = nil
    navigation.index = nil
    navigation.draft = nil
    replace_prompt(draft)
    return true
  end

  local function native_arrow(key)
    vim.api.nvim_feedkeys(vim.keycode(key), 'n', false)
  end

  local function submit()
    if not vim.api.nvim_buf_is_valid(prompt) then
      return
    end
    local instruction = table.concat(vim.api.nvim_buf_get_lines(prompt, 0, -1, false), '\n')
    if not instruction:match '%S' then
      notify('instruction is required', vim.log.levels.WARN)
      return
    end
    vim.cmd 'stopinsert'
    cleanup_prompt()
    start_job(snapshot, instruction)
  end

  local function newline(advance_codepoint)
    if not vim.api.nvim_win_is_valid(window) then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(window)
    local line = vim.api.nvim_buf_get_lines(prompt, cursor[1] - 1, cursor[1], false)[1]
    local column = math.min(#line, cursor[2])
    if advance_codepoint and column < #line then
      column = vim.str_byteindex(line, vim.str_utfindex(line, column) + 1)
    end
    vim.api.nvim_buf_set_text(prompt, cursor[1] - 1, column, cursor[1] - 1, column, { '', '' })
    vim.api.nvim_win_set_cursor(window, { cursor[1] + 1, 0 })
  end

  local map_options = { buffer = prompt, silent = true, nowait = true }
  vim.keymap.set({ 'n', 'i' }, '<CR>', submit, map_options)
  vim.keymap.set('n', '<C-j>', function()
    newline(true)
  end, map_options)
  vim.keymap.set('i', '<C-j>', function()
    newline(false)
  end, map_options)
  vim.keymap.set({ 'n', 'i' }, '<C-p>', older_history, map_options)
  vim.keymap.set({ 'n', 'i' }, '<C-n>', newer_history, map_options)
  vim.keymap.set({ 'n', 'i' }, '<Up>', function()
    local cursor = vim.api.nvim_win_get_cursor(window)
    if cursor[1] ~= 1 or not older_history() then
      native_arrow '<Up>'
    end
  end, map_options)
  vim.keymap.set({ 'n', 'i' }, '<Down>', function()
    local cursor = vim.api.nvim_win_get_cursor(window)
    if cursor[1] ~= vim.api.nvim_buf_line_count(prompt) or not newer_history() then
      native_arrow '<Down>'
    end
  end, map_options)
  vim.keymap.set({ 'n', 'i' }, '<Esc>', function()
    cleanup_prompt()
  end, map_options)
  vim.cmd 'startinsert'
  return true
end

local function invoke(mode)
  local buffer = vim.api.nvim_get_current_buf()
  if jobs[buffer] then
    notify('an edit is already running for this buffer', vim.log.levels.WARN)
    return
  end
  local snapshot, validation_error = eligible(buffer, options.max_bytes)
  if not snapshot then
    notify(validation_error, vim.log.levels.WARN)
    return
  end
  if vim.fn.executable(options.command) ~= 1 then
    notify('Pi executable not found: ' .. options.command, vim.log.levels.ERROR)
    return
  end
  local target = { kind = 'whole', label = nil }
  if mode == 'visual' then
    local visual_mode = vim.fn.mode(1):sub(1, 1)
    target, validation_error = capture_visual(buffer, visual_mode)
    if not target then
      notify(validation_error, vim.log.levels.WARN)
      return
    end
  end
  local target_text = target.kind == 'whole' and snapshot.text or selection_text(buffer, target)
  if #target_text > options.max_bytes then
    notify('selection size exceeds configured limit', vim.log.levels.WARN)
    return
  end
  snapshot.buffer = buffer
  snapshot.window = vim.api.nvim_get_current_win()
  snapshot.source = source_screen_position(snapshot.window)
  if not snapshot.source then
    notify('cursor-relative prompt placement is unavailable', vim.log.levels.WARN)
    return
  end
  snapshot.target = target
  snapshot.target_text = target_text
  snapshot.changedtick = vim.api.nvim_buf_get_changedtick(buffer)
  snapshot.endofline = vim.bo[buffer].endofline
  local opened, prompt_error = open_prompt(snapshot)
  if not opened then
    notify(prompt_error, vim.log.levels.WARN)
  end
end

local function validate_options(overrides)
  local allowed = {
    keymap = true,
    command = true,
    model = true,
    thinking = true,
    config_dir = true,
    timeout_ms = true,
    max_bytes = true,
    width = true,
    height = true,
    status = true,
  }
  for key in pairs(overrides) do
    if not allowed[key] then
      error('ai_edit: unknown option ' .. key)
    end
  end
  if type(overrides.keymap) ~= 'string' or overrides.keymap == '' then
    error 'ai_edit: keymap must be non-empty text'
  end
  if type(overrides.command) ~= 'string' or overrides.command == '' then
    error 'ai_edit: command must be non-empty text'
  end
  if overrides.model ~= false and (type(overrides.model) ~= 'string' or not overrides.model:match '^[^/]+/.+$') then
    error 'ai_edit: model must be false or provider/model text'
  end
  if type(overrides.config_dir) ~= 'string' or overrides.config_dir == '' then
    error 'ai_edit: config_dir must be a non-empty directory path'
  end
  local levels = { off = true, minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }
  if type(overrides.thinking) ~= 'string' or not levels[overrides.thinking] then
    error 'ai_edit: thinking must be off, minimal, low, medium, high, xhigh, or max'
  end
  for _, key in ipairs { 'timeout_ms', 'max_bytes' } do
    if type(overrides[key]) ~= 'number' or overrides[key] <= 0 or overrides[key] % 1 ~= 0 then
      error('ai_edit: ' .. key .. ' must be a positive integer')
    end
  end
  for _, key in ipairs { 'width', 'height' } do
    if type(overrides[key]) ~= 'number' or overrides[key] ~= overrides[key] or overrides[key] <= 0 or overrides[key] > 1 then
      error('ai_edit: ' .. key .. ' must be greater than 0 and at most 1')
    end
  end
  if type(overrides.status) ~= 'table' then
    error 'ai_edit: status must be a table'
  end
  local status_allowed = { text = true, color = true, interval_ms = true, frames = true }
  for key in pairs(overrides.status) do
    if not status_allowed[key] then
      error('ai_edit: unknown status option ' .. key)
    end
  end
  if type(overrides.status.text) ~= 'string' or overrides.status.text == '' then
    error 'ai_edit: status.text must be non-empty text'
  end
  if type(overrides.status.color) ~= 'string' or not overrides.status.color:match '^#%x%x%x%x%x%x$' then
    error 'ai_edit: status.color must be a six-digit hex color'
  end
  if type(overrides.status.interval_ms) ~= 'number' or overrides.status.interval_ms <= 0 or overrides.status.interval_ms % 1 ~= 0 then
    error 'ai_edit: status.interval_ms must be a positive integer'
  end
  if not vim.islist(overrides.status.frames) or #overrides.status.frames == 0 then
    error 'ai_edit: status.frames must be a non-empty list'
  end
  for _, frame in ipairs(overrides.status.frames) do
    if type(frame) ~= 'string' or frame == '' then
      error 'ai_edit: every status frame must be non-empty text'
    end
  end
end

function M.statusline()
  if not next(jobs) then
    return ''
  end
  return statusline_literal(options.status.frames[status_frame]) .. ' ' .. statusline_literal(options.status.text)
end

function M.statusline_color()
  return { fg = options.status.color, gui = 'bold' }
end

function M.cancel(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local job = jobs[buffer]
  if not job then
    notify('no active edit for this buffer', vim.log.levels.WARN)
    return
  end
  stop_job(job, 'cancelled')
end

local function setup_running_view()
  vim.api.nvim_set_hl(0, 'AIEditHiddenCursor', { fg = '#000000', bg = '#000000', blend = 100 })
  cursor_state.base = strip_hidden_cursor(vim.o.guicursor)
  set_guicursor(cursor_state.base)

  local group = vim.api.nvim_create_augroup('ai_edit_running_view', { clear = true })
  vim.api.nvim_create_autocmd('OptionSet', {
    group = group,
    pattern = 'guicursor',
    callback = function()
      if cursor_state.writing then
        return
      end
      cursor_state.base = strip_hidden_cursor(vim.o.guicursor)
      sync_caret()
      schedule_caret_sync()
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = group,
    callback = function()
      sync_caret()
      vim.schedule(sync_activity_views)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufWinLeave', 'TabEnter', 'VimResized', 'WinClosed', 'WinResized' }, {
    group = group,
    callback = function()
      vim.schedule(sync_activity_views)
    end,
  })
  sync_caret()
end

function M.setup(overrides)
  if overrides ~= nil and type(overrides) ~= 'table' then
    error 'ai_edit: setup options must be a table'
  end
  local configured = copy_table(options)
  for key, value in pairs(overrides or {}) do
    if key == 'status' and type(value) == 'table' then
      configured.status = vim.tbl_extend('force', configured.status, copy_table(value))
    else
      configured[key] = value
    end
  end
  validate_options(configured)
  if mapped_keymap and mapped_keymap ~= configured.keymap then
    for _, mapping in ipairs {
      { mode = 'n', desc = 'AI edit buffer' },
      { mode = 'x', desc = 'AI edit selection' },
    } do
      local current = vim.fn.maparg(mapped_keymap, mapping.mode, false, true)
      if current.desc == mapping.desc then
        pcall(vim.keymap.del, mapping.mode, mapped_keymap)
      end
    end
  end
  options = configured
  status_frame = 1
  health_state.command = options.command
  health_state.config_dir = options.config_dir
  setup_running_view()

  vim.keymap.set('n', options.keymap, function()
    invoke 'normal'
  end, { desc = 'AI edit buffer' })
  vim.keymap.set('x', options.keymap, function()
    invoke 'visual'
  end, { desc = 'AI edit selection' })
  mapped_keymap = options.keymap
  vim.api.nvim_create_user_command('AIEditCancel', function()
    M.cancel()
  end, { desc = 'Cancel AI edit for current buffer', force = true })
end

return M
