vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ai_edit = require 'ai_edit'
for _, name in ipairs { 'setup', 'cancel', 'statusline', 'statusline_color' } do
  assert(type(ai_edit[name]) == 'function', 'missing public function: ' .. name)
end
ai_edit.setup()
assert(type(ai_edit.statusline()) == 'string', 'statusline is not callable')
assert(type(ai_edit.statusline_color()) == 'table', 'statusline_color is not callable')
ai_edit.cancel()
assert(#vim.api.nvim_get_runtime_file('lua/ai_edit/stage_text.ts', false) == 1, 'trusted helper source is unavailable')
vim.cmd 'qa'
