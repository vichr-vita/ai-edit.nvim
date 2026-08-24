local function fail(message)
  error(message, 2)
end

local function truthy(value, message)
  if not value then
    fail(message)
  end
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(message .. '\nexpected: ' .. vim.inspect(expected) .. '\nactual: ' .. vim.inspect(actual))
  end
end

local project = assert(vim.env.AI_EDIT_HOSTILE_PROJECT)
local fake = vim.env.AI_EDIT_FAKE_COMMAND or (vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts')
local log_path = assert(vim.env.AI_EDIT_FAKE_LOG)
local notifications = {}
vim.notify = function(message)
  table.insert(notifications, tostring(message))
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function logs()
  local result = {}
  local file = io.open(log_path, 'rb')
  if not file then
    return result
  end
  for line in file:lines() do
    table.insert(result, vim.json.decode(line))
  end
  file:close()
  return result
end

local function count(kind)
  local total = 0
  for _, item in ipairs(logs()) do
    if item.kind == kind then
      total = total + 1
    end
  end
  return total
end

local function read_bytes(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read '*a'
  file:close()
  return value
end

local function setup()
  require('ai_edit').setup {
    keymap = '<F8>',
    command = fake,
    timeout_ms = 15000,
    max_bytes = 1024 * 1024,
  }
end

local function open_target(text)
  local path = project .. '/src/target.ts'
  vim.fn.writefile(vim.split(text, '\n', { plain = true }), path, 'b')
  vim.cmd('silent edit! ' .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo.modified = false
  return vim.api.nvim_get_current_buf()
end

local function submit(buffer, instruction)
  vim.api.nvim_set_current_buf(buffer)
  feed '<F8>'
  truthy(
    vim.wait(2000, function()
      return vim.api.nvim_get_current_buf() ~= buffer and vim.bo.buftype == 'nofile'
    end, 10),
    'hostile fixture prompt did not open'
  )
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { instruction })
  feed '<CR>'
end

setup()

-- Every managed unsafe resolution must abort before session creation.
for _, scenario in ipairs {
  'unsafe-managed',
  'unsafe-tiny-output',
  'unsafe-sharing',
  'unsafe-mcp',
  'unsafe-plugin',
  'unsafe-provider',
  'disabled-agent',
  'wrong-version',
} do
  notifications = {}
  vim.env.AI_EDIT_FAKE_SCENARIO = scenario
  local fixture_names = {
    ['unsafe-managed'] = 'unsafe-managed.json',
    ['unsafe-tiny-output'] = 'tiny-output-limit.json',
    ['unsafe-sharing'] = 'automatic-sharing.json',
    ['unsafe-mcp'] = 'enabled-local-mcp.json',
  }
  local fixture_name = fixture_names[scenario]
  vim.env.AI_EDIT_MANAGED_FIXTURE = fixture_name and (vim.fn.getcwd() .. '/tests/ai_edit/fixtures/managed/' .. fixture_name) or nil
  local runs = count 'run'
  local buffer = open_target 'unsafe must remain'
  submit(buffer, scenario)
  truthy(
    vim.wait(20000, function()
      for _, message in ipairs(notifications) do
        if message:lower():match 'unsafe' or message:lower():match 'config' or message:lower():match 'version' then
          return true
        end
      end
      return false
    end, 10),
    scenario .. ' was not rejected'
  )
  equal(count 'run', runs, scenario .. ' created session')
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'unsafe must remain' }, scenario .. ' changed target')
end

-- A fixture-driven stock apply_patch move stays denied while the allowed edit remains staged.
notifications = {}
vim.env.AI_EDIT_FAKE_SCENARIO = 'apply-patch-move'
vim.env.AI_EDIT_MANAGED_FIXTURE = nil
local original = 'PROJECT_TARGET_BYTES\nsecond line'
local buffer = open_target(original)
local project_target = project .. '/src/target.ts'
local original_bytes = read_bytes(project_target)
submit(buffer, 'attempt stock apply_patch move')
local move_attempt
truthy(
  vim.wait(20000, function()
    for _, item in ipairs(logs()) do
      if item.kind == 'apply-patch-move-attempt' then
        move_attempt = item
        return true
      end
    end
    return false
  end, 10),
  'apply_patch move fixture was not executed'
)
equal(move_attempt.fixtureTool, 'apply_patch', 'apply_patch fixture tool was not consumed')
truthy(move_attempt.fixturePatch:find('*** Move to: src/target.ts', 1, true), 'apply_patch fixture move was not consumed')
equal(move_attempt.source, 'staging/target.ts', 'apply_patch fixture source changed')
equal(move_attempt.moveTo, 'src/target.ts', 'apply_patch fixture destination changed')
equal(vim.uv.fs_realpath(move_attempt.destination), vim.uv.fs_realpath(project_target), 'move did not target project file')
equal(move_attempt.canApplyPatch, false, 'stock apply_patch move was executable')
local stage_root = assert(vim.uv.fs_realpath(move_attempt.root))
local stage_target = assert(vim.uv.fs_realpath(move_attempt.target))
truthy(stage_target:sub(1, #stage_root + 1) == stage_root .. '/', 'allowed edit escaped staging root')
truthy(vim.uv.fs_realpath(move_attempt.destination):sub(1, #stage_root + 1) ~= stage_root .. '/', 'hostile move destination unexpectedly remained in staging')
equal(move_attempt.projectBefore, original_bytes, 'project target bytes differed before move attempt')
equal(move_attempt.projectAfterAttempt, original_bytes, 'apply_patch move mutated project target bytes')
equal(read_bytes(project_target), original_bytes, 'project target changed while allowed edit was staged')
equal(move_attempt.stagedAfterAllowedEdit, 'hostile staged result\n', 'allowed edit did not reach staging target')
equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'PROJECT_TARGET_BYTES', 'second line' }, 'staged edit applied before validation')
truthy(
  vim.wait(20000, function()
    return vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { 'hostile staged result' })
  end, 10),
  'validated staged edit was not applied through Neovim'
)
equal(read_bytes(project_target), original_bytes, 'Neovim application wrote project target to disk')
equal(vim.fn.isdirectory(move_attempt.root), 0, 'apply_patch scenario leaked staging directory')

-- Project extensions and colliding disabled agent cannot affect unique runtime agent.
notifications = {}
vim.env.AI_EDIT_FAKE_SCENARIO = 'disabled-collision'
vim.env.AI_EDIT_MANAGED_FIXTURE = nil
local template = table.concat(vim.fn.readfile(assert(vim.env.AI_EDIT_LARGE_FIXTURE)), '\n')
local large = template:gsub('{{REPEAT_4000:line filler 0123456789}}', string.rep('line filler 0123456789\n', 4000))
buffer = open_target(large)
submit(buffer, 'tail exact replacement')
truthy(
  vim.wait(20000, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == 'EDITED_HEAD'
  end, 10),
  'safe hostile-fixture edit did not apply'
)
local result = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n')
truthy(result:find('LARGE_TAIL_MARKER', 1, true), 'large unread tail was truncated')

local run
for _, item in ipairs(logs()) do
  if item.kind == 'run' then
    run = item
  end
end
truthy(run, 'hostile safe run missing')
local agent_index = vim.fn.index(run.args, '--agent')
truthy(agent_index >= 0, 'dynamic agent flag missing')
truthy(run.args[agent_index + 2] ~= 'colliding-agent', 'runtime agent collided with disabled project agent')
equal(run.config.share, 'disabled', 'sharing not disabled')
equal(run.config.snapshot, false, 'snapshots not disabled')
equal(run.config.formatter, false, 'formatters not disabled')
equal(run.config.lsp, false, 'LSP not disabled')
equal(run.config.tools.apply_patch, false, 'apply_patch move capability not disabled')
equal(run.config.tools.edit, false, 'stock edit capability not disabled')
equal(run.config.tools.write, false, 'stock write capability not disabled')
equal(vim.uv.fs_realpath(run.cwd), vim.uv.fs_realpath(project), 'run did not use nearest Git root')
equal(run.externalSymlinkInput, 'EXTERNAL_SYMLINK_SENTINEL\n', 'trusted-worktree symlink read boundary changed')

-- Hostile project files and external symlink remain readable context, never mutation destinations.
equal(vim.fn.filereadable(project .. '/PLUGIN_EXECUTED'), 0, 'project plugin executed')
equal(vim.fn.filereadable(project .. '/TOOL_EXECUTED'), 0, 'project tool executed')
equal(vim.fn.filereadable(project .. '/FORMATTER_EXECUTED'), 0, 'formatter command executed')
equal(vim.fn.filereadable(project .. '/LSP_EXECUTED'), 0, 'LSP command executed')
equal(vim.fn.filereadable(project .. '/MOVED_BY_APPLY_PATCH'), 0, 'apply_patch moved staging into project')
local external_target = assert(vim.env.AI_EDIT_EXTERNAL_TARGET)
equal(table.concat(vim.fn.readfile(external_target), '\n'), 'EXTERNAL_SYMLINK_SENTINEL', 'external symlink target mutated')
truthy(vim.uv.fs_realpath(project .. '/src/external-link.txt') == vim.uv.fs_realpath(external_target), 'external symlink fixture invalid')

print 'hostile ai_edit assertions passed'
