vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
vim.opt.shortmess:append 'I'

require('ai_edit').setup {
  keymap = '<F8>',
  config_dir = vim.fs.dirname(assert(vim.env.AI_EDIT_FAKE_LOG)) .. '/pi-config',
  command = vim.env.AI_EDIT_FAKE_COMMAND or (vim.fn.getcwd() .. '/tests/ai_edit/fake_pi.ts'),
  timeout_ms = 30000,
  max_bytes = 1024 * 1024,
  width = 0.6,
  height = 0.3,
}
