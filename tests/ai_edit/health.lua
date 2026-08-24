local function fail(message)
  error(message, 2)
end

local function truthy(value, message)
  if not value then
    fail(message)
  end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p', tonumber('700', 8))
local fake = vim.env.AI_EDIT_FAKE_COMMAND or (vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts')
local log = root .. '/fake.log'
local user_cache = root .. '/user-cache'
vim.fn.mkdir(user_cache, 'p')
vim.env.XDG_CACHE_HOME = user_cache
vim.env.AI_EDIT_FAKE_LOG = log
vim.env.OPENCODE_CONFIG = root .. '/hostile-opencode.json'

local version_policy = require 'ai_edit.version'
for _, version in ipairs { '1.18.21', '1.18.22', '1.99.0' } do
  truthy(version_policy.supported(version), 'compatible version rejected: ' .. version)
end
for _, version in ipairs { '1.18.20', '2.0.0', '1.19.0-beta.1', '1.019.0', 'garbage', '' } do
  truthy(not version_policy.supported(version), 'unsupported version accepted: ' .. version)
end

local reports = {}
local original_health = vim.health
vim.health = {}
for _, level in ipairs { 'start', 'ok', 'info', 'warn', 'error' } do
  vim.health[level] = function(message)
    table.insert(reports, level .. ': ' .. message)
  end
end

local function output()
  return table.concat(reports, '\n')
end

local function check(command)
  reports = {}
  require('ai_edit').setup { command = command, keymap = '<F8>' }
  require('ai_edit.health').check()
  return output()
end

local value = check(fake)
truthy(value:match 'ok: Neovim', 'supported Neovim was not reported')
truthy(value:match 'ok: Darwin is supported' or value:match 'ok: Linux is supported', 'supported operating system was not reported')
truthy(value:match 'OpenCode version 1%.18%.21 is supported', 'exact OpenCode version was not accepted')
truthy(value:match 'Provider, model, and credentials are not inspected', 'provider guidance missing')
truthy(value:match 'First use for each OpenCode version needs network access', 'bootstrap guidance missing')
truthy(value:match 'trusted worktrees', 'worktree trust guidance missing')

local entries = {}
local file = assert(io.open(log, 'rb'))
for line in file:lines() do
  table.insert(entries, vim.json.decode(line))
end
file:close()
truthy(
  #entries == 2 and entries[1].kind == 'phase' and entries[1].phase == 'version' and entries[2].kind == 'version',
  'health executed more than OpenCode --version'
)
truthy(entries[2].xdgCacheHome ~= user_cache, 'health exposed user cache to OpenCode')
truthy(entries[2].opencodeConfig == nil, 'health inherited OpenCode configuration')
truthy(vim.fn.isdirectory(entries[2].xdgCacheHome) == 0, 'health leaked temporary OpenCode cache')
truthy(vim.tbl_isempty(vim.fn.readdir(user_cache)), 'health modified user cache')

value = check(root .. '/missing-opencode')
truthy(value:match 'OpenCode executable not found', 'missing executable was not reported')

local compatible = root .. '/compatible-opencode'
vim.fn.writefile({ '#!/bin/sh', "printf '1.99.0\\n'" }, compatible)
assert((vim.uv or vim.loop).fs_chmod(compatible, tonumber('700', 8)))
value = check(compatible)
truthy(value:match 'OpenCode version 1%.99%.0 is supported', 'higher compatible OpenCode version was rejected')

local unsupported = root .. '/unsupported-opencode'
vim.fn.writefile({ '#!/bin/sh', "printf '2.0.0\\n'" }, unsupported)
assert((vim.uv or vim.loop).fs_chmod(unsupported, tonumber('700', 8)))
value = check(unsupported)
truthy(value:match 'OpenCode version 2%.0%.0 is unsupported', 'OpenCode 2.0.0 was not rejected')
truthy(value:match '>=1%.18%.21 <2%.0%.0', 'supported version range guidance missing')

vim.health = original_health
vim.env.OPENCODE_CONFIG = nil
vim.fn.delete(root, 'rf')
print 'health ai_edit assertions passed'
