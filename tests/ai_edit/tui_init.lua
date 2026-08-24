vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
vim.opt.shortmess:append 'I'

require('vichr.ai_edit').setup {
  keymap = '<F8>',
  command = vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts',
  timeout_ms = 10000,
  cleanup_timeout_ms = 300,
  max_bytes = 1024 * 1024,
  width = 0.6,
  height = 0.3,
}
