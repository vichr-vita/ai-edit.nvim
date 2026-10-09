local reports = {}
local original_health = vim.health
vim.health = {}
for _, level in ipairs { 'start', 'ok', 'info', 'warn', 'error' } do
  vim.health[level] = function(message)
    table.insert(reports, level .. ': ' .. message)
  end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local log = root .. '/fake.log'
vim.env.AI_EDIT_FAKE_LOG = log
local function check(command)
  reports = {}
  require('ai_edit').setup { command = command, config_dir = root .. '/pi-config', keymap = '<F8>' }
  require('ai_edit.health').check()
  return table.concat(reports, '\n')
end

local value = check(assert(vim.env.AI_EDIT_FAKE_COMMAND))
assert(value:match 'ok: Neovim', value)
assert(value:match 'ok: Darwin is supported' or value:match 'ok: Linux is supported', value)
assert(value:match 'ok: Pi executable:', value)
assert(value:find(root .. '/pi-config', 1, true), value)
assert(vim.fn.filereadable(log) == 0, 'health launched Pi')
value = check(root .. '/missing-pi')
assert(value:match 'Pi executable not found', value)

vim.health = original_health
vim.fn.delete(root, 'rf')
print 'health ai_edit assertions passed'
