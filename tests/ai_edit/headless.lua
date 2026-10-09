local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or 'values differ') .. '\nexpected: ' .. vim.inspect(expected) .. '\nactual: ' .. vim.inspect(actual))
end

local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/config', 'p', tonumber('700', 8))
vim.o.columns = 120
vim.o.lines = 40
vim.env.AI_EDIT_FAKE_LOG = root .. '/fake.log'
local ai_edit = require 'ai_edit'
local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read '*a'
  file:close()
  return value
end

local function setup(overrides)
  ai_edit.setup(vim.tbl_extend('force', {
    keymap = '<F8>',
    command = assert(vim.env.AI_EDIT_FAKE_COMMAND),
    config_dir = root .. '/config',
    model = false,
    thinking = 'off',
    timeout_ms = 10000,
    max_bytes = 1024 * 1024,
  }, overrides or {}))
end

local function open_file(name, lines)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      vim.api.nvim_win_close(win, true)
    end
  end
  local path = root .. '/' .. name
  vim.fn.writefile(lines, path, 'b')
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  return vim.api.nvim_get_current_buf(), path
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function edit(buffer, instruction, visual)
  notifications = {}
  vim.api.nvim_set_current_buf(buffer)
  if visual then
    vim.cmd('normal! ' .. visual)
  end
  feed '<F8>'
  assert(vim.b.ai_edit_prompt, 'prompt did not open: ' .. vim.inspect(notifications))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(instruction, '\n', { plain = true }))
  feed '<CR>'
  assert(
    vim.wait(15000, function()
      return ai_edit.statusline() == ''
    end, 10),
    'edit did not finish: ' .. vim.inspect(notifications)
  )
  assert(vim.bo[buffer].modifiable, 'target stayed locked')
end

local function last_run()
  local entries = vim.fn.readfile(vim.env.AI_EDIT_FAKE_LOG)
  return vim.json.decode(entries[#entries])
end

local function success()
  assert(table.concat(notifications, '\n'):find('buffer changed', 1, true), vim.inspect(notifications))
end

setup()
vim.env.AI_EDIT_FAKE_SCENARIO = 'success'
local buffer, path = open_file('whole.lua', { 'disk contents' })
local before = { 'local café = "Příliš"', 'return café' }
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, before)
vim.env.AI_EDIT_FAKE_RESULT = 'local café = "žluťoučký"\nreturn café\n'
edit(buffer, 'replace the literal')
success()
equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'local café = "žluťoučký"', 'return café' })
equal(read(path), 'disk contents', 'edit wrote the source file')
assert(vim.bo[buffer].modified, 'result was saved')
vim.api.nvim_set_current_buf(buffer)
vim.cmd 'undo'
equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), before, 'one undo lost unsaved input')
equal(last_run().targetInput, table.concat(before, '\n'), 'reference used disk contents')
equal(vim.fn.isdirectory(last_run().cwd), 0, 'successful staging leaked')
vim.env.AI_EDIT_FAKE_RESULT = nil

buffer = open_file('selection.lua', { 'alpha beta omega' })
edit(buffer, 'characterwise replacement', '0wv3l')
success()
equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'alpha BETA omega' })
equal(last_run().targetInput, 'alpha beta omega', 'selection lacked full buffer context')
assert(last_run().request:find('"beta"', 1, true), 'request omitted exact selection')

buffer = open_file('lines.lua', { 'one', 'two', 'three', 'four' })
edit(buffer, 'linewise replacement', '2GVj')
success()
equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'one', 'TWO', 'THREE', 'four' })

buffer = open_file('delete.lua', { 'remove this' })
edit(buffer, 'delete the code')
success()
equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { '' }, 'empty replacement was rejected')

vim.env.AI_EDIT_FAKE_SCENARIO = 'no-op'
buffer = open_file('noop.lua', { 'return true' })
edit(buffer, 'preserve this')
assert(not vim.bo[buffer].modified, 'unchanged response marked target modified')
assert(table.concat(notifications, '\n'):find('no changes', 1, true), vim.inspect(notifications))

-- Dedicated model defaults survive, while user and project resources stay excluded.
vim.fn.writefile({
  vim.json.encode {
    defaultProvider = 'test-provider',
    defaultModel = 'local-model',
    defaultThinkingLevel = 'high',
    defaultTools = { 'bash' },
    extensions = { 'untrusted-extension.ts' },
    packages = { 'npm:untrusted' },
    retry = { enabled = true },
    compaction = { enabled = true },
  },
}, root .. '/config/settings.json')
vim.fn.writefile({ '{}' }, root .. '/config/auth.json')
vim.fn.writefile({ '{}' }, root .. '/config/models.json')
vim.fn.writefile({ 'HOSTILE_USER_INSTRUCTIONS' }, root .. '/config/AGENTS.md')
vim.fn.writefile({ 'HOSTILE_PROJECT_INSTRUCTIONS' }, root .. '/AGENTS.md')
vim.fn.mkdir(root .. '/.pi', 'p')
vim.fn.writefile({ '{"defaultTools":["bash"]}' }, root .. '/.pi/settings.json')
vim.env.PI_CODING_AGENT_DIR = root .. '/wrong-config'
vim.env.AI_EDIT_FAKE_SCENARIO = 'success'
buffer = open_file('isolated.lua', { 'return false' })
edit(buffer, 'isolated model defaults')
success()
local run = last_run()
equal(run.settings.defaultProvider, 'test-provider')
equal(run.settings.defaultModel, 'local-model')
equal(run.settings.defaultThinkingLevel, 'off')
equal(run.settings.defaultTools, {})
equal(run.settings.retry.enabled, false)
equal(run.settings.compaction.enabled, false)
assert(run.settings.extensions == nil and run.settings.packages == nil, 'inherited extra resources')
equal(run.targetMode, tonumber('400', 8))
equal(run.rootMode, tonumber('700', 8))
equal(run.nvim, '')
equal(run.offline, '1')
equal(run.telemetry, '0')
for _, flag in ipairs {
  '--print',
  '--no-session',
  '--no-tools',
  '--no-extensions',
  '--no-skills',
  '--no-prompt-templates',
  '--no-themes',
  '--no-context-files',
  '--no-approve',
  '--offline',
} do
  assert(vim.tbl_contains(run.args, flag), 'missing isolation flag: ' .. flag)
end
local prompt_index = vim.fn.index(run.args, '--system-prompt')
assert(prompt_index >= 0, 'missing code-only prompt')
local prompt = read(run.args[prompt_index + 2])
assert(prompt:find('Return only', 1, true) and prompt:find('Do not write tests or perform verification', 1, true))
assert(not run.request:find('HOSTILE_', 1, true), 'inherited extra instructions')

setup { model = 'test-provider/explicit', thinking = 'minimal' }
buffer = open_file('explicit.lua', { 'return false' })
edit(buffer, 'explicit model')
success()
run = last_run()
equal(run.args[vim.fn.index(run.args, '--model') + 2], 'test-provider/explicit')
equal(run.args[vim.fn.index(run.args, '--thinking') + 2], 'minimal')

-- A successful process must still provide one complete, bounded code response.
setup { max_bytes = 1024 }
for _, scenario in ipairs {
  'nonzero',
  'malformed',
  'missing-response',
  'duplicate-response',
  'truncated',
  'tool-call',
  'provider-error',
  'nul-output',
  'oversized-output',
} do
  vim.env.AI_EDIT_FAKE_SCENARIO = scenario
  buffer = open_file(scenario .. '.lua', { 'unchanged' })
  edit(buffer, scenario)
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'unchanged' }, scenario .. ' changed the target')
  assert(table.concat(notifications, '\n'):match 'Pi failed', scenario .. ' was accepted')
  equal(vim.fn.isdirectory(last_run().cwd), 0, scenario .. ' staging leaked')
end

vim.env.PI_CODING_AGENT_DIR = nil
vim.fn.delete(root, 'rf')
print 'headless Pi ai_edit assertions passed'
