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
  truthy(vim.wait(timeout or 5000, predicate, 10), message)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p', tonumber('700', 8))
local fake = vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts'
vim.env.AI_EDIT_FAKE_LOG = root .. '/fake.log'
vim.env.AI_EDIT_FAKE_SCENARIO = 'run-hold'

local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

local function clear_notifications()
  notifications = {}
end

local function notified(pattern)
  for _, message in ipairs(notifications) do
    if message:lower():match(pattern:lower()) then
      return true
    end
  end
  return false
end

local function write_file(path, lines)
  vim.fn.writefile(lines, path, 'b')
end

local function open_file(name, lines)
  local path = root .. '/' .. name
  write_file(path, lines)
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  vim.bo.binary = false
  vim.bo.readonly = false
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  return vim.api.nvim_get_current_buf()
end

local function prompt_windows()
  local frame
  local input
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    local buffer = vim.api.nvim_win_get_buf(window)
    if vim.b[buffer].ai_edit_prompt_frame then
      frame = window
    elseif vim.b[buffer].ai_edit_prompt then
      input = window
    end
  end
  return frame, input
end

local function prompt_count()
  local count = 0
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    local buffer = vim.api.nvim_win_get_buf(window)
    if vim.b[buffer].ai_edit_prompt_frame or vim.b[buffer].ai_edit_prompt then
      count = count + 1
    end
  end
  return count
end

local function prompt_text(input)
  local buffer = vim.api.nvim_win_get_buf(input)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n')
end

local original_screenrow = vim.fn.screenrow
local original_screencol = vim.fn.screencol
local function invoke_at(buffer, row, col)
  local existing = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    existing[window] = true
  end
  vim.api.nvim_set_current_buf(buffer)
  vim.fn.screenrow = function()
    return row
  end
  vim.fn.screencol = function()
    return col
  end
  feed '<F8>'
  vim.fn.screenrow = original_screenrow
  vim.fn.screencol = original_screencol
  wait_for(function()
    return prompt_count() >= 2
  end, 'prompt did not open')
  local frame
  local input
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if not existing[window] then
      local owned_buffer = vim.api.nvim_win_get_buf(window)
      if vim.b[owned_buffer].ai_edit_prompt_frame then
        frame = window
      elseif vim.b[owned_buffer].ai_edit_prompt then
        input = window
      end
    end
  end
  truthy(frame and input, 'new prompt windows were not identifiable')
  return frame, input
end

local function close_prompt()
  feed '<Esc>'
  wait_for(function()
    return prompt_count() == 0
  end, 'prompt floats did not close')
end

local ai_edit = require 'ai_edit'
local base_options = {
  keymap = '<F8>',
  command = fake,
  timeout_ms = 2000,
  cleanup_timeout_ms = 500,
  max_bytes = 1024 * 1024,
  width = 0.5,
  height = 0.2,
  status = {
    text = 'AI is Working...',
    color = '#d946ef',
    interval_ms = 20,
    frames = { '.', ':' },
  },
}

local function setup(overrides)
  local values = vim.deepcopy(base_options)
  for key, value in pairs(overrides or {}) do
    values[key] = value
  end
  ai_edit.setup(values)
end

local original_columns = vim.o.columns
local original_lines = vim.o.lines
local original_cmdheight = vim.o.cmdheight
vim.o.columns = 80
vim.o.lines = 25
vim.o.cmdheight = 1

-- Omit dimensions once so this geometry proves module defaults.
local default_options = vim.deepcopy(base_options)
default_options.width = nil
default_options.height = nil
ai_edit.setup(default_options)

-- Default sizing, upper placement, source gap, centering, inset, and focus.
do
  local buffer = open_file('default-layout.lua', { 'default layout' })
  local frame, input = invoke_at(buffer, 5, 41)
  local frame_config = vim.api.nvim_win_get_config(frame)
  local input_config = vim.api.nvim_win_get_config(input)
  equal({ frame_config.width, frame_config.height }, { 40, 4 }, 'default frame dimensions differ')
  equal({ frame_config.row, frame_config.col }, { 6, 19 }, 'upper-half frame placement differs')
  equal({ input_config.row, input_config.col }, { 8, 21 }, 'input inset differs')
  equal({ input_config.width, input_config.height }, { 38, 2 }, 'input dimensions differ')
  equal(vim.api.nvim_get_current_win(), input, 'input float was not focused')
  equal(frame_config.row - (5 - 1), 2, 'frame lacks one clear row below source cursor')
  equal(frame_config.col + (frame_config.width + 2) / 2, 40, 'frame is not horizontally centered on source cursor')
  close_prompt()
end

-- Odd-width frames center their middle cell on the source cursor.
do
  vim.o.columns = 78
  local buffer = open_file('odd-width-layout.lua', { 'odd width layout' })
  local frame = invoke_at(buffer, 5, 40)
  local config = vim.api.nvim_win_get_config(frame)
  equal({ config.width, config.col }, { 39, 19 }, 'odd-width frame was not centered on source cursor')
  close_prompt()
  vim.o.columns = 80
end

-- Overrides and lower-half placement preserve the source gap.
do
  setup { width = 0.75, height = 0.5 }
  local buffer = open_file('overridden-layout.lua', { 'overridden layout' })
  local frame = invoke_at(buffer, 4, 41)
  local config = vim.api.nvim_win_get_config(frame)
  equal({ config.width, config.height }, { 60, 12 }, 'overridden frame dimensions differ')
  equal({ config.row, config.col }, { 5, 9 }, 'overridden frame placement differs')
  close_prompt()

  setup()
  buffer = open_file('lower-layout.lua', { 'lower layout' })
  frame = invoke_at(buffer, 20, 41)
  config = vim.api.nvim_win_get_config(frame)
  equal(config.row, 12, 'lower-half cursor did not place frame above')
  equal((20 - 1) - (config.row + config.height + 1), 2, 'frame lacks one clear row above source cursor')
  close_prompt()
end

-- If preferred side cannot hold configured height, fitting opposite side wins before shrinking.
do
  vim.o.lines = 24
  vim.o.cmdheight = 2
  setup { height = 0.4 }
  local buffer = open_file('opposite-side.lua', { 'opposite side fallback' })
  local frame = invoke_at(buffer, 12, 41)
  local config = vim.api.nvim_win_get_config(frame)
  equal({ config.row, config.height }, { 0, 8 }, 'prompt did not use fitting opposite side')
  close_prompt()
  vim.o.cmdheight = 1
  vim.o.lines = 25
  setup()
end

-- Narrow editors clamp the normal 20-column minimum to valid hard-minimum geometry.
do
  for columns = 18, 22 do
    vim.o.columns = columns
    local buffer = open_file('narrow-' .. columns .. '.lua', { 'narrow layout' })
    local frame, input = invoke_at(buffer, 4, math.floor(columns / 2) + 1)
    local frame_config = vim.api.nvim_win_get_config(frame)
    local input_config = vim.api.nvim_win_get_config(input)
    equal(frame_config.width, columns - 2, 'narrow frame width differs at ' .. columns .. ' columns')
    equal(input_config.width, columns - 4, 'narrow input width differs at ' .. columns .. ' columns')
    truthy(frame_config.col >= 0 and frame_config.col + frame_config.width + 2 <= columns, 'narrow frame escaped editor bounds')
    close_prompt()
  end
  vim.o.columns = 80
end

-- Centered cursors in 7-9 usable rows leave no side for the 3-row content shell and source gap.
do
  for usable_rows = 7, 9 do
    vim.o.lines = usable_rows + vim.o.cmdheight
    clear_notifications()
    local buffer = open_file('short-' .. usable_rows .. '.lua', { 'short layout' })
    local source_row = math.floor((usable_rows + 1) / 2)
    vim.fn.screenrow = function()
      return source_row
    end
    vim.fn.screencol = function()
      return 40
    end
    feed '<F8>'
    vim.fn.screenrow = original_screenrow
    vim.fn.screencol = original_screencol
    vim.wait(50)
    equal(prompt_count(), 0, 'no-side-fit geometry opened floats at ' .. usable_rows .. ' rows')
    equal(vim.api.nvim_get_current_buf(), buffer, 'no-side-fit geometry changed buffer focus')
    truthy(notified 'cannot fit', 'no-side-fit geometry warning missing')
  end
  vim.o.lines = 25
end

-- Unresolved source coordinates reject before creating either float.
do
  clear_notifications()
  local buffer = open_file('unresolved.lua', { 'unresolved cursor' })
  vim.fn.screenrow = function()
    return 0
  end
  vim.fn.screencol = function()
    return 0
  end
  feed '<F8>'
  vim.fn.screenrow = original_screenrow
  vim.fn.screencol = original_screencol
  vim.wait(50)
  equal(prompt_count(), 0, 'unresolved coordinates opened prompt floats')
  equal(vim.api.nvim_get_current_buf(), buffer, 'unresolved coordinates changed buffer focus')
  truthy(notified 'placement.*unavailable', 'unresolved-coordinate warning missing')
end

-- Autocmd-driven frame closure during focus transfer cannot orphan the input.
do
  clear_notifications()
  local buffer = open_file('open-race.lua', { 'close frame during open' })
  vim.api.nvim_create_autocmd('WinLeave', {
    once = true,
    callback = function()
      local frame = prompt_windows()
      if frame then
        vim.api.nvim_win_close(frame, true)
      end
    end,
  })
  vim.fn.screenrow = function()
    return 4
  end
  vim.fn.screencol = function()
    return 40
  end
  feed '<F8>'
  vim.fn.screenrow = original_screenrow
  vim.fn.screencol = original_screencol
  wait_for(function()
    return prompt_count() == 0
  end, 'frame closure during open leaked an owned float')
  equal(vim.api.nvim_get_current_buf(), buffer, 'frame closure during open changed target buffer')
  truthy(notified 'closed while opening', 'frame closure during open warning missing')
end

-- Either externally closed owned window tears down the complete prompt.
do
  local buffer = open_file('external-frame.lua', { 'external frame close' })
  local frame = invoke_at(buffer, 4, 40)
  vim.api.nvim_win_close(frame, true)
  wait_for(function()
    return prompt_count() == 0
  end, 'external frame close leaked input float')

  buffer = open_file('external-input.lua', { 'external input close' })
  local _, input = invoke_at(buffer, 4, 40)
  vim.api.nvim_win_close(input, true)
  wait_for(function()
    return prompt_count() == 0
  end, 'external input close leaked frame float')
end

local function set_prompt(input, text)
  local lines = vim.split(text, '\n', { plain = true })
  if #lines == 0 then
    lines = { '' }
  end
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(input), 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(input, { #lines, #lines[#lines] })
end

local function accept(buffer, instruction)
  local existing_prompts = prompt_count()
  local _, input = invoke_at(buffer, 4, 40)
  set_prompt(input, instruction)
  feed '<CR>'
  wait_for(function()
    return prompt_count() == existing_prompts and ai_edit.statusline() ~= ''
  end, 'accepted instruction did not start a job')
  ai_edit.cancel(buffer)
  wait_for(function()
    return ai_edit.statusline() == ''
  end, 'cancelled history fixture job did not finish')
end

-- Cancelled, whitespace-only, and stale-target instructions never enter history.
do
  local buffer = open_file('excluded-cancel.lua', { 'cancelled input' })
  local _, input = invoke_at(buffer, 4, 40)
  set_prompt(input, 'excluded cancelled')
  close_prompt()

  buffer = open_file('excluded-whitespace.lua', { 'whitespace input' })
  _, input = invoke_at(buffer, 4, 40)
  set_prompt(input, '   \n  ')
  feed '<CR>'
  equal(prompt_count(), 2, 'whitespace-only input closed prompt')
  close_prompt()

  buffer = open_file('excluded-stale.lua', { 'snapshot' })
  _, input = invoke_at(buffer, 4, 40)
  set_prompt(input, 'excluded stale')
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'changed while prompting' })
  feed '<CR>'
  wait_for(function()
    return prompt_count() == 0
  end, 'stale-target submission leaked prompt floats')
  truthy(notified 'changed while prompt', 'stale-target rejection warning missing')
end

-- Cross-buffer order, exact multiline recall, bounds, arrows, and draft restoration.
local first_buffer = open_file('history-first.lua', { 'first target' })
accept(first_buffer, 'first accepted')
local second_buffer = open_file('history-second.lua', { 'second target' })
accept(second_buffer, 'second accepted\nsecond line')

do
  local buffer = open_file('history-navigation.lua', { 'navigation target' })
  local _, input = invoke_at(buffer, 4, 40)
  set_prompt(input, 'draft text\ndraft tail')
  feed '<C-p>'
  equal(prompt_text(input), 'second accepted\nsecond line', '<C-p> did not recall newest exact multiline instruction')
  equal(vim.api.nvim_win_get_cursor(input), { 2, #'second line' - 1 }, 'history recall cursor was not at input end')
  feed '<C-p>'
  equal(prompt_text(input), 'first accepted', 'second <C-p> did not recall older instruction')
  feed '<C-p>'
  equal(prompt_text(input), 'first accepted', 'older bound moved past oldest instruction')
  feed '<C-n>'
  equal(prompt_text(input), 'second accepted\nsecond line', '<C-n> did not recall newer instruction')
  feed '<C-n>'
  equal(prompt_text(input), 'draft text\ndraft tail', '<C-n> did not restore exact multiline draft')
  feed '<C-n>'
  equal(prompt_text(input), 'draft text\ndraft tail', 'newer bound changed restored draft')

  feed '<C-p>'
  vim.api.nvim_win_set_cursor(input, { 2, 2 })
  feed '<Up>'
  equal(prompt_text(input), 'second accepted\nsecond line', 'non-boundary <Up> started history navigation')
  equal(vim.api.nvim_win_get_cursor(input)[1], 1, 'non-boundary <Up> did not move natively')
  feed '<Up>'
  equal(prompt_text(input), 'first accepted', 'first-line <Up> did not recall older instruction')
  feed '<Down>'
  equal(prompt_text(input), 'second accepted\nsecond line', 'last-line <Down> did not recall newer instruction')
  vim.api.nvim_win_set_cursor(input, { 1, 2 })
  feed '<Down>'
  equal(prompt_text(input), 'second accepted\nsecond line', 'non-boundary <Down> changed history entry')
  equal(vim.api.nvim_win_get_cursor(input)[1], 2, 'non-boundary <Down> did not move natively')
  feed '<Down>'
  equal(prompt_text(input), 'draft text\ndraft tail', 'last-line <Down> did not restore draft')
  close_prompt()
end

-- Active navigation uses an immutable snapshot, then refreshes after draft restoration.
do
  local mutation_buffer = open_file('history-mutation.lua', { 'mutation target' })
  local mutation_window = vim.api.nvim_get_current_win()
  vim.cmd 'vsplit'
  local navigation_window = vim.api.nvim_get_current_win()
  local navigation_buffer = open_file('history-snapshot.lua', { 'snapshot target' })
  local _, navigation_input = invoke_at(navigation_buffer, 4, 40)
  set_prompt(navigation_input, 'snapshot draft')
  feed '<C-p>'
  equal(prompt_text(navigation_input), 'second accepted\nsecond line', 'snapshot navigation did not start at newest instruction')

  vim.api.nvim_set_current_win(mutation_window)
  accept(mutation_buffer, 'third accepted')
  vim.api.nvim_set_current_win(navigation_input)
  feed '<C-p>'
  equal(prompt_text(navigation_input), 'first accepted', 'concurrent history append shifted active snapshot')
  feed '<C-n>'
  equal(prompt_text(navigation_input), 'second accepted\nsecond line', 'active snapshot skipped after concurrent append')
  feed '<C-n>'
  equal(prompt_text(navigation_input), 'snapshot draft', 'active snapshot did not restore its draft')
  feed '<C-p>'
  equal(prompt_text(navigation_input), 'third accepted', 'fresh navigation snapshot omitted concurrent append')
  close_prompt()

  vim.api.nvim_set_current_win(navigation_window)
  vim.cmd 'only'
end

-- Adding a 101st accepted instruction evicts only the oldest entry.
do
  local buffer = open_file('history-eviction.lua', { 'eviction target' })
  for index = 1, 98 do
    accept(buffer, string.format('eviction %03d', index))
  end

  local _, input = invoke_at(buffer, 4, 40)
  feed '<C-p>'
  equal(prompt_text(input), 'eviction 098', 'history lost newest entry at capacity')
  for _ = 2, 100 do
    feed '<C-p>'
  end
  equal(prompt_text(input), 'second accepted\nsecond line', '101st entry did not evict exactly oldest instruction')
  feed '<C-p>'
  equal(prompt_text(input), 'second accepted\nsecond line', 'bounded history moved before retained oldest instruction')
  feed '<C-n>'
  equal(prompt_text(input), 'third accepted', 'retained history ordering changed after eviction')
  close_prompt()
end

vim.fn.screenrow = original_screenrow
vim.fn.screencol = original_screencol
vim.o.columns = original_columns
vim.o.lines = original_lines
vim.o.cmdheight = original_cmdheight
vim.fn.delete(root, 'rf')
print 'prompt ai_edit assertions passed'
