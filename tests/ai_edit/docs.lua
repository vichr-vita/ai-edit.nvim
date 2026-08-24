local function fail(message)
  error(message, 2)
end

local function truthy(value, message)
  if not value then
    fail(message)
  end
end

local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read '*a'
  file:close()
  return value
end

local root = vim.fn.tempname()
local doc = root .. '/doc'
vim.fn.mkdir(doc, 'p')
assert((vim.uv or vim.loop).fs_copyfile('doc/ai-edit.txt', doc .. '/ai-edit.txt'))
vim.cmd('helptags ' .. vim.fn.fnameescape(doc))

local tags = read(doc .. '/tags')
for _, tag in ipairs {
  'ai-edit',
  'ai-edit-setup',
  'ai-edit-options',
  'ai-edit-mappings',
  'ai-edit-commands',
  ':AIEditCancel',
  'ai-edit-statusline',
  'ai-edit-health',
  'ai-edit-security',
  'ai-edit-troubleshooting',
} do
  truthy(tags:match('^' .. vim.pesc(tag) .. '\t') or tags:match('\n' .. vim.pesc(tag) .. '\t'), 'missing help tag: ' .. tag)
end

local readme = read 'README.md'
local help = read 'doc/ai-edit.txt'
for _, text in ipairs { readme, help } do
  truthy(not text:match 'vichr%.ai_edit', 'documentation contains private module')
  truthy(not text:match 'Kickstart', 'documentation contains stale Kickstart content')
  for _, name in ipairs {
    'keymap',
    'command',
    'model',
    'variant',
    'timeout_ms',
    'cleanup_timeout_ms',
    'max_bytes',
    'width',
    'height',
    'status.text',
    'status.color',
    'status.interval_ms',
    'status.frames',
  } do
    truthy(text:find(name, 1, true), 'documentation omits option: ' .. name)
  end
  truthy(text:find('>=1.18.21 <2.0.0', 1, true), 'documentation omits OpenCode range')
  truthy(text:find('Neovim 0.11', 1, true), 'documentation omits Neovim boundary')
end

local ai_edit = require 'ai_edit'
ai_edit.setup {
  keymap = '<F8>',
  command = 'opencode',
  status = { color = '#d946ef' },
}
truthy(type(ai_edit.statusline()) == 'string', 'documented statusline example fails')
truthy(ai_edit.statusline_color().fg == '#d946ef', 'documented statusline color example fails')

vim.fn.delete(root, 'rf')
print 'documentation ai_edit assertions passed'
