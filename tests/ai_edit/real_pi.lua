local root = assert(vim.env.AI_EDIT_REAL_ROOT)
local ai_edit = require 'ai_edit'
local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end
vim.o.columns = 120
vim.o.lines = 40
ai_edit.setup {
  keymap = '<F8>',
  command = vim.env.AI_EDIT_REAL_PI or 'pi',
  config_dir = root .. '/config',
  timeout_ms = 30000,
}

local function edit(path, lines, visual)
  notifications = {}
  vim.fn.writefile({ 'disk sentinel' }, path, 'b')
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  if visual then
    vim.cmd('normal! ' .. visual)
  end
  vim.api.nvim_feedkeys(vim.keycode '<F8>', 'xt', false)
  assert(vim.b.ai_edit_prompt, 'prompt did not open')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'Make the requested edit.' })
  vim.api.nvim_feedkeys(vim.keycode '<CR>', 'xt', false)
  assert(
    vim.wait(35000, function()
      return ai_edit.statusline() == ''
    end, 10),
    'Pi run timed out'
  )
  assert(table.concat(notifications, '\n'):find('buffer changed', 1, true), vim.inspect(notifications))
  assert(vim.bo[buffer].modifiable and vim.bo[buffer].modified, 'result was not unsaved and writable')
  assert(vim.fn.readfile(path)[1] == 'disk sentinel', 'Pi wrote source file')
  return buffer
end

local buffer = edit(root .. '/project/whole.lua', { "return 'unsaved snapshot'" })
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { "return 'from Pi'" }))
vim.api.nvim_set_current_buf(buffer)
vim.cmd 'undo'
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { "return 'unsaved snapshot'" }))

buffer = edit(root .. '/project/selection.lua', { 'alpha beta omega' }, '0wv3l')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'alpha BETA omega' }))
print 'installed Pi whole-buffer and selection assertions passed'
