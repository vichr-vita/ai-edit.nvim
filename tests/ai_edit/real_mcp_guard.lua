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

vim.cmd('silent edit ' .. vim.fn.fnameescape(target))
local buffer = vim.api.nvim_get_current_buf()
local before = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

require('vichr.ai_edit').setup {
  keymap = '<F8>',
  command = command,
  timeout_ms = 15000,
  cleanup_timeout_ms = 1000,
}

feed '<F8>'
assert(
  vim.wait(2000, function()
    return vim.api.nvim_get_current_buf() ~= buffer and vim.bo.buftype == 'nofile'
  end, 10),
  'managed MCP guard prompt did not open'
)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'must abort before managed MCP starts' })
feed '<CR>'

assert(
  vim.wait(15000, function()
    for _, message in ipairs(notifications) do
      if message:lower():match 'mcp' then
        return true
      end
    end
    return false
  end, 10),
  'managed MCP configuration was not rejected: ' .. vim.inspect(notifications)
)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), before), 'managed MCP rejection changed buffer')
print 'installed OpenCode managed MCP guard passed'
