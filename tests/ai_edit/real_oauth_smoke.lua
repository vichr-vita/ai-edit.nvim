local project = assert(vim.env.AI_EDIT_REAL_PROJECT)
local command = assert(vim.env.AI_EDIT_REAL_OPENCODE)
local target = project .. '/src/target.ts'
local notifications = {}

vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function read_file(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read '*a'
  file:close()
  return value
end

local function prompt(buffer, instruction)
  assert(
    vim.wait(2000, function()
      return vim.api.nvim_get_current_buf() ~= buffer and vim.bo.buftype == 'nofile'
    end, 10),
    'real OAuth smoke prompt did not open'
  )
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { instruction })
  feed '<CR>'
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

local function assert_running(buffer, instruction)
  assert(
    vim.wait(2000, function()
      return not vim.bo[buffer].modifiable and activity_buffer(buffer) ~= nil
    end, 10),
    'installed OpenCode smoke did not lock target and open activity immediately'
  )
  assert(vim.api.nvim_get_current_buf() == buffer, 'activity view changed focus')
  local activity = assert(activity_buffer(buffer))
  assert(#vim.fn.win_findbuf(activity) > 0, 'activity transcript was not visible beside target')
  local transcript = table.concat(vim.api.nvim_buf_get_lines(activity, 0, -1, false), '\n')
  assert(transcript:find(instruction, 1, true), 'activity transcript omitted submitted request')

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local changedtick = vim.api.nvim_buf_get_changedtick(buffer)
  assert(not pcall(vim.api.nvim_buf_set_lines, buffer, 0, 1, false, { 'blocked smoke mutation' }), 'locked target accepted edit')
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), lines), 'blocked edit changed target text')
  assert(vim.api.nvim_buf_get_changedtick(buffer) == changedtick, 'blocked edit changed target revision')
  return activity
end

local function wait_for_change(buffer, previous_notification_count)
  assert(
    vim.wait(190000, function()
      for index = previous_notification_count + 1, #notifications do
        local message = notifications[index]:lower()
        if message:match 'changed' or message:match 'failed' or message:match 'timed out' then
          return true
        end
      end
      return false
    end, 10),
    'installed OpenCode OAuth smoke did not finish'
  )
  assert(not notifications[#notifications]:lower():match 'failed', vim.inspect(notifications))
  vim.api.nvim_set_current_buf(buffer)
  assert(vim.bo[buffer].modifiable, 'installed OpenCode result left target locked')
  assert(activity_buffer(buffer) == nil, 'installed OpenCode result leaked activity view')
end

vim.cmd('silent edit ' .. vim.fn.fnameescape(target))
local buffer = vim.api.nvim_get_current_buf()
local before = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
local before_disk = read_file(target)
local ai_edit = require 'ai_edit'
ai_edit.setup {
  keymap = '<F8>',
  command = command,
  timeout_ms = 180000,
  cleanup_timeout_ms = 5000,
}

local notification_count = #notifications
feed '<F8>'
local whole_instruction = 'Use stage_text to replace exact text REAL_PROJECT_TARGET with OAUTH_WHOLE_RESULT. Preserve everything else and submit exactly once.'
prompt(buffer, whole_instruction)
assert_running(buffer, whole_instruction)
wait_for_change(buffer, notification_count)
local result = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(result[1] == 'OAUTH_WHOLE_RESULT', 'whole-buffer OAuth smoke produced unexpected result: ' .. vim.inspect(notifications))
assert(vim.bo[buffer].modified, 'whole-buffer OAuth result was saved automatically')
assert(read_file(target) == before_disk, 'whole-buffer OAuth result changed disk before manual save')
vim.cmd 'undo'
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), before), 'whole-buffer OAuth undo did not restore target')

local utf8_line = 'prefix café 中央 suffix'
local utf8_before = { utf8_line, 'untouched line' }
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, utf8_before)
vim.cmd 'write'
local utf8_disk = read_file(target)
local selected = 'café 中央'
local start_col = assert(utf8_line:find(selected, 1, true)) - 1
local end_col = start_col + #selected - #'央'
vim.api.nvim_win_set_cursor(0, { 1, start_col })
feed 'v'
vim.api.nvim_win_set_cursor(0, { 1, end_col })
notification_count = #notifications
feed '<F8>'
local selection_instruction = 'Replace the entire staged UTF-8 selection with UTF8_SELECTION_RESULT using stage_text. Submit exactly once.'
prompt(buffer, selection_instruction)
assert_running(buffer, selection_instruction)
wait_for_change(buffer, notification_count)
result = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(result[1] == 'prefix UTF8_SELECTION_RESULT suffix', 'UTF-8 selection OAuth smoke escaped or missed selection: ' .. vim.inspect(result))
assert(result[2] == 'untouched line', 'UTF-8 selection OAuth smoke changed unselected line')
assert(vim.bo[buffer].modified, 'UTF-8 selection OAuth result was saved automatically')
assert(read_file(target) == utf8_disk, 'UTF-8 selection OAuth result changed disk before manual save')
vim.cmd 'write'
assert(read_file(target):match '^prefix UTF8_SELECTION_RESULT suffix\n', 'manual save did not persist reviewed OAuth result')
vim.cmd 'undo'
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), utf8_before), 'UTF-8 selection OAuth undo did not restore target')

local before_cancel = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
notification_count = #notifications
feed '<F8>'
local cancel_instruction = 'Prepare an edit with stage_text, but wait before submitting.'
prompt(buffer, cancel_instruction)
local cancel_activity = assert_running(buffer, cancel_instruction)
ai_edit.cancel(buffer)
assert(
  vim.wait(2000, function()
    for index = notification_count + 1, #notifications do
      if notifications[index]:lower():match 'cancel' then
        return true
      end
    end
    return false
  end, 10),
  'installed OpenCode cancellation did not finish'
)
assert(vim.bo[buffer].modifiable, 'installed OpenCode cancellation left target locked')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), before_cancel), 'installed OpenCode cancellation changed target')
assert(not vim.api.nvim_buf_is_valid(cancel_activity), 'installed OpenCode cancellation leaked activity transcript')
assert(ai_edit.statusline() == '', 'installed OpenCode cancellation leaked active status')

vim.api.nvim_buf_set_lines(buffer, 0, -1, false, before)
vim.bo[buffer].endofline = before_disk:sub(-1) == '\n'
vim.cmd 'write'
assert(read_file(target) == before_disk, 'OAuth smoke did not restore fixture bytes')
vim.wait(6000, function()
  return false
end, 10)
for _, message in ipairs(notifications) do
  assert(not message:lower():match 'could not delete', 'automatic OAuth session cleanup failed: ' .. message)
  assert(not message:lower():match 'cleanup timed out', 'automatic OAuth session cleanup timed out: ' .. message)
end
print 'installed OpenCode whole-buffer and UTF-8 selection OAuth smoke passed'
