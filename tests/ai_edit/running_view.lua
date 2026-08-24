local function fail(message)
  error(message, 2)
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail((message or 'values differ') .. '\nexpected: ' .. vim.inspect(expected) .. '\nactual: ' .. vim.inspect(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or 'expected truthy value')
  end
end

local function wait_for(predicate, message, timeout)
  truthy(vim.wait(timeout or 20000, predicate, 10), message)
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p', tonumber('700', 8))
vim.o.columns = 120
vim.o.lines = 40
vim.env.AI_EDIT_FAKE_LOG = root .. '/fake.log'
vim.env.AI_EDIT_GLOBAL_MODEL = 'test-provider/inherited-model'

local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

local function clear_notifications()
  notifications = {}
end

local function notified(pattern)
  for _, message in ipairs(notifications) do
    for alternative in pattern:gmatch '[^|]+' do
      if message:lower():match(alternative:lower()) then
        return true
      end
    end
  end
  return false
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function make_buffer(name, lines)
  local path = root .. '/' .. name
  vim.fn.writefile(lines, path, 'b')
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, path)
  vim.bo[buffer].buftype = ''
  vim.bo[buffer].binary = false
  vim.bo[buffer].readonly = false
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modified = false
  return buffer, path
end

local function open_file(name, lines)
  local buffer, path = make_buffer(name, lines)
  vim.api.nvim_set_current_buf(buffer)
  return buffer, path
end

local function buffer_lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function activity_buffer(target)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) then
      local marked, value = pcall(vim.api.nvim_buf_get_var, buffer, 'ai_edit_activity')
      local has_target, activity_target = pcall(vim.api.nvim_buf_get_var, buffer, 'ai_edit_target')
      if marked and value == true and has_target and activity_target == target then
        return buffer
      end
    end
  end
end

local function activity_window(target)
  local buffer = activity_buffer(target)
  if not buffer then
    return nil
  end
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_buf(window) == buffer then
      return window
    end
  end
end

local function transcript(target)
  local buffer = activity_buffer(target)
  if not buffer then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n')
end

local function invoke(buffer, instruction, keymap)
  vim.api.nvim_set_current_buf(buffer)
  feed(keymap or '<F8>')
  wait_for(function()
    return vim.api.nvim_get_current_buf() ~= buffer and vim.bo.buftype == 'nofile'
  end, 'AI edit prompt did not open')
  local prompt = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, vim.split(instruction, '\n', { plain = true }))
  feed '<CR>'
  wait_for(function()
    return vim.api.nvim_buf_is_valid(buffer) and not vim.bo[buffer].modifiable
  end, 'target did not lock immediately')
end

local function wait_done(ai_edit, pattern)
  wait_for(function()
    return ai_edit.statusline() == '' and (not pattern or notified(pattern))
  end, 'AI edit did not reach terminal state' .. (pattern and ': ' .. pattern or ''))
end

local function close_floats()
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_config(window).relative ~= '' then
      pcall(vim.api.nvim_win_close, window, true)
    end
  end
end

local hidden_cursor = 'n-v-ve-o-i-r-sm:AIEditHiddenCursor'

local function cursor_segment_count()
  local count = 0
  for segment in vim.o.guicursor:gmatch '[^,]+' do
    if segment == hidden_cursor then
      count = count + 1
    end
  end
  return count
end

local function strip_cursor_segment(value)
  local segments = {}
  for segment in value:gmatch '[^,]+' do
    if segment ~= hidden_cursor then
      table.insert(segments, segment)
    end
  end
  return table.concat(segments, ',')
end

local case = assert(vim.env.AI_EDIT_RUNNING_VIEW_CASE, 'missing AI_EDIT_RUNNING_VIEW_CASE')
if case == 'cursor' then
  vim.o.guicursor = 'n:block,i:ver25,c:hor20'
end

local ai_edit = require 'ai_edit'
local function setup(overrides)
  local values = {
    keymap = '<F8>',
    command = vim.env.AI_EDIT_FAKE_COMMAND or (vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts'),
    timeout_ms = 15000,
    cleanup_timeout_ms = 300,
    max_bytes = 1024 * 1024,
    width = 0.6,
    height = 0.3,
  }
  for key, value in pairs(overrides or {}) do
    values[key] = value
  end
  ai_edit.setup(values)
end

setup()

if case == 'lock-basic' then
  vim.env.AI_EDIT_FAKE_SCENARIO = 'parallel'
  local target = open_file('lock-basic.lua', { 'local original = true', 'return original' })
  local original = buffer_lines(target)
  local changedtick = vim.api.nvim_buf_get_changedtick(target)
  invoke(target, 'lock basic')

  local api_edit = pcall(vim.api.nvim_buf_set_lines, target, 0, 1, false, { 'blocked API edit' })
  truthy(not api_edit, 'locked target accepted API mutation')
  vim.api.nvim_set_current_buf(target)
  feed 'iBLOCKED<Esc>'
  vim.wait(50)
  equal(buffer_lines(target), original, 'ordinary insert changed locked target')
  equal(vim.api.nvim_buf_get_changedtick(target), changedtick, 'blocked edits changed target revision')

  local unrelated = open_file('unrelated.lua', { 'writable' })
  vim.api.nvim_buf_set_lines(unrelated, 0, -1, false, { 'edited elsewhere' })
  equal(buffer_lines(unrelated), { 'edited elsewhere' }, 'unrelated buffer could not be edited')

  wait_for(function()
    return vim.deep_equal(buffer_lines(target), { 'normal result' })
  end, 'successful result was not applied')
  truthy(vim.bo[target].modifiable, 'successful target remained locked')
  truthy(vim.bo[target].modified, 'successful result was not left unsaved')
  vim.api.nvim_set_current_buf(target)
  vim.cmd 'undo'
  equal(buffer_lines(target), original, 'one undo did not restore locked target snapshot')
  wait_done(ai_edit, 'changed|revert|undo')
  truthy(activity_buffer(target) == nil, 'successful activity buffer leaked')
elseif case == 'lock-concurrency' then
  vim.env.AI_EDIT_FAKE_SCENARIO = 'run-hold'
  local first = open_file('concurrent-one.lua', { 'one' })
  local first_window = vim.api.nvim_get_current_win()
  invoke(first, 'concurrent one')

  vim.cmd 'vnew'
  local second = open_file('concurrent-two.lua', { 'two' })
  local second_window = vim.api.nvim_get_current_win()
  invoke(second, 'concurrent two')
  truthy(not vim.bo[first].modifiable and not vim.bo[second].modifiable, 'concurrent targets were not independently locked')
  truthy(activity_buffer(first) ~= activity_buffer(second), 'concurrent jobs shared activity buffers')
  truthy(activity_window(first) ~= nil and activity_window(second) ~= nil, 'concurrent visible targets lacked separate activity views')

  vim.api.nvim_set_current_win(first_window)
  equal(cursor_segment_count(), 1, 'first locked target lacked one cursor override')
  vim.api.nvim_set_current_win(second_window)
  equal(cursor_segment_count(), 1, 'direct locked-target switch duplicated cursor override')

  ai_edit.cancel(first)
  wait_for(function()
    return vim.bo[first].modifiable and activity_buffer(first) == nil
  end, 'first concurrent job did not clean up')
  truthy(not vim.bo[second].modifiable, 'finishing first job unlocked second target')
  equal(cursor_segment_count(), 1, 'finishing first job released current second-target cursor override')
  ai_edit.cancel(second)
  wait_done(ai_edit, 'cancel')
  truthy(vim.bo[second].modifiable, 'second concurrent target remained locked')
  equal(cursor_segment_count(), 0, 'concurrent terminal cleanup leaked cursor override')
elseif case == 'setup-active' then
  vim.env.AI_EDIT_FAKE_SCENARIO = 'run-hold'
  local target = open_file('setup-active.lua', { 'active setup target' })
  invoke(target, 'preserve active setup')
  local activity = assert(activity_buffer(target), 'active setup activity did not start')
  local autocmd_count = #vim.api.nvim_get_autocmds { group = 'ai_edit_running_view' }

  setup { keymap = '<F9>', timeout_ms = 60, status = { text = 'Reconfigured', frames = { 'z' } } }
  equal(vim.fn.maparg('<F8>', 'n'), '', 'old normal mapping remained after setup')
  equal(vim.fn.maparg('<F8>', 'x'), '', 'old visual mapping remained after setup')
  truthy(vim.fn.maparg('<F9>', 'n') ~= '', 'new normal mapping missing after setup')
  truthy(vim.fn.maparg('<F9>', 'x') ~= '', 'new visual mapping missing after setup')
  truthy(vim.fn.exists ':AIEditCancel' == 2, 'cancel command missing after repeated setup')
  equal(#vim.api.nvim_get_autocmds { group = 'ai_edit_running_view' }, autocmd_count, 'repeated setup duplicated autocommands')
  equal(ai_edit.statusline(), 'z Reconfigured', 'repeated setup invalidated active status frame')

  vim.wait(100)
  truthy(not vim.bo[target].modifiable, 'new timeout changed active job')
  equal(activity_buffer(target), activity, 'repeated setup replaced active activity state')
  ai_edit.cancel(target)
  wait_done(ai_edit, 'cancel')
  truthy(vim.bo[target].modifiable, 'active target remained locked after cancellation')

  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'timeout'
  target = open_file('setup-subsequent.lua', { 'subsequent setup target' })
  invoke(target, 'use subsequent setup', '<F9>')
  wait_done(ai_edit, 'timeout|timed out')
elseif case == 'stale-targets' then
  local function start(name)
    clear_notifications()
    vim.env.AI_EDIT_FAKE_SCENARIO = 'stale'
    local buffer = open_file(name .. '.lua', { 'snapshot' })
    invoke(buffer, name)
    return buffer
  end

  local buffer = start 'forced-mutation'
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'newer text' })
  wait_done(ai_edit, 'stale|changed')
  equal(buffer_lines(buffer), { 'newer text' }, 'forced mutation was overwritten')
  truthy(vim.bo[buffer].modifiable, 'forced stale target remained locked')

  buffer = start 'renamed-target'
  vim.api.nvim_buf_set_name(buffer, root .. '/renamed-elsewhere.lua')
  wait_done(ai_edit, 'file|stale|target')
  truthy(vim.bo[buffer].modifiable, 'renamed target remained locked')

  buffer = start 'unloaded-target'
  vim.api.nvim_buf_delete(buffer, { force = true, unload = true })
  wait_done(ai_edit, 'available|buffer')
  if vim.api.nvim_buf_is_valid(buffer) then
    truthy(vim.api.nvim_get_option_value('modifiable', { buf = buffer }), 'unloaded target option was not restored')
  end

  buffer = start 'deleted-target'
  vim.api.nvim_buf_delete(buffer, { force = true })
  wait_done(ai_edit, 'available|buffer')
  truthy(activity_buffer(buffer) == nil, 'deleted target leaked activity buffer')
elseif case == 'lock-optionset' then
  local target
  local option_events = 0
  vim.api.nvim_create_autocmd('OptionSet', {
    pattern = 'modifiable',
    callback = function()
      if target and vim.api.nvim_buf_is_valid(target) and vim.api.nvim_get_current_buf() == target then
        option_events = option_events + 1
        pcall(vim.cmd, 'noautocmd setlocal modifiable')
        pcall(vim.api.nvim_buf_set_lines, target, 0, -1, false, { 'hostile option callback' })
      end
    end,
  })

  vim.env.AI_EDIT_FAKE_SCENARIO = 'parallel'
  target = open_file('optionset-apply.lua', { 'before apply' })
  invoke(target, 'optionset apply')
  wait_for(function()
    return vim.deep_equal(buffer_lines(target), { 'normal result' })
  end, 'hostile OptionSet apply case did not finish')
  wait_done(ai_edit)
  equal(option_events, 0, 'OptionSet ran during owned acquisition or application')
  truthy(vim.bo[target].modifiable, 'application did not restore modifiable')

  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'run-hold'
  target = open_file('optionset-cancel.lua', { 'before cancel' })
  invoke(target, 'optionset cancel')
  local original_cmd = vim.cmd
  local restore_failures = 0
  vim.cmd = function(command)
    if command == 'noautocmd setlocal modifiable' and vim.api.nvim_get_current_buf() == target and restore_failures == 0 then
      restore_failures = restore_failures + 1
      error 'injected one-time restore failure'
    end
    return original_cmd(command)
  end
  ai_edit.cancel(target)
  vim.cmd = original_cmd
  wait_done(ai_edit, 'cancel')
  equal(restore_failures, 1, 'restore failure injection did not run')
  equal(option_events, 0, 'OptionSet ran during owned terminal restoration')
  equal(buffer_lines(target), { 'before cancel' }, 'hostile OptionSet mutated cancelled target')
  truthy(vim.bo[target].modifiable, 'cancel did not restore modifiable')
elseif case == 'cursor' then
  local original = 'n:block,i:ver25,c:hor20'
  vim.env.AI_EDIT_FAKE_SCENARIO = 'run-hold'
  local target = open_file('cursor.lua', { 'cursor target' })
  invoke(target, 'cursor ownership')
  equal(cursor_segment_count(), 1, 'locked target did not install exactly one cursor override')
  equal(vim.api.nvim_get_hl(0, { name = 'AIEditHiddenCursor' }).blend, 100, 'hidden cursor highlight blend differs')
  truthy(not hidden_cursor:match 'c[:%-]', 'owned cursor segment includes command-line mode')

  local unrelated = open_file('cursor-unrelated.lua', { 'visible cursor' })
  equal(vim.o.guicursor, original, 'unrelated buffer did not restore clean cursor base')
  vim.api.nvim_set_current_buf(target)
  equal(vim.o.guicursor, original .. ',' .. hidden_cursor, 'target redisplay did not restore cursor suppression')

  local late_handler_runs = 0
  vim.api.nvim_create_autocmd('OptionSet', {
    pattern = 'guicursor',
    callback = function()
      if vim.o.guicursor:find(hidden_cursor, 1, true) then
        late_handler_runs = late_handler_runs + 1
        vim.o.guicursor = strip_cursor_segment(vim.o.guicursor)
      end
    end,
  })

  local replaced = 'n:hor20,i:ver30,c:block'
  vim.o.guicursor = replaced
  wait_for(function()
    return vim.o.guicursor == replaced .. ',' .. hidden_cursor
  end, 'external cursor replacement was not normalized after later handler')
  vim.o.guicursor = vim.o.guicursor .. ',a:blinkwait100'
  local appended = replaced .. ',a:blinkwait100'
  wait_for(function()
    return vim.o.guicursor == appended .. ',' .. hidden_cursor
  end, 'external cursor append leaked override ordering')
  vim.o.guicursor = 'v:hor10,' .. vim.o.guicursor
  local prepended = 'v:hor10,' .. appended
  wait_for(function()
    return vim.o.guicursor == prepended .. ',' .. hidden_cursor
  end, 'external cursor prepend leaked override ordering')
  vim.o.guicursor = strip_cursor_segment(vim.o.guicursor)
  wait_for(function()
    return vim.o.guicursor == prepended .. ',' .. hidden_cursor
  end, 'external cursor removal was not re-owned')
  truthy(late_handler_runs > 0, 'later guicursor OptionSet handler did not exercise reconciliation')
  equal(cursor_segment_count(), 1, 'external cursor changes produced duplicate owned segments')

  vim.api.nvim_set_current_buf(unrelated)
  equal(vim.o.guicursor, prepended, 'latest normalized cursor base was not restored')
  vim.api.nvim_set_current_buf(target)
  ai_edit.cancel(target)
  wait_done(ai_edit, 'cancel')
  equal(vim.o.guicursor, prepended, 'terminal cleanup did not restore latest cursor base')
  equal(cursor_segment_count(), 0, 'terminal cleanup leaked owned cursor segment')
elseif case == 'activity-events' then
  vim.env.AI_EDIT_FAKE_SCENARIO = 'activity-events'
  local target = open_file('activity.lua', { 'activity target' })
  local target_window = vim.api.nvim_get_current_win()
  invoke(target, 'show activity request')
  equal(vim.api.nvim_get_current_win(), target_window, 'opening activity view changed focus')

  wait_for(function()
    local value = transcript(target)
    return value and value:find('DUPLICATE_NEW_TEXT', 1, true)
  end, 'complete activity event stream did not appear')
  local buffer = assert(activity_buffer(target), 'activity buffer missing')
  local window = assert(activity_window(target), 'activity window missing')
  local config = vim.api.nvim_win_get_config(window)
  equal(config.relative, 'win', 'activity float was not window-relative')
  equal(config.win, target_window, 'activity float was not anchored to target window')
  equal(config.focusable, false, 'activity float was focusable')
  equal(config.mouse, false, 'activity float accepted mouse input')
  equal(config.col + config.width + 2, vim.api.nvim_win_get_width(target_window), 'activity float was not right-aligned inside target')
  truthy(config.border and #config.border > 0, 'activity float lacked rounded border')
  equal(vim.api.nvim_get_current_win(), target_window, 'activity updates changed focus')
  truthy(not vim.bo[buffer].modifiable and vim.bo[buffer].readonly, 'activity transcript was not readonly')

  local value = transcript(target)
  for _, expected in ipairs {
    'Request:\nshow activity request',
    'Phase: Preparing staging',
    'Phase: Checking OpenCode version',
    'Phase: Resolving global configuration',
    'Phase: Preparing trusted helper',
    'Phase: Checking runtime configuration',
    'Phase: Checking edit agent',
    'Phase: Running model',
    'ASSISTANT_SAFE_TEXT',
    'SAFE_GLOB_PATTERN',
    'SAFE_GREP_PATTERN',
    'read target',
    'DUPLICATE_NEW_TEXT',
  } do
    truthy(value:find(expected, 1, true), 'activity transcript omitted ' .. expected)
  end
  for _, forbidden in ipairs {
    'MODEL_REASONING_SECRET',
    'RAW_TOOL_OUTPUT_SECRET',
    'REPLACEMENT_SECRET',
    'UNKNOWN_PAYLOAD_SECRET',
    'UNKNOWN_TOOL_INPUT_SECRET',
    'DUPLICATE_OLD_TEXT',
    'fake-session',
    '\1',
  } do
    truthy(not value:find(forbidden, 1, true), 'activity transcript exposed ' .. vim.inspect(forbidden))
  end
  truthy(value:find('[private path]', 1, true) and value:find('[session]', 1, true), 'sensitive values were not redacted')
  equal(vim.api.nvim_win_get_cursor(window)[1], vim.api.nvim_buf_line_count(buffer), 'activity view did not scroll to newest line')

  local unrelated = make_buffer('activity-hidden.lua', { 'hide target' })
  vim.api.nvim_win_set_buf(target_window, unrelated)
  wait_for(function()
    return activity_window(target) == nil
  end, 'activity float stayed open after target became hidden')
  truthy(vim.api.nvim_buf_is_valid(buffer), 'hidden target deleted activity transcript')
  vim.api.nvim_win_set_buf(target_window, target)
  wait_for(function()
    return activity_window(target) ~= nil
  end, 'activity float did not reopen when target became visible')

  vim.o.columns = 72
  vim.api.nvim_exec_autocmds('VimResized', {})
  wait_for(function()
    local resized = activity_window(target)
    if not resized then
      return false
    end
    local resized_config = vim.api.nvim_win_get_config(resized)
    return resized_config.col + resized_config.width + 2 == vim.api.nvim_win_get_width(target_window)
  end, 'activity float did not clamp and realign after resize')

  vim.cmd 'vnew'
  local narrow_neighbor = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(target_window, 1)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait_for(function()
    return activity_window(target) == nil
  end, 'activity float overflowed a one-column target window')
  vim.api.nvim_win_set_width(target_window, 20)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait_for(function()
    return activity_window(target) ~= nil
  end, 'activity float did not return after target regained usable width')
  pcall(vim.api.nvim_win_close, narrow_neighbor, true)

  wait_for(function()
    return vim.deep_equal(buffer_lines(target), { 'normal result' })
  end, 'activity event run did not apply result')
  wait_done(ai_edit)
  truthy(not vim.api.nvim_buf_is_valid(buffer), 'terminal outcome leaked activity buffer')
  truthy(not vim.api.nvim_win_is_valid(window), 'terminal outcome leaked activity window')
elseif case == 'activity-bounds' then
  local function assert_bounds(scenario, tail, marker, absent)
    clear_notifications()
    vim.env.AI_EDIT_FAKE_SCENARIO = scenario
    local target = open_file(scenario .. '.lua', { 'bounded activity' })
    invoke(target, scenario)
    wait_for(function()
      local value = transcript(target)
      return value and value:find(tail, 1, true)
    end, scenario .. ' newest activity was not retained')
    local buffer = assert(activity_buffer(target), scenario .. ' activity buffer missing')
    local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    local value = table.concat(lines, '\n')
    truthy(#value <= vim.b[buffer].ai_edit_max_bytes, scenario .. ' exceeded aggregate byte bound')
    truthy(#lines <= vim.b[buffer].ai_edit_max_lines, scenario .. ' exceeded aggregate line bound')
    truthy(pcall(vim.str_utfindex, value), scenario .. ' truncated invalid UTF-8')
    truthy(value:find(marker, 1, true), scenario .. ' omitted truncation marker')
    if absent then
      truthy(not value:find(absent, 1, true), scenario .. ' retained oldest aggregate entry')
    end
    local window = assert(activity_window(target), scenario .. ' activity window missing')
    equal(vim.api.nvim_win_get_cursor(window)[1], #lines, scenario .. ' did not auto-scroll')
    wait_for(function()
      return ai_edit.statusline() == ''
    end, scenario .. ' did not finish')
    truthy(not vim.api.nvim_buf_is_valid(buffer), scenario .. ' leaked transcript buffer')
  end

  assert_bounds('activity-single-limit', 'SINGLE_ENTRY_TAIL', '[earlier entry truncated]')
  assert_bounds('activity-aggregate-limit', 'AGGREGATE_ACTIVITY_TAIL', '[earlier activity truncated]', '000:')
  assert_bounds('activity-keyed-growth', 'KEYED_GROWTH_TAIL', '[earlier activity truncated]', 'small-0')
elseif case == 'terminal-matrix' then
  local function assert_clean(target, activity, message)
    if vim.api.nvim_buf_is_valid(target) then
      truthy(vim.bo[target].modifiable, message .. ' left target locked')
    end
    truthy(not vim.api.nvim_buf_is_valid(activity), message .. ' leaked activity buffer')
    equal(cursor_segment_count(), 0, message .. ' leaked cursor override')
    close_floats()
  end

  local function run(scenario, pattern, trigger)
    clear_notifications()
    vim.env.AI_EDIT_FAKE_SCENARIO = scenario
    local target = open_file('terminal-' .. scenario .. '.lua', { 'terminal original' })
    invoke(target, 'terminal ' .. scenario)
    local activity = assert(activity_buffer(target), scenario .. ' activity did not start')
    if trigger then
      trigger(target)
    end
    wait_done(ai_edit, pattern)
    assert_clean(target, activity, scenario)
  end

  run('no-op', 'no changes')
  run('nonzero', 'failed|error')
  run('run-hold', 'cancel', function(target)
    ai_edit.cancel(target)
  end)
  setup { timeout_ms = 60 }
  run('timeout', 'timeout|timed out')
  setup()
  run('stale', 'stale|changed', function(target)
    vim.bo[target].modifiable = true
    vim.api.nvim_buf_set_lines(target, 0, -1, false, { 'forced terminal mutation' })
  end)

  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'parallel'
  local target = open_file('terminal-application-error.lua', { 'before application error' })
  invoke(target, 'application error')
  local activity = assert(activity_buffer(target), 'application error activity did not start')
  local original_set_lines = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(buffer, ...)
    if buffer == target and vim.bo[target].modifiable then
      error 'injected application failure'
    end
    return original_set_lines(buffer, ...)
  end
  wait_done(ai_edit, 'failed|apply|error')
  vim.api.nvim_buf_set_lines = original_set_lines
  assert_clean(target, activity, 'application error')
  equal(buffer_lines(target), { 'before application error' }, 'failed application changed target')
else
  fail('unknown running-view case: ' .. case)
end

vim.fn.delete(root, 'rf')
print('running-view assertion passed: ' .. case)
