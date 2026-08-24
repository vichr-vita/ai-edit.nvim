local M = {}

local health_state = require 'ai_edit.health_state'
local version_policy = require 'ai_edit.version'

local function inspect_version(command)
  local root = vim.fn.tempname()
  local environment = vim.fn.environ()
  for key in pairs(environment) do
    if key:match '^OPENCODE_' then
      environment[key] = nil
    end
  end
  for _, name in ipairs { 'home', 'config', 'cache', 'data', 'state' } do
    vim.fn.mkdir(root .. '/' .. name, 'p', tonumber('700', 8))
  end
  environment.HOME = root .. '/home'
  environment.XDG_CONFIG_HOME = root .. '/config'
  environment.XDG_CACHE_HOME = root .. '/cache'
  environment.XDG_DATA_HOME = root .. '/data'
  environment.XDG_STATE_HOME = root .. '/state'
  environment.OPENCODE_TEST_HOME = root .. '/home'

  local started, process = pcall(vim.system, { command, '--version' }, { text = true, env = environment })
  if not started then
    vim.fn.delete(root, 'rf')
    return nil, tostring(process)
  end
  local waited, result = pcall(process.wait, process, 5000)
  vim.fn.delete(root, 'rf')
  if not waited then
    return nil, tostring(result)
  end
  return result
end

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

  local command = health_state.command
  local resolved = vim.fn.exepath(command)
  if resolved == '' then
    vim.health.error(('OpenCode executable not found: %s; install OpenCode %s or configure command'):format(command, version_policy.range))
  else
    vim.health.ok('OpenCode executable: ' .. resolved)
    local result, inspect_error = inspect_version(resolved)
    if not result then
      vim.health.error('Could not inspect OpenCode version: ' .. inspect_error)
    elseif result.code ~= 0 then
      vim.health.error(('OpenCode --version failed; supported range is %s: %s'):format(version_policy.range, vim.trim(result.stderr or '')))
    else
      local version = vim.trim(result.stdout or '')
      if version_policy.supported(version) then
        vim.health.ok('OpenCode version ' .. version .. ' is supported')
      else
        vim.health.error(('OpenCode version %s is unsupported; required range is %s'):format(version == '' and '<empty>' or version, version_policy.range))
      end
    end
  end

  vim.health.info 'Provider, model, and credentials are not inspected; confirm they are configured before editing.'
  vim.health.info 'First use for each OpenCode version needs network access to install the exact matching @opencode-ai/plugin; a verified helper cache supports later offline use.'
  vim.health.warn 'Project reads are not an operating-system sandbox. Run AI edit only in trusted worktrees; in-project symlinks can expose outside files.'
end

return M
