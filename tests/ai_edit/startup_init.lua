vim.opt.runtimepath:prepend(vim.fn.getcwd())
require('vichr.ai_edit').setup()
vim.cmd 'qa'
