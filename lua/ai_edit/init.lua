local M = {}

local uv = vim.uv or vim.loop
local health_state = require 'ai_edit.health_state'
local version_policy = require 'ai_edit.version'
local helper_cache_version = '5'
local output_limit = { max_bytes = 32768, max_lines = 10 }
local activity_limit = { max_bytes = 8192, max_lines = 120, entry_bytes = 2048, entry_lines = 24 }
local debug_output_max_bytes = 1024 * 1024
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
  command = 'opencode',
  model = false,
  variant = false,
  timeout_ms = 5 * 60 * 1000,
  cleanup_timeout_ms = 2000,
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

local safe_tools = {
  invalid = false,
  read = true,
  glob = true,
  grep = true,
  stage_text = true,
  apply_patch = false,
  edit = false,
  write = false,
  bash = false,
  webfetch = false,
  websearch = false,
  codesearch = false,
  task = false,
  todowrite = false,
  question = false,
  skill = false,
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
  for session_id in pairs(job.sessions or {}) do
    text = text:gsub(vim.pesc(session_id), '[session]')
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
    return nil, 'target buffer text changed while OpenCode was running'
  end
  if vim.api.nvim_buf_get_changedtick(job.buffer) ~= job.changedtick then
    return nil, 'target buffer changed while OpenCode was running'
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
  if job.helper_build then
    vim.fn.delete(job.helper_build, 'rf')
  end
end

local function create_staging(job)
  local parent = vim.fn.stdpath 'cache' .. '/nvim-ai-edit/staging'
  local ok, error_message = private_directory(parent)
  if not ok then
    return nil, 'cannot create private staging parent: ' .. tostring(error_message)
  end
  local root = parent .. '/' .. random_id()
  ok, error_message = private_directory(root)
  if not ok then
    return nil, 'cannot create private staging directory: ' .. tostring(error_message)
  end
  job.stage_root = root

  local extension = vim.fn.fnamemodify(job.path, ':e')
  local suffix = extension == '' and '' or '.' .. extension
  job.stage_target = root .. '/target' .. suffix
  ok, error_message = write_file(job.stage_target, job.target_text)
  if not ok then
    return nil, 'cannot write staging target: ' .. tostring(error_message)
  end

  if job.target.kind ~= 'whole' then
    job.stage_context = root .. '/context' .. suffix
    ok, error_message = write_file(job.stage_context, job.full_text, tonumber('400', 8))
    if not ok then
      return nil, 'cannot write read-only context: ' .. tostring(error_message)
    end
    uv.fs_chmod(job.stage_context, tonumber('400', 8))
  end
  return true
end

local function helper_source(command, opencode_version)
  local source_paths = vim.api.nvim_get_runtime_file('lua/ai_edit/stage_text.ts', false)
  local source_path = source_paths[1]
  if not source_path then
    return nil, 'trusted stage_text helper source is missing'
  end
  local source, read_error = read_file(source_path)
  if not source then
    return nil, 'cannot read trusted stage_text helper: ' .. tostring(read_error)
  end
  local parent = vim.fn.stdpath 'cache' .. '/nvim-ai-edit'
  local resolved_command = vim.fn.exepath(command)
  if resolved_command == '' then
    resolved_command = command
  end
  local root = parent
    .. '/helper-'
    .. helper_cache_version
    .. '-'
    .. opencode_version
    .. '-'
    .. vim.fn.sha256(source):sub(1, 16)
    .. '-'
    .. vim.fn.sha256(resolved_command):sub(1, 12)
  return { source = source, version = opencode_version, parent = parent, root = root, cache = root .. '/opencode' }
end

local function verify_helper_cache(cache, source, opencode_version)
  local status = uv.fs_lstat(cache)
  if not status or status.type ~= 'directory' then
    return nil, 'published helper cache is missing'
  end
  for _, path in ipairs {
    cache .. '/tool/stage_text.ts',
    cache .. '/package.json',
    cache .. '/node_modules/@opencode-ai/plugin/package.json',
    cache .. '/node_modules/@opencode-ai/plugin/dist/index.js',
  } do
    local file_status = uv.fs_lstat(path)
    if not file_status or file_status.type ~= 'file' then
      return nil, 'published helper cache contains a missing or redirected required file'
    end
  end
  local installed_source, source_error = read_file(cache .. '/tool/stage_text.ts')
  if installed_source ~= source then
    return nil, 'published helper source differs from trusted source: ' .. tostring(source_error or '')
  end
  local manifest_text, manifest_error = read_file(cache .. '/package.json')
  if not manifest_text then
    return nil, 'published helper manifest is unreadable: ' .. tostring(manifest_error)
  end
  local manifest_ok, manifest = pcall(vim.json.decode, manifest_text)
  if
    not manifest_ok
    or type(manifest) ~= 'table'
    or type(manifest.dependencies) ~= 'table'
    or manifest.dependencies['@opencode-ai/plugin'] ~= opencode_version
  then
    return nil, 'published helper manifest has wrong dependency version'
  end
  local package_text, package_error = read_file(cache .. '/node_modules/@opencode-ai/plugin/package.json')
  if not package_text then
    return nil, 'published helper dependency is unreadable: ' .. tostring(package_error)
  end
  local package_ok, package = pcall(vim.json.decode, package_text)
  if not package_ok or type(package) ~= 'table' or package.version ~= opencode_version then
    return nil, 'published helper dependency has wrong version'
  end
  return true
end

local function seal_helper_cache(path)
  local status = uv.fs_lstat(path)
  if not status then
    return nil, 'cannot inspect helper cache entry'
  end
  if status.type == 'link' then
    return true
  end
  if status.type == 'directory' then
    local scanner, scan_error = uv.fs_scandir(path)
    if not scanner then
      return nil, scan_error
    end
    while true do
      local name = uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      local ok, error_message = seal_helper_cache(path .. '/' .. name)
      if not ok then
        return nil, error_message
      end
    end
    return uv.fs_chmod(path, tonumber('500', 8))
  end
  return uv.fs_chmod(path, tonumber('400', 8))
end

local function discard_helper_build(path)
  local status = uv.fs_lstat(path)
  if not status then
    return
  end
  if status.type == 'directory' then
    uv.fs_chmod(path, tonumber('700', 8))
    local scanner = uv.fs_scandir(path)
    if scanner then
      while true do
        local name = uv.fs_scandir_next(scanner)
        if not name then
          break
        end
        discard_helper_build(path .. '/' .. name)
      end
    end
  elseif status.type ~= 'link' then
    uv.fs_chmod(path, tonumber('600', 8))
  end
  if status.type == 'directory' then
    vim.fn.delete(path, 'rf')
  else
    vim.fn.delete(path)
  end
end

local function materialize_helper_build(info)
  local ok, error_message = private_directory(info.parent)
  if not ok then
    return nil, 'cannot create trusted helper parent: ' .. tostring(error_message)
  end
  local root = info.parent .. '/.helper-build-' .. random_id()
  local cache = root .. '/opencode'
  local tool_directory = cache .. '/tool'
  ok, error_message = private_directory(tool_directory)
  if not ok then
    return nil, 'cannot create trusted helper build: ' .. tostring(error_message)
  end
  ok, error_message = write_file(tool_directory .. '/stage_text.ts', info.source)
  if not ok then
    vim.fn.delete(root, 'rf')
    return nil, 'cannot materialize trusted helper: ' .. tostring(error_message)
  end
  local manifest = vim.json.encode { dependencies = { ['@opencode-ai/plugin'] = info.version } }
  ok, error_message = write_file(cache .. '/package.json', manifest)
  if not ok then
    vim.fn.delete(root, 'rf')
    return nil, 'cannot materialize helper dependency manifest: ' .. tostring(error_message)
  end
  return { root = root, cache = cache }
end

local function isolated_environment(job, cache, config, suffix)
  local environment = vim.fn.environ()
  local isolation = job.stage_root .. '/' .. suffix
  private_directory(isolation .. '/home')
  if cache then
    environment.XDG_CONFIG_HOME = vim.fs.dirname(cache)
  else
    private_directory(isolation .. '/config')
    environment.XDG_CONFIG_HOME = isolation .. '/config'
  end
  environment.OPENCODE_TEST_HOME = isolation .. '/home'
  environment.OPENCODE_CONFIG = nil
  environment.OPENCODE_CONFIG_DIR = cache
  environment.OPENCODE_CONFIG_CONTENT = vim.json.encode(config)
  environment.OPENCODE_PURE = '1'
  environment.OPENCODE_DISABLE_DEFAULT_PLUGINS = nil
  environment.OPENCODE_DISABLE_PROJECT_CONFIG = '1'
  environment.OPENCODE_DISABLE_AUTOSHARE = '1'
  environment.NVIM_AI_EDIT_STAGE_ROOT = job.stage_root
  environment.NVIM_AI_EDIT_STAGE_TARGET = job.stage_target
  environment.NVIM_AI_EDIT_MAX_BYTES = tostring(job.options.max_bytes)
  environment.NVIM_AI_EDIT_CONTEXT = job.stage_context
  return environment
end

local function runtime_environment(job)
  return isolated_environment(job, job.cache, job.config, 'runtime')
end

local function global_config_environment(job)
  local environment = vim.fn.environ()
  environment.OPENCODE_CONFIG_CONTENT = vim.json.encode(job.config)
  environment.OPENCODE_PURE = '1'
  environment.OPENCODE_DISABLE_DEFAULT_PLUGINS = nil
  environment.OPENCODE_DISABLE_PROJECT_CONFIG = '1'
  environment.OPENCODE_DISABLE_AUTOSHARE = '1'
  return environment
end

local function restricted_config(job)
  local permission = {
    invalid = 'deny',
    read = 'allow',
    glob = 'allow',
    grep = 'allow',
    stage_text = 'allow',
    apply_patch = 'deny',
    edit = 'deny',
    write = 'deny',
    bash = 'deny',
    webfetch = 'deny',
    websearch = 'deny',
    codesearch = 'deny',
    task = 'deny',
    todowrite = 'deny',
    question = 'deny',
    skill = 'deny',
    external_directory = 'deny',
    lsp = 'deny',
  }
  local prompt = table.concat({
    'Edit only the host-selected staging target through stage_text.',
    'Use stage_text read pages as authoritative unsaved target content; context is read-only.',
    'Submit exactly once with the current revision using exact operations or a complete replacement.',
    'On submit, omit source or set it to target; never submit context.',
    'Never mutate project files. Project reads are context only.',
    'Original file: ' .. job.path,
    'Project root: ' .. job.project_root,
    'Target scope: ' .. (job.target.label or 'whole buffer'),
  }, '\n')
  local agent = {
    mode = 'primary',
    disable = false,
    prompt = prompt,
    permission = copy_table(permission),
  }
  if job.options.model then
    agent.model = job.options.model
    agent.variant = job.options.variant or nil
  end
  return {
    share = 'disabled',
    snapshot = false,
    formatter = false,
    lsp = false,
    plugin = vim.json.decode '[]',
    tool_output = copy_table(output_limit),
    tools = copy_table(safe_tools),
    permission = permission,
    agent = {
      [job.agent] = agent,
    },
  }
end

local function enabled_tools(value)
  local result = {}
  for name, enabled in pairs(value or {}) do
    if enabled == true then
      table.insert(result, name)
    end
  end
  table.sort(result)
  return result
end

local expected_enabled_tools = { 'glob', 'grep', 'read', 'stage_text' }

local function contains_provider_package(value)
  if type(value) ~= 'table' then
    return false
  end
  if value.npm ~= nil then
    return true
  end
  for _, child in pairs(value) do
    if contains_provider_package(child) then
      return true
    end
  end
  return false
end

local function validate_resolved_config(config)
  if type(config) ~= 'table' then
    return nil, 'resolved config is not an object'
  end
  if config.share ~= 'disabled' then
    return nil, 'sharing is not disabled'
  end
  if config.snapshot ~= false then
    return nil, 'snapshots are not disabled'
  end
  if config.formatter ~= false then
    return nil, 'formatters are not disabled'
  end
  if config.lsp ~= false then
    return nil, 'LSP is not disabled'
  end
  if type(config.plugin) ~= 'table' or not vim.tbl_isempty(config.plugin) then
    return nil, 'configured plugins are not disabled'
  end
  if config.mcp ~= nil and (type(config.mcp) ~= 'table' or not vim.tbl_isempty(config.mcp)) then
    return nil, 'MCP servers are configured'
  end
  if not vim.deep_equal(config.tool_output, output_limit) then
    return nil, 'tool output limits differ from 32768 bytes and 10 lines'
  end
  if not vim.deep_equal(enabled_tools(config.tools), expected_enabled_tools) then
    return nil, 'resolved enabled tools differ from read, glob, grep, and stage_text'
  end
  if config.provider ~= nil and type(config.provider) ~= 'table' then
    return nil, 'provider configuration is not an object'
  end
  for name, provider in pairs(config.provider or {}) do
    if contains_provider_package(provider) then
      return nil, 'provider ' .. name .. ' loads a custom npm package'
    end
  end
  for name, allowed in pairs(safe_tools) do
    if allowed == false and config.tools[name] == true then
      return nil, name .. ' is enabled'
    end
  end
  return true
end

local function validate_resolved_agent(agent, expected_name, expected_model, expected_variant)
  if type(agent) ~= 'table' or agent.name ~= expected_name then
    return nil, 'runtime agent resolution does not match unique agent'
  end
  if agent.mode ~= 'primary' or (agent.disable ~= nil and agent.disable ~= false) then
    return nil, 'runtime primary agent is disabled or has wrong mode'
  end
  if not vim.deep_equal(enabled_tools(agent.tools), expected_enabled_tools) then
    return nil, 'runtime agent enabled tools differ from read, glob, grep, and stage_text'
  end
  if expected_model then
    local provider, model = expected_model:match '^([^/]+)/(.+)$'
    if type(agent.model) ~= 'table' or agent.model.providerID ~= provider or agent.model.modelID ~= model then
      return nil, 'runtime agent model differs from configured model'
    end
    if agent.variant ~= expected_variant then
      return nil, 'runtime agent variant differs from configured variant'
    end
  end
  return true
end

local function show_error(message)
  local lines = vim.split(message ~= '' and message or 'Unknown OpenCode failure', '\n', { plain = true })
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

local function cleanup_environment(job)
  local root = vim.fn.stdpath 'cache' .. '/nvim-ai-edit/session-cleanup/' .. random_id()
  private_directory(root .. '/config')
  private_directory(root .. '/home')
  local environment = vim.fn.environ()
  environment.XDG_CONFIG_HOME = root .. '/config'
  environment.OPENCODE_TEST_HOME = root .. '/home'
  environment.OPENCODE_CONFIG = nil
  environment.OPENCODE_CONFIG_DIR = nil
  environment.OPENCODE_CONFIG_CONTENT = vim.json.encode {
    share = 'disabled',
    snapshot = false,
    formatter = false,
    lsp = false,
    plugin = vim.json.decode '[]',
    tools = vim.json.decode '{}',
  }
  environment.OPENCODE_PURE = '1'
  environment.OPENCODE_DISABLE_DEFAULT_PLUGINS = nil
  environment.OPENCODE_DISABLE_PROJECT_CONFIG = '1'
  environment.OPENCODE_DISABLE_AUTOSHARE = '1'
  environment.NVIM_AI_EDIT_STAGE_ROOT = nil
  environment.NVIM_AI_EDIT_STAGE_TARGET = nil
  environment.NVIM_AI_EDIT_MAX_BYTES = nil
  environment.NVIM_AI_EDIT_CONTEXT = nil
  return environment, root
end

local function job_process(channel, detached)
  local process_id = vim.fn.jobpid(channel)
  return {
    kill = function(_, signal)
      return uv.kill(detached and -process_id or process_id, signal)
    end,
  }
end

local function job_environment(environment)
  local result = copy_table(environment)
  result.NVIM = ''
  result.NVIM_LISTEN_ADDRESS = nil
  return result
end

local function delete_session(job, session_id)
  if job.deleted_sessions[session_id] then
    return
  end
  job.deleted_sessions[session_id] = true
  local environment, cleanup_root = cleanup_environment(job)
  local finished = false
  local timer = uv.new_timer()
  local process
  local function close_timer()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  local ok, channel = pcall(vim.fn.jobstart, { job.options.command, 'session', 'delete', session_id }, {
    cwd = job.project_root,
    env = job_environment(environment),
    clear_env = true,
    stdin = 'null',
    on_exit = function(_, code)
      vim.schedule(function()
        vim.fn.delete(cleanup_root, 'rf')
        if finished then
          return
        end
        finished = true
        close_timer()
        if code ~= 0 then
          notify('could not delete OpenCode session ' .. session_id, vim.log.levels.WARN)
        end
      end)
    end,
  })
  if not ok or channel <= 0 then
    close_timer()
    vim.fn.delete(cleanup_root, 'rf')
    notify('could not start OpenCode session cleanup for ' .. session_id, vim.log.levels.WARN)
    return
  end
  process = job_process(channel, false)
  timer:start(job.options.cleanup_timeout_ms, 0, function()
    vim.schedule(function()
      if finished then
        return
      end
      finished = true
      close_timer()
      pcall(process.kill, process, 15)
      local kill_timer = uv.new_timer()
      kill_timer:start(500, 0, function()
        pcall(process.kill, process, 9)
        kill_timer:stop()
        kill_timer:close()
      end)
      notify('OpenCode session cleanup timed out for ' .. session_id, vim.log.levels.WARN)
    end)
  end)
end

local function remember_session(job, value)
  if type(value) ~= 'table' then
    return
  end
  local session_id = value.sessionID or value.sessionId or value.session_id
  if type(session_id) == 'string' and session_id ~= '' then
    job.sessions[session_id] = true
    if job.done then
      delete_session(job, session_id)
    end
  end
  for _, nested in pairs(value) do
    if type(nested) == 'table' then
      remember_session(job, nested)
    end
  end
end

local function activity_event_key(prefix, event, part)
  local id = part.id or part.callID or event.id
  if type(id) == 'string' and id ~= '' then
    return prefix .. ':' .. id
  end
  return nil
end

local function safe_tool_detail(job, tool, input)
  if type(input) ~= 'table' then
    return nil
  end
  if tool == 'glob' or tool == 'grep' then
    local pattern = input.pattern
    if type(pattern) == 'string' and pattern ~= '' then
      pattern = redact_activity(job, pattern)
      if not pattern:find('[private path]', 1, true) then
        return pattern
      end
    end
  elseif tool == 'stage_text' then
    if input.action == 'submit' then
      return 'submit edit'
    end
    if input.action == 'read' and (input.source == 'target' or input.source == 'context') then
      return 'read ' .. input.source
    end
  end
  return nil
end

local function present_event(job, event)
  local part = event.part
  if event.type == 'text' and type(part) == 'table' and type(part.text) == 'string' then
    add_activity(job, 'Assistant:\n' .. part.text, activity_event_key('text', event, part))
    return
  end
  if event.type ~= 'tool_use' or type(part) ~= 'table' or type(part.state) ~= 'table' then
    return
  end
  local status = part.state.status
  if status ~= 'completed' and status ~= 'error' then
    return
  end
  local labels = {
    read = 'read context',
    glob = 'find files',
    grep = 'search text',
    stage_text = 'stage target',
  }
  local label = labels[part.tool]
  if not label then
    return
  end
  local detail = safe_tool_detail(job, part.tool, part.state.input)
  local summary = 'Tool: ' .. label
  if detail then
    summary = summary .. ' (' .. detail .. ')'
  end
  summary = summary .. (status == 'error' and ' failed' or ' complete')
  add_activity(job, summary, activity_event_key('tool', event, part))
end

local function parse_event(job, event)
  remember_session(job, event)
  if event.type == 'error' then
    job.event_error = true
    table.insert(job.errors, type(event.error) == 'string' and event.error or vim.inspect(event.error or event))
  end
  local part = event.part
  if type(part) == 'table' and type(part.state) == 'table' then
    if part.state.status == 'error' then
      job.tool_error = true
      table.insert(job.errors, tostring(part.state.error or ('tool ' .. tostring(part.tool) .. ' failed')))
    end
    if part.tool == 'stage_text' and part.state.status == 'completed' and type(part.state.input) == 'table' and part.state.input.action == 'submit' then
      job.submit_count = job.submit_count + 1
    end
  end
  present_event(job, event)
end

local function consume_stdout(job, data, final)
  if data then
    job.stdout_buffer = job.stdout_buffer .. data
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

local function validated_stage_result(job)
  local status = uv.fs_lstat(job.stage_target)
  if not status or status.type ~= 'file' then
    return nil, 'staging target is missing or not a regular file'
  end
  local resolved_root = uv.fs_realpath(job.stage_root)
  local resolved_target = uv.fs_realpath(job.stage_target)
  if not resolved_root or not resolved_target or resolved_target:sub(1, #resolved_root + 1) ~= resolved_root .. '/' then
    return nil, 'staging target escaped its private root'
  end
  local text, read_error = read_file(job.stage_target)
  if not text then
    return nil, 'cannot read staged result: ' .. tostring(read_error)
  end
  if #text > job.options.max_bytes then
    return nil, 'staged result exceeds configured size limit'
  end
  if not pcall(vim.str_utfindex, text) then
    return nil, 'staged result contains invalid UTF-8'
  end
  return text
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
  for session_id in pairs(job.sessions) do
    delete_session(job, session_id)
  end

  if outcome == 'cancelled' then
    notify('cancelled', vim.log.levels.WARN)
  elseif outcome == 'timeout' then
    notify('timed out', vim.log.levels.ERROR)
  elseif outcome == 'error' then
    local details = result or table.concat(job.errors, '\n')
    local summary = details:match '([^\n]+)' or 'OpenCode failed'
    notify('OpenCode failed: ' .. summary, vim.log.levels.ERROR)
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
      table.insert(job.errors, string.format('OpenCode exited with status %d', exit_code))
    end
    local stderr = table.concat(job.stderr)
    if stderr:match '%S' then
      table.insert(job.errors, stderr)
    end
    if exit_code ~= 0 or job.event_error or job.tool_error or job.parse_error then
      finish(job, 'error', table.concat(job.errors, '\n'))
      return
    end
    if job.submit_count ~= 1 then
      finish(job, 'error', string.format('expected exactly one successful stage_text submit, received %d', job.submit_count))
      return
    end
    local text, stage_error = validated_stage_result(job)
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

  local ok, channel = pcall(vim.fn.jobstart, { job.options.command, 'run', '--agent', job.agent, '--format', 'json' }, {
    cwd = job.project_root,
    env = job_environment(job.environment),
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
    finish(job, 'error', 'could not start OpenCode: ' .. tostring(channel))
    return
  end
  job.process = job_process(channel, false)
  local sent, send_result = pcall(vim.fn.chansend, channel, job.instruction)
  local closed, close_result = pcall(vim.fn.chanclose, channel, 'stdin')
  if not sent or send_result == 0 or not closed or close_result == 0 then
    pcall(job.process.kill, job.process, 9)
    finish(job, 'error', 'could not send OpenCode instruction')
  end
end

local function decode_debug_output(result, label)
  if result.code ~= 0 then
    return nil, label .. ' failed: ' .. tostring(result.stderr or '')
  end
  local ok, value = pcall(vim.json.decode, (result.stdout or ''):match '^%s*(.-)%s*$')
  if not ok then
    return nil, label .. ' returned invalid JSON: ' .. tostring(result.stdout)
  end
  return value
end

local function run_debug(job, arguments, label, callback, cwd, environment)
  local stdout = { chunks = {}, bytes = 0, done = false }
  local stderr = { chunks = {}, bytes = 0, done = false }
  local output_errors = {}
  local process_id
  local exit_code
  local exit_signal
  local completed = false

  local function kill_group(signal)
    if process_id then
      pcall(uv.kill, -process_id, signal)
    end
  end

  local function complete()
    if completed or exit_code == nil or not stdout.done or not stderr.done then
      return
    end
    completed = true
    vim.schedule(function()
      local stderr_text = table.concat(stderr.chunks)
      if #output_errors > 0 then
        stderr_text = stderr_text .. '\n' .. table.concat(output_errors, '\n')
      end
      callback {
        code = #output_errors == 0 and exit_code or 1,
        signal = exit_signal,
        stdout = table.concat(stdout.chunks),
        stderr = stderr_text,
      }
    end)
  end

  local function capture(state, name, data)
    if state.done then
      return
    end
    if #data == 1 and data[1] == '' then
      state.done = true
    else
      data = table.concat(data, '\n')
      local remaining = debug_output_max_bytes - state.bytes
      if #data <= remaining then
        table.insert(state.chunks, data)
        state.bytes = state.bytes + #data
      else
        if remaining > 0 then
          table.insert(state.chunks, data:sub(1, remaining))
          state.bytes = debug_output_max_bytes
        end
        table.insert(output_errors, name .. ' exceeded ' .. debug_output_max_bytes .. ' bytes')
        state.done = true
        kill_group(9)
      end
    end
    complete()
  end

  local command = { job.options.command }
  vim.list_extend(command, arguments)
  local spawn_ok, channel = pcall(vim.fn.jobstart, command, {
    cwd = cwd or job.project_root,
    env = job_environment(environment or job.environment or vim.fn.environ()),
    clear_env = true,
    detach = true,
    stdin = 'null',
    on_stdout = function(_, data)
      capture(stdout, 'stdout', data)
    end,
    on_stderr = function(_, data)
      capture(stderr, 'stderr', data)
    end,
    on_exit = function(_, code)
      exit_code = code
      exit_signal = 0
      complete()
    end,
  })
  if not spawn_ok or channel <= 0 then
    return nil, label .. ': ' .. tostring(channel)
  end
  process_id = vim.fn.jobpid(channel)
  return job_process(channel, true)
end

local function prepare_helper(job, callback)
  activity_phase(job, 'Preparing trusted helper')
  local info, info_error = helper_source(job.options.command, job.opencode_version)
  if not info then
    callback(nil, info_error)
    return
  end
  local verified = verify_helper_cache(info.cache, info.source, info.version)
  if verified then
    local sealed, seal_error = seal_helper_cache(info.root)
    callback(sealed and info.cache or nil, seal_error)
    return
  end

  local build, build_error = materialize_helper_build(info)
  if not build then
    callback(nil, build_error)
    return
  end
  job.helper_build = build.root
  local bootstrap_config = copy_table(job.config)
  bootstrap_config.model = 'opencode/big-pickle'
  local environment = isolated_environment(job, build.cache, bootstrap_config, 'bootstrap')
  local process, start_error = run_debug(job, { 'debug', 'agent', job.agent }, 'OpenCode helper bootstrap', function(result)
    if job.done then
      discard_helper_build(build.root)
      return
    end
    if result.code ~= 0 then
      discard_helper_build(build.root)
      job.helper_build = nil
      callback(nil, 'helper dependency bootstrap failed: ' .. tostring(result.stderr or ''))
      return
    end
    local valid, validation_error = verify_helper_cache(build.cache, info.source, info.version)
    if not valid then
      discard_helper_build(build.root)
      job.helper_build = nil
      callback(nil, validation_error)
      return
    end
    local sealed, seal_error = seal_helper_cache(build.root)
    if not sealed then
      discard_helper_build(build.root)
      job.helper_build = nil
      callback(nil, 'cannot seal trusted helper cache: ' .. tostring(seal_error))
      return
    end
    local published, publish_error = uv.fs_rename(build.root, info.root)
    if not published then
      discard_helper_build(build.root)
      local winner_valid, winner_error = verify_helper_cache(info.cache, info.source, info.version)
      if not winner_valid then
        job.helper_build = nil
        callback(nil, 'cannot publish trusted helper cache: ' .. tostring(publish_error or winner_error))
        return
      end
    end
    job.helper_build = nil
    callback(info.cache)
  end, job.project_root, environment)
  if not process then
    vim.fn.delete(build.root, 'rf')
    job.helper_build = nil
    callback(nil, 'could not start helper dependency bootstrap: ' .. tostring(start_error))
    return
  end
  job.process = process
end

local function preflight_agent(job)
  activity_phase(job, 'Checking edit agent')
  local process, start_error = run_debug(job, { 'debug', 'agent', job.agent }, 'OpenCode agent preflight', function(result)
    if job.done then
      return
    end
    local agent, decode_error = decode_debug_output(result, 'OpenCode agent preflight')
    if not agent then
      finish(job, 'error', decode_error)
      return
    end
    local safe, safety_error = validate_resolved_agent(agent, job.agent, job.options.model, job.options.variant)
    if not safe then
      finish(job, 'error', 'unsafe OpenCode agent configuration: ' .. safety_error)
      return
    end
    launch_run(job)
  end)
  if not process then
    finish(job, 'error', 'could not start OpenCode agent preflight: ' .. tostring(start_error))
    return
  end
  job.process = process
end

local preflight_config

local provider_config_fields = { 'model', 'small_model', 'provider', 'enabled_providers', 'disabled_providers' }

local function preflight_global_config(job)
  activity_phase(job, 'Resolving global configuration')
  local environment = global_config_environment(job)
  local process, start_error = run_debug(job, { 'debug', 'config' }, 'OpenCode global config resolution', function(result)
    if job.done then
      return
    end
    local config, decode_error = decode_debug_output(result, 'OpenCode global config resolution')
    if not config then
      finish(job, 'error', decode_error)
      return
    end
    local safe, safety_error = validate_resolved_config(config)
    if not safe then
      finish(job, 'error', 'unsafe OpenCode configuration: ' .. safety_error)
      return
    end
    if type(config.model) ~= 'string' or not config.model:match '^([^/]+)/' then
      finish(job, 'error', 'unsafe OpenCode configuration: resolved model/provider is unavailable')
      return
    end
    for _, field in ipairs(provider_config_fields) do
      if config[field] ~= nil then
        job.config[field] = copy_table(config[field])
      end
    end
    prepare_helper(job, function(cache, cache_error)
      if job.done then
        return
      end
      if not cache then
        finish(job, 'error', 'dependency bootstrap failed: ' .. tostring(cache_error))
        return
      end
      job.cache = cache
      job.environment = runtime_environment(job)
      preflight_config(job)
    end)
  end, job.project_root, environment)
  if not process then
    finish(job, 'error', 'could not start OpenCode global config resolution: ' .. tostring(start_error))
    return
  end
  job.process = process
end

local function preflight_version(job)
  activity_phase(job, 'Checking OpenCode version')
  local process, start_error = run_debug(job, { '--version' }, 'OpenCode version preflight', function(result)
    if job.done then
      return
    end
    if result.code ~= 0 then
      finish(job, 'error', 'OpenCode version preflight failed: ' .. tostring(result.stderr or ''))
      return
    end
    local version = (result.stdout or ''):match '^%s*(.-)%s*$'
    if not version_policy.supported(version) then
      finish(job, 'error', 'unsupported OpenCode version: expected ' .. version_policy.range .. ', resolved ' .. tostring(version))
      return
    end
    job.opencode_version = version
    preflight_global_config(job)
  end)
  if not process then
    finish(job, 'error', 'could not start OpenCode version preflight: ' .. tostring(start_error))
    return
  end
  job.process = process
end

preflight_config = function(job)
  activity_phase(job, 'Checking runtime configuration')
  local process, start_error = run_debug(job, { 'debug', 'config' }, 'OpenCode dependency/config preflight', function(result)
    if job.done then
      return
    end
    local config, decode_error = decode_debug_output(result, 'OpenCode dependency/config preflight')
    if not config then
      finish(job, 'error', decode_error)
      return
    end
    local safe, safety_error = validate_resolved_config(config)
    if not safe then
      finish(job, 'error', 'unsafe OpenCode configuration: ' .. safety_error)
      return
    end
    if type(config.model) ~= 'string' then
      finish(job, 'error', 'unsafe OpenCode configuration: resolved model/provider is unavailable')
      return
    end
    if not config.model:match '^([^/]+)/' then
      finish(job, 'error', 'unsafe OpenCode configuration: resolved model has no provider')
      return
    end
    preflight_agent(job)
  end)
  if not process then
    finish(job, 'error', 'could not start OpenCode config preflight: ' .. tostring(start_error))
    return
  end
  job.process = process
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
    project_root = project_root(snapshot.path),
    full_text = snapshot.text,
    target_text = snapshot.target_text,
    target = snapshot.target,
    changedtick = snapshot.changedtick,
    endofline = snapshot.endofline,
    instruction = instruction,
    options = copy_table(options),
    agent = 'nvim-ai-edit-' .. random_id(),
    sessions = {},
    deleted_sessions = {},
    errors = {},
    stderr = {},
    stdout_buffer = '',
    submit_count = 0,
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
  job.config = restricted_config(job)
  job.timer = uv.new_timer()
  job.timer:start(job.options.timeout_ms, 0, function()
    vim.schedule(function()
      stop_job(job, 'timeout')
    end)
  end)
  notify 'running'
  preflight_version(job)
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
    notify('OpenCode executable not found: ' .. options.command, vim.log.levels.ERROR)
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
    variant = true,
    timeout_ms = true,
    cleanup_timeout_ms = true,
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
  if overrides.variant ~= false and (type(overrides.variant) ~= 'string' or overrides.variant == '') then
    error 'ai_edit: variant must be false or non-empty text'
  end
  if overrides.variant and not overrides.model then
    error 'ai_edit: variant requires model'
  end
  for _, key in ipairs { 'timeout_ms', 'cleanup_timeout_ms', 'max_bytes' } do
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
