local M = {}

local health_state = require 'ai_edit.health_state'

function M.check()
  vim.health.start 'AI edit'

  if vim.fn.has 'nvim-0.11' == 1 then
    local version = vim.version()
    vim.health.ok(('Neovim %d.%d.%d is supported'):format(version.major, version.minor, version.patch))
  else
    vim.health.error 'Neovim 0.11 or newer is required'
  end

  local system = (vim.uv or vim.loop).os_uname().sysname
  if system == 'Darwin' or system == 'Linux' then
    vim.health.ok(system .. ' is supported')
  else
    vim.health.error(system .. ' is unsupported; AI edit supports macOS and Linux')
  end

  local resolved = vim.fn.exepath(health_state.command)
  if resolved == '' then
    vim.health.error('Pi executable not found: ' .. health_state.command)
  else
    vim.health.ok('Pi executable: ' .. resolved)
  end
  vim.health.info('Dedicated Pi configuration: ' .. health_state.config_dir)
  vim.health.info 'Set a model and credentials in this directory, or use provider API-key environment variables.'
  vim.health.info 'Pi runs headlessly with one code-only prompt, an attached buffer snapshot, and no tools or saved sessions.'
end

return M
