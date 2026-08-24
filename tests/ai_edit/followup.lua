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

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p', tonumber('700', 8))
vim.env.AI_EDIT_FAKE_LOG = vim.env.AI_EDIT_FAKE_LOG or (root .. '/fake.log')
vim.env.AI_EDIT_FAKE_SCENARIO = 'success'

local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
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

local function log_entries()
  local file = io.open(vim.env.AI_EDIT_FAKE_LOG, 'rb')
  if not file then
    return {}
  end
  local entries = {}
  for line in file:lines() do
    table.insert(entries, vim.json.decode(line))
  end
  file:close()
  return entries
end

local function count_runs()
  local count = 0
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'run' then
      count = count + 1
    end
  end
  return count
end

local function run_for_instruction(instruction)
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'run' and entry.instruction == instruction then
      return entry
    end
  end
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function wait_for(predicate, message)
  if not vim.wait(20000, predicate, 10) then
    fail(message .. '\nnotifications: ' .. vim.inspect(notifications) .. '\nfake log: ' .. vim.inspect(log_entries()))
  end
end

local function open_file(name, lines)
  local path = root .. '/' .. name
  vim.fn.writefile(lines, path, 'b')
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  vim.bo.binary = false
  vim.bo.readonly = false
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  return vim.api.nvim_get_current_buf()
end

local function open_prompt(buffer)
  vim.api.nvim_set_current_buf(buffer)
  feed '<F8>'
  wait_for(function()
    return vim.api.nvim_get_current_buf() ~= buffer and vim.bo.buftype == 'nofile'
  end, 'prompt did not open')
  return vim.api.nvim_get_current_buf()
end

local function submit(prompt, instruction)
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { instruction })
  feed '<CR>'
end

require('ai_edit').setup {
  keymap = '<F8>',
  command = vim.env.AI_EDIT_FAKE_COMMAND or (vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts'),
  timeout_ms = 15000,
  cleanup_timeout_ms = 500,
  max_bytes = 1024 * 1024,
  width = 0.6,
  height = 0.3,
}

local case = assert(vim.env.AI_EDIT_FOLLOWUP_CASE, 'missing AI_EDIT_FOLLOWUP_CASE')

if case == 'visual-mutation' then
  local buffer = open_file('prompt-stale-visual.lua', { 'alpha beta omega' })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.cmd 'normal! v3l'
  local prompt = open_prompt(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'user alpha beta omega' })
  local runs = count_runs()
  submit(prompt, 'reject changed visual target')
  wait_for(function()
    return notified 'stale|changed|modified' or count_runs() > runs
  end, 'visual target mutation produced no terminal response')
  equal(count_runs(), runs, 'visual target mutation started OpenCode')
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'user alpha beta omega' }, 'visual target mutation was overwritten')
elseif case == 'short-write' then
  local buffer = open_file('short-write.lua', { 'complete staging snapshot survives short writes' })
  local prompt = open_prompt(buffer)
  local original_write = vim.uv.fs_write
  local short_writes = 0
  vim.uv.fs_write = function(fd, data, offset)
    if type(data) == 'string' and #data > 1 then
      short_writes = short_writes + 1
      data = data:sub(1, math.max(1, math.floor(#data / 2)))
    end
    return original_write(fd, data, offset)
  end
  submit(prompt, 'short positive writes')
  wait_for(function()
    return run_for_instruction 'short positive writes' ~= nil
  end, 'short-write run did not start')
  vim.uv.fs_write = original_write
  local run = run_for_instruction 'short positive writes'
  truthy(short_writes > 1, 'staging write did not retry a short positive write')
  equal(run.targetInput, 'complete staging snapshot survives short writes', 'short writes truncated staging snapshot')
elseif case == 'fsync-error' then
  local buffer = open_file('fsync-error.lua', { 'preserve after fsync failure' })
  local prompt = open_prompt(buffer)
  local original_fsync = vim.uv.fs_fsync
  local fsync_calls = 0
  vim.uv.fs_fsync = function()
    fsync_calls = fsync_calls + 1
    return nil, 'injected fsync failure'
  end
  local runs = count_runs()
  submit(prompt, 'fsync failure')
  vim.uv.fs_fsync = original_fsync
  wait_for(function()
    return notified 'fsync|sync|write|staging|failure|failed' or count_runs() > runs
  end, 'fsync failure produced no terminal response')
  truthy(fsync_calls > 0, 'staging write did not fsync')
  equal(count_runs(), runs, 'fsync failure started OpenCode')
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'preserve after fsync failure' }, 'fsync failure changed buffer')
elseif case == 'bootstrap' then
  local buffer = open_file('bootstrap.lua', { 'concurrent bootstrap' })
  local prompt = open_prompt(buffer)
  local original_rename = vim.uv.fs_rename
  local helper_build_mode
  vim.uv.fs_rename = function(source, destination)
    if source:match '/%.helper%-build%-' then
      helper_build_mode = assert(vim.uv.fs_stat(source)).mode
    end
    return original_rename(source, destination)
  end
  submit(prompt, 'bootstrap publication')
  wait_for(function()
    return vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'normal result' })
  end, 'bootstrap run did not complete')
  vim.uv.fs_rename = original_rename
  truthy(helper_build_mode and bit.band(helper_build_mode, tonumber('200', 8)) ~= 0, 'helper build root was read-only before publication')
else
  fail('unknown follow-up case: ' .. case)
end

vim.fn.delete(root, 'rf')
print('follow-up ai_edit assertion passed: ' .. case)
