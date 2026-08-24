local function fail(message)
  error(message, 2)
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail((message or 'values differ') .. '\nexpected: ' .. vim.inspect(expected) .. '\nactual: ' .. vim.inspect(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or 'expected truthy value')
  end
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p', tonumber('700', 8))
local fake = vim.fn.getcwd() .. '/tests/ai_edit/fake_opencode.ts'
local log_path = root .. '/fake.log'
vim.env.AI_EDIT_FAKE_LOG = log_path
vim.env.AI_EDIT_GLOBAL_MODEL = 'test-provider/inherited-model'
vim.env.AI_EDIT_GLOBAL_PROVIDER = vim.json.encode { ['test-provider'] = { options = { inherited = true } } }

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = tostring(message), level = level })
end

local function notified(pattern)
  for _, item in ipairs(notifications) do
    for alternative in pattern:gmatch '[^|]+' do
      if item.message:lower():match(alternative:lower()) then
        return true
      end
    end
  end
  return false
end

local function clear_notifications()
  notifications = {}
end

local function read_file(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read '*a'
  file:close()
  return value
end

local function log_entries()
  local file = io.open(log_path, 'rb')
  if not file then
    return {}
  end
  local entries = {}
  for line in file:lines() do
    table.insert(entries, vim.json.decode(line))
  end
  file:close()
  return entries
end

local function count_log(kind)
  local count = 0
  for _, entry in ipairs(log_entries()) do
    if entry.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function count_scenario_log(kind, scenario)
  local count = 0
  for _, entry in ipairs(log_entries()) do
    if entry.kind == kind and entry.scenario == scenario then
      count = count + 1
    end
  end
  return count
end

local function write_file(path, text)
  vim.fn.writefile(vim.split(text, '\n', { plain = true }), path, 'b')
end

local function open_file(name, lines)
  local path = root .. '/' .. name
  write_file(path, table.concat(lines, '\n'))
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  vim.bo.binary = false
  vim.bo.readonly = false
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  return vim.api.nvim_get_current_buf(), path
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
end

local function wait_for(predicate, message, timeout)
  truthy(vim.wait(timeout or 20000, predicate, 10), message)
end

local function prompt_opened(original)
  return vim.api.nvim_get_current_buf() ~= original and vim.bo.buftype == 'nofile'
end

local function invoke_normal(buffer, instruction)
  vim.api.nvim_set_current_buf(buffer)
  feed '<F8>'
  wait_for(function()
    return prompt_opened(buffer)
  end, 'normal invocation did not open prompt')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(instruction, '\n', { plain = true }))
  feed '<CR>'
end

local function invoke_visual(buffer, command, instruction)
  vim.api.nvim_set_current_buf(buffer)
  vim.cmd('normal! ' .. command)
  feed '<F8>'
  wait_for(function()
    return prompt_opened(buffer)
  end, 'visual invocation did not open prompt')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { instruction })
  feed '<CR>'
end

local function invoke_visual_positions(buffer, anchor, cursor, instruction)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, anchor)
  feed 'v'
  vim.api.nvim_win_set_cursor(0, cursor)
  feed '<F8>'
  wait_for(function()
    return prompt_opened(buffer)
  end, 'positioned visual invocation did not open prompt')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { instruction })
  feed '<CR>'
end

local function buffer_lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function native_newline_state(line, cursor, keys)
  local window = vim.api.nvim_get_current_win()
  local original_buffer = vim.api.nvim_get_current_buf()
  local original_cursor = vim.api.nvim_win_get_cursor(window)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, scratch)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(window, cursor)
  feed(keys)
  local state = {
    lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false),
    cursor = vim.api.nvim_win_get_cursor(window),
  }
  vim.api.nvim_win_set_buf(window, original_buffer)
  vim.api.nvim_win_set_cursor(window, original_cursor)
  vim.api.nvim_buf_delete(scratch, { force = true })
  return state
end

local function wait_terminal(pattern)
  wait_for(function()
    return notified(pattern)
  end, 'missing terminal notification matching ' .. pattern)
end

local lualine_refreshes = {}
package.loaded.lualine = {
  refresh = function(options)
    table.insert(lualine_refreshes, options)
  end,
}

local ai_edit = require 'ai_edit'
local function setup(overrides)
  local options = {
    keymap = '<F8>',
    command = fake,
    timeout_ms = 15000,
    cleanup_timeout_ms = 500,
    max_bytes = 1024 * 1024,
    width = 0.6,
    height = 0.3,
    status = {
      text = 'AI is Working...',
      color = '#d946ef',
      interval_ms = 20,
      frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
    },
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  ai_edit.setup(options)
end

setup()

do
  local ok, message = pcall(ai_edit.setup, 'invalid')
  truthy(not ok and tostring(message):match 'ai_edit: setup options must be a table', 'setup type error lacks public prefix')
  ok, message = pcall(ai_edit.setup, { width = 0 / 0 })
  truthy(not ok and tostring(message):match 'ai_edit: width', 'NaN prompt width was accepted')
end

-- Lualine status appears immediately, animates, and clears on completion.
do
  equal(ai_edit.statusline(), '', 'idle statusline was not empty')
  equal(ai_edit.statusline_color(), { fg = '#d946ef', gui = 'bold' }, 'default statusline color differs')
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'cancel'
  local buffer = open_file('status.lua', { 'unchanged' })
  local refresh_count = #lualine_refreshes
  invoke_normal(buffer, 'show status')
  truthy(#lualine_refreshes > refresh_count, 'lualine was not refreshed when work started')
  local first_frame = ai_edit.statusline()
  truthy(first_frame:match 'AI is Working%.%.%.$', 'working status text missing')
  wait_for(function()
    return ai_edit.statusline() ~= first_frame
  end, 'working status did not animate')
  truthy(#lualine_refreshes > refresh_count + 1, 'lualine was not refreshed for animation')
  ai_edit.cancel(buffer)
  wait_for(function()
    return ai_edit.statusline() == ''
  end, 'working status did not clear after cancellation')
  local refresh_options = lualine_refreshes[#lualine_refreshes]
  equal(refresh_options, { scope = 'tabpage', place = { 'statusline' }, force = true }, 'lualine refresh options differ')
  wait_terminal 'cancelled'

  setup { status = { text = 'AI 50% done', frames = { '%', '.' } } }
  buffer = open_file('status-percent.lua', { 'unchanged' })
  invoke_normal(buffer, 'escape status')
  equal(ai_edit.statusline(), '%% AI 50%% done', 'statusline metacharacters were not escaped')
  ai_edit.cancel(buffer)
  wait_for(function()
    return ai_edit.statusline() == ''
  end, 'escaped status did not clear after cancellation')
  setup()
end

-- Normal target, exact preflight, argv-safe stdin, dynamic agent, bootstrap, cleanup, undo.
do
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'large-debug-config'
  local buffer = open_file('normal.lua', { 'local before = true', 'return before' })
  local before = buffer_lines(buffer)
  invoke_normal(buffer, '--flags stay on stdin\nnormal')
  wait_for(function()
    return vim.deep_equal(buffer_lines(buffer), { 'normal result' })
  end, 'whole-buffer result not applied')
  truthy(vim.bo[buffer].modified, 'result must remain unsaved')
  wait_terminal 'revert|undo|changed'
  vim.api.nvim_set_current_buf(buffer)
  vim.cmd 'undo'
  equal(buffer_lines(buffer), before, 'one undo did not restore whole buffer')

  local entries = log_entries()
  local run
  local agents = {}
  for _, entry in ipairs(entries) do
    if entry.kind == 'run' then
      run = entry
      local index = vim.fn.index(entry.args, '--agent')
      truthy(index >= 0, 'run omitted --agent')
      table.insert(agents, entry.args[index + 2])
    end
  end
  truthy(run, 'fake OpenCode run missing')
  equal(run.instruction, '--flags stay on stdin\nnormal', 'instruction changed or became argv')
  truthy(not vim.tbl_contains(run.args, run.instruction), 'instruction leaked into argv')
  equal(run.pure, '1', 'OPENCODE_PURE missing')
  equal(run.disableDefaultPlugins, nil, 'built-in authentication plugins unavailable')
  equal(run.disableProjectConfig, '1', 'project config not disabled')
  equal(run.xdgConfigHome, vim.fs.dirname(run.configDir), 'runtime global config directory was not isolated to helper cache')
  truthy(run.opencodeTestHome and run.opencodeTestHome:find(run.root, 1, true) == 1, 'legacy global extension home was not isolated')
  equal(run.targetInput, 'local before = true\nreturn before', 'normal staging omitted in-memory buffer')
  equal(run.config.model, 'test-provider/inherited-model', 'resolved global model was not preserved')
  equal(run.config.provider, { ['test-provider'] = { options = { inherited = true } } }, 'resolved global provider was not preserved')
  equal(run.config.share, 'disabled', 'runtime sharing not disabled')
  equal(run.config.snapshot, false, 'runtime snapshots not disabled')
  equal(run.config.formatter, false, 'runtime formatters not disabled')
  equal(run.config.lsp, false, 'runtime LSP not disabled')
  truthy(run.config.plugin and vim.tbl_isempty(run.config.plugin), 'configured external plugins not disabled')
  equal(run.config.tool_output, { max_bytes = 32768, max_lines = 10 }, 'runtime tool-output limits differ')
  truthy(run.config.tools and run.config.tools.apply_patch == false, 'apply_patch not disabled')
  truthy(run.config.tools and run.config.tools.edit == false, 'edit not disabled')
  truthy(run.config.tools and run.config.tools.write == false, 'write not disabled')
  truthy(run.configDir and not run.configDir:find(vim.fn.getcwd(), 1, true), 'checked-in config used as writable cache')
  local manifest = vim.json.decode(read_file(run.configDir .. '/package.json'))
  local helper_version = manifest.dependencies and manifest.dependencies['@opencode-ai/plugin']
  truthy(helper_version, 'cache manifest lacks exact helper dependency')
  truthy(helper_version:match '^%d+%.%d+%.%d+[%w.-]*$', 'helper dependency must use exact version')
  truthy(count_log 'version' >= 1 and count_log 'debug-config' >= 1 and count_log 'debug-agent' >= 1, 'version/config/agent preflight missing')
  wait_for(function()
    return count_log 'session-delete' >= 1
  end, 'observed session was not deleted')
end

-- Higher compatible CLIs receive an exact matching helper SDK and separate cache.
do
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'success'
  vim.env.AI_EDIT_FAKE_VERSION = '1.99.0'
  local buffer = open_file('compatible-version.lua', { 'before compatible version' })
  invoke_normal(buffer, 'compatible version')
  wait_for(function()
    return vim.deep_equal(buffer_lines(buffer), { 'normal result' })
  end, 'higher compatible OpenCode version did not apply result')
  local run
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'run' and entry.instruction == 'compatible version' then
      run = entry
    end
  end
  truthy(run, 'higher compatible OpenCode run missing')
  local manifest = vim.json.decode(read_file(run.configDir .. '/package.json'))
  equal(manifest.dependencies['@opencode-ai/plugin'], '1.99.0', 'helper SDK did not match compatible CLI')
  vim.env.AI_EDIT_FAKE_VERSION = nil
end

-- A configured model and effort variant override only the generated edit agent.
do
  clear_notifications()
  setup { model = 'openai/gpt-5.6-luna-fast', variant = 'high' }
  vim.env.AI_EDIT_FAKE_SCENARIO = 'success'
  local buffer = open_file('model-override.lua', { 'before' })
  invoke_normal(buffer, 'model override')
  wait_for(function()
    return vim.deep_equal(buffer_lines(buffer), { 'normal result' })
  end, 'model override result not applied')

  local run
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'run' and entry.instruction == 'model override' then
      run = entry
    end
  end
  truthy(run, 'model override run missing')
  local agent_index = vim.fn.index(run.args, '--agent')
  local agent = run.config.agent[run.args[agent_index + 2]]
  equal(agent.model, 'openai/gpt-5.6-luna-fast', 'edit agent model differs')
  equal(agent.variant, 'high', 'edit agent effort variant differs')
  equal(run.config.model, 'test-provider/inherited-model', 'global model was modified')
end

-- Characterwise capture follows Neovim's inclusive/exclusive UTF-8 region in either direction.
do
  local bases = {
    {
      name = 'ascii-single',
      lines = { 'abCDxy' },
      first = { 1, 2 },
      last = { 1, 3 },
      inclusive = { selected = 'CD', result = { 'abBETAxy' } },
      exclusive = { selected = 'C', result = { 'abBETADxy' } },
    },
    {
      name = 'utf8-single',
      lines = { 'aé中z' },
      first = { 1, 1 },
      last = { 1, 3 },
      inclusive = { selected = 'é中', result = { 'aBETAz' } },
      exclusive = { selected = 'é', result = { 'aBETA中z' } },
    },
    {
      name = 'ascii-multiline',
      lines = { 'abX', 'cdZ' },
      first = { 1, 1 },
      last = { 2, 1 },
      inclusive = { selected = 'bX\ncd', result = { 'aBETAZ' } },
      exclusive = { selected = 'bX\nc', result = { 'aBETAdZ' } },
    },
    {
      name = 'utf8-multiline',
      lines = { 'aéX', '中bZ' },
      first = { 1, 1 },
      last = { 2, 3 },
      inclusive = { selected = 'éX\n中b', result = { 'aBETAZ' } },
      exclusive = { selected = 'éX\n中', result = { 'aBETAbZ' } },
    },
  }
  local cases = {}
  for _, base in ipairs(bases) do
    for _, selection in ipairs { 'inclusive', 'exclusive' } do
      for _, direction in ipairs { 'forward', 'reverse' } do
        local expected = base[selection]
        table.insert(cases, {
          name = table.concat({ base.name, selection, direction }, '-'),
          selection = selection,
          lines = base.lines,
          anchor = direction == 'forward' and base.first or base.last,
          cursor = direction == 'forward' and base.last or base.first,
          selected = expected.selected,
          result = expected.result,
        })
      end
    end
  end

  vim.env.AI_EDIT_FAKE_SCENARIO = 'success'
  for _, case in ipairs(cases) do
    clear_notifications()
    vim.o.selection = case.selection
    local buffer = open_file(case.name .. '.lua', case.lines)
    local instruction = 'characterwise ' .. case.name
    invoke_visual_positions(buffer, case.anchor, case.cursor, instruction)
    wait_for(function()
      return vim.deep_equal(buffer_lines(buffer), case.result)
    end, case.name .. ' replacement did not match exact region')

    local run
    for _, entry in ipairs(log_entries()) do
      if entry.kind == 'run' and entry.instruction == instruction then
        run = entry
      end
    end
    truthy(run, case.name .. ' run missing')
    equal(run.targetInput, case.selected, case.name .. ' captured wrong bytes')
    equal(run.contextInput, table.concat(case.lines, '\n'), case.name .. ' context changed')
  end
  vim.o.selection = 'inclusive'
end

-- Characterwise and linewise selection application stays within captured scope.
do
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'success'
  local buffer = open_file('selection.lua', { 'alpha beta omega', 'tail untouched' })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  invoke_visual(buffer, 'v3l', 'characterwise')
  wait_for(function()
    return buffer_lines(buffer)[1] == 'alpha BETA omega'
  end, 'characterwise replacement missed exact bytes')
  equal(buffer_lines(buffer)[2], 'tail untouched', 'characterwise edit escaped selection')

  buffer = open_file('linewise.lua', { 'one', 'two', 'three', 'four' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  invoke_visual(buffer, 'Vj', 'linewise')
  wait_for(function()
    return vim.deep_equal(buffer_lines(buffer), { 'one', 'TWO', 'THREE', 'four' })
  end, 'linewise replacement escaped complete selected lines')

  local saw_characterwise = false
  local saw_linewise = false
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'run' and entry.instruction == 'characterwise' then
      saw_characterwise = entry.targetInput == 'beta' and entry.contextInput == 'alpha beta omega\ntail untouched'
    elseif entry.kind == 'run' and entry.instruction == 'linewise' then
      saw_linewise = entry.targetInput == 'two\nthree' and entry.contextInput == 'one\ntwo\nthree\nfour'
    end
  end
  truthy(saw_characterwise, 'characterwise staging target/context incorrect')
  truthy(saw_linewise, 'linewise staging target/context incorrect')
end

-- Session deletion never gates application, staging removal, or independent timers.
do
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'cleanup-config-sensitive'
  local config_delete_finishes = count_scenario_log('session-delete-finish', 'cleanup-config-sensitive')
  local config_buffer, config_path = open_file('cleanup-config.lua', { 'before config-sensitive cleanup' })
  invoke_normal(config_buffer, 'cleanup config object')
  wait_for(function()
    return vim.deep_equal(buffer_lines(config_buffer), { 'normal result' })
      and count_scenario_log('session-delete-finish', 'cleanup-config-sensitive') > config_delete_finishes
  end, 'config-sensitive session cleanup did not succeed')
  vim.wait(50)
  truthy(not notified 'could not delete', 'valid cleanup config produced OpenCode configuration failure')
  local config_delete
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'session-delete' and entry.scenario == 'cleanup-config-sensitive' then
      config_delete = entry
    end
  end
  truthy(config_delete, 'config-sensitive session cleanup was not captured')
  equal(config_delete.args, { 'session', 'delete', 'fake-session' }, 'session cleanup argv changed')
  equal(vim.uv.fs_realpath(config_delete.cwd), vim.uv.fs_realpath(vim.fs.dirname(config_path)), 'session cleanup cwd changed')
  equal(config_delete.pure, '1', 'session cleanup pure mode missing')
  equal(config_delete.disableDefaultPlugins, nil, 'session cleanup disabled bundled authentication plugins')
  equal(config_delete.disableProjectConfig, '1', 'session cleanup project-config isolation missing')
  equal(config_delete.disableAutoshare, '1', 'session cleanup autoshare isolation missing')
  equal(config_delete.stageRoot, nil, 'session cleanup inherited staging capability')
  equal(config_delete.cleanupConfig.share, 'disabled', 'session cleanup sharing not disabled')
  equal(config_delete.cleanupConfig.snapshot, false, 'session cleanup snapshots not disabled')
  equal(config_delete.toolsIsArray, false, 'empty cleanup tools encoded as invalid JSON array')

  local ticks = 0
  local responsiveness_timer = vim.uv.new_timer()
  responsiveness_timer:start(5, 5, function()
    ticks = ticks + 1
  end)

  setup { cleanup_timeout_ms = 1000 }
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'cleanup-delay'
  local delete_starts = count_scenario_log('session-delete', 'cleanup-delay')
  local delete_finishes = count_scenario_log('session-delete-finish', 'cleanup-delay')
  local buffer = open_file('cleanup-delay.lua', { 'before delayed cleanup' })
  invoke_normal(buffer, 'cleanup delay')
  local delayed_root
  wait_for(function()
    for _, entry in ipairs(log_entries()) do
      if entry.kind == 'run' and entry.instruction == 'cleanup delay' then
        delayed_root = entry.root
      end
    end
    return vim.deep_equal(buffer_lines(buffer), { 'normal result' })
      and count_scenario_log('session-delete', 'cleanup-delay') > delete_starts
      and delayed_root ~= nil
  end, 'buffer result waited for delayed session deletion')
  equal(count_scenario_log('session-delete-finish', 'cleanup-delay'), delete_finishes, 'buffer result waited for delayed cleanup completion')
  equal(vim.fn.isdirectory(delayed_root), 0, 'staging removal waited for delayed cleanup')
  local ticks_after_apply = ticks
  wait_for(function()
    return ticks >= ticks_after_apply + 5
  end, 'Neovim timer did not advance during delayed cleanup', 200)
  equal(count_scenario_log('session-delete-finish', 'cleanup-delay'), delete_finishes, 'delayed cleanup finished before responsiveness proof')
  wait_for(function()
    return count_scenario_log('session-delete-finish', 'cleanup-delay') > delete_finishes
  end, 'delayed session cleanup did not complete')

  setup { cleanup_timeout_ms = 80 }
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'cleanup-never'
  delete_starts = count_scenario_log('session-delete', 'cleanup-never')
  buffer = open_file('cleanup-never.lua', { 'before stuck cleanup' })
  invoke_normal(buffer, 'cleanup never')
  local stuck_root
  wait_for(function()
    for _, entry in ipairs(log_entries()) do
      if entry.kind == 'run' and entry.instruction == 'cleanup never' then
        stuck_root = entry.root
      end
    end
    return vim.deep_equal(buffer_lines(buffer), { 'normal result' })
      and count_scenario_log('session-delete', 'cleanup-never') > delete_starts
      and stuck_root ~= nil
  end, 'buffer result waited for never-exiting session deletion')
  equal(vim.fn.isdirectory(stuck_root), 0, 'staging removal waited for stuck cleanup')
  ticks_after_apply = ticks
  wait_for(function()
    return notified 'cleanup.*timed out|session.*timed out'
  end, 'stuck session cleanup timeout warning missing')
  truthy(ticks > ticks_after_apply, 'Neovim timer did not advance during stuck cleanup')
  wait_for(function()
    return count_scenario_log('session-delete-term', 'cleanup-never') > 0
  end, 'stuck cleanup process did not receive bounded-time termination')

  responsiveness_timer:stop()
  responsiveness_timer:close()
  setup()
end

-- Prompt newline parity, empty rejection, Escape cancellation.
do
  clear_notifications()
  local buffer = open_file('prompt.lua', { 'prompt' })
  local newline_cases = {
    { label = 'ASCII insert middle', line = 'abcd', cursor = { 1, 2 }, native = 'i<CR><Esc>', mapped = 'i<C-j><C-\\><C-n>' },
    { label = 'ASCII normal middle', line = 'abcd', cursor = { 1, 2 }, native = 'a<CR><Esc>', mapped = '<C-j>' },
    { label = 'multibyte insert middle', line = 'aébc', cursor = { 1, 1 }, native = 'i<CR><Esc>', mapped = 'i<C-j><C-\\><C-n>' },
    { label = 'multibyte normal middle', line = 'aébc', cursor = { 1, 1 }, native = 'a<CR><Esc>', mapped = '<C-j>' },
    { label = 'insert end', line = 'first', cursor = { 1, 4 }, native = 'A<CR><Esc>', mapped = 'A<C-j><C-\\><C-n>' },
    { label = 'normal end', line = 'first', cursor = { 1, 4 }, native = 'a<CR><Esc>', mapped = '<C-j>' },
  }
  local native_states = {}
  for index, case in ipairs(newline_cases) do
    native_states[index] = native_newline_state(case.line, case.cursor, case.native)
  end
  feed '<F8>'
  wait_for(function()
    return prompt_opened(buffer)
  end, 'prompt did not open')
  local prompt = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { '   ' })
  feed '<CR>'
  equal(vim.api.nvim_get_current_buf(), prompt, 'empty prompt closed')
  truthy(notified 'instruction', 'empty prompt warning missing')
  local before_runs = count_log 'run'
  feed '<C-\\><C-n>'
  for index, case in ipairs(newline_cases) do
    vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { case.line })
    vim.api.nvim_win_set_cursor(0, case.cursor)
    feed(case.mapped)
    equal({
      lines = vim.api.nvim_buf_get_lines(prompt, 0, -1, false),
      cursor = vim.api.nvim_win_get_cursor(0),
    }, native_states[index], case.label .. ' <C-j> differs from native insert-mode Enter')
  end
  equal(count_log 'run', before_runs, '<C-j> submitted prompt')
  feed '<Esc>'
  wait_for(function()
    return vim.api.nvim_get_current_buf() == buffer
  end, 'Escape did not close prompt')
  equal(count_log 'run', before_runs, 'cancelled prompt started OpenCode')
end

-- Unsupported buffers, blockwise selection, and size limit never open prompt or run.
do
  local function rejected(buffer, pattern)
    clear_notifications()
    local runs = count_log 'run'
    vim.api.nvim_set_current_buf(buffer)
    feed '<F8>'
    vim.wait(100)
    equal(vim.api.nvim_get_current_buf(), buffer, 'unsupported target opened prompt')
    equal(count_log 'run', runs, 'unsupported target started OpenCode')
    truthy(notified(pattern), 'missing validation notification: ' .. pattern)
  end

  vim.cmd 'enew'
  rejected(vim.api.nvim_get_current_buf(), 'name|file')
  local buffer = open_file('readonly.lua', { 'readonly' })
  vim.bo[buffer].readonly = true
  rejected(buffer, 'read')
  vim.bo[buffer].readonly = false
  vim.bo[buffer].binary = true
  rejected(buffer, 'binary')
  vim.bo[buffer].binary = false
  vim.bo[buffer].buftype = 'nofile'
  rejected(buffer, 'file|buffer')

  setup { max_bytes = 8 }
  buffer = open_file('large.lua', { 'more than eight bytes' })
  rejected(buffer, 'size|large|limit')
  setup()

  buffer = open_file('block.lua', { 'abcd', 'efgh' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed '<C-v>j'
  rejected(buffer, 'block')
  feed '<Esc>'
end

-- Same-buffer concurrency rejected; another buffer may run concurrently; cancellation cleans both.
do
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'parallel'
  local first = open_file('parallel-one.lua', { 'first' })
  invoke_normal(first, 'parallel first')
  local first_runs = count_log 'run'
  vim.api.nvim_set_current_buf(first)
  feed '<F8>'
  vim.wait(50)
  equal(count_log 'run', first_runs, 'same-buffer request started twice')
  truthy(notified 'active|already|running', 'same-buffer concurrency rejection missing')

  local second = open_file('parallel-two.lua', { 'second' })
  invoke_normal(second, 'parallel second')
  wait_for(function()
    return count_log 'run' >= first_runs + 1
  end, 'second buffer did not run concurrently')
  vim.api.nvim_set_current_buf(first)
  vim.cmd 'AIEditCancel'
  vim.api.nvim_set_current_buf(second)
  vim.cmd 'AIEditCancel'
  wait_for(function()
    return notified 'cancel'
  end, 'cancellation notification missing')
  equal(buffer_lines(first), { 'first' }, 'cancel changed first buffer')
  equal(buffer_lines(second), { 'second' }, 'cancel changed second buffer')
end

-- Stale buffer and disappeared buffer results are discarded.
do
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'stale'
  local buffer = open_file('stale.lua', { 'snapshot' })
  invoke_normal(buffer, 'stale')
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'newer user text' })
  wait_terminal 'stale|changed'
  equal(buffer_lines(buffer), { 'newer user text' }, 'stale result overwrote user text')

  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'missing-buffer'
  buffer = open_file('missing.lua', { 'snapshot' })
  invoke_normal(buffer, 'missing buffer')
  vim.api.nvim_buf_delete(buffer, { force = true })
  wait_terminal 'available|buffer'
end

-- Missing executable, no-op, all event failures, and exact submit cardinality.
do
  local function error_float_count()
    local count = 0
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(window)
      local title = config.title
      if type(title) == 'table' then
        local chunks = {}
        for _, chunk in ipairs(title) do
          table.insert(chunks, chunk[1])
        end
        title = table.concat(chunks)
      end
      if config.relative ~= '' and title == ' AI edit error ' then
        count = count + 1
      end
    end
    return count
  end

  local function unchanged_failure(scenario, pattern, expects_error_float)
    clear_notifications()
    vim.env.AI_EDIT_FAKE_SCENARIO = scenario
    local buffer = open_file(scenario .. '.lua', { 'unchanged' })
    local floats = error_float_count()
    invoke_normal(buffer, scenario)
    wait_for(function()
      return notified(pattern) or error_float_count() > floats
    end, scenario .. ' completion feedback missing')
    equal(buffer_lines(buffer), { 'unchanged' }, scenario .. ' changed buffer')
    if expects_error_float then
      truthy(error_float_count() > floats, scenario .. ' did not open readonly error float')
    end
  end

  setup { command = root .. '/missing-opencode' }
  clear_notifications()
  local buffer = open_file('missing-executable.lua', { 'unchanged' })
  local before_runs = count_log 'run'
  feed '<F8>'
  wait_for(function()
    return notified 'opencode|executable|dependency|found'
  end, 'missing executable not reported')
  equal(count_log 'run', before_runs, 'missing executable started job')
  setup()

  unchanged_failure('no-op', 'no changes|unchanged', false)
  unchanged_failure('nonzero', 'error|failed', true)
  unchanged_failure('top-error', 'error|failed', true)
  unchanged_failure('nested-error', 'error|failed', true)
  unchanged_failure('missing-submit', 'submit|error|failed', true)
  unchanged_failure('duplicate-submit', 'submit|error|failed', true)

  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'cleanup-error'
  buffer = open_file('cleanup-error.lua', { 'before cleanup warning' })
  invoke_normal(buffer, 'cleanup error')
  wait_for(function()
    return vim.deep_equal(buffer_lines(buffer), { 'normal result' }) and notified 'cleanup|session|delete'
  end, 'session cleanup failure changed successful buffer outcome or lacked warning')
end

-- Timeout terminates run and leaves original content; terminal paths remove staging.
do
  setup { timeout_ms = 50 }
  clear_notifications()
  vim.env.AI_EDIT_FAKE_SCENARIO = 'timeout'
  local buffer = open_file('timeout.lua', { 'original' })
  invoke_normal(buffer, 'timeout')
  wait_terminal 'timeout|timed out'
  equal(buffer_lines(buffer), { 'original' }, 'timeout changed buffer')
  setup()

  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'run' and entry.root then
      equal(vim.fn.isdirectory(entry.root), 0, 'terminal outcome leaked staging directory')
    end
  end

  local names = {}
  local total_agents = 0
  local saw_inherited_model = false
  local saw_configured_model = false
  for _, entry in ipairs(log_entries()) do
    if entry.kind == 'debug-agent' then
      if entry.agent.model == nil then
        saw_inherited_model = true
      else
        equal(entry.agent.model, 'openai/gpt-5.6-luna-fast', 'runtime agent pinned unexpected model')
        equal(entry.agent.variant, 'high', 'runtime agent pinned unexpected effort variant')
        saw_configured_model = true
      end
    elseif entry.kind == 'run' then
      local index = vim.fn.index(entry.args, '--agent')
      local name = index >= 0 and entry.args[index + 2] or nil
      truthy(name, 'run omitted generated agent name')
      total_agents = total_agents + 1
      names[name] = true
    end
  end
  local unique_agents = 0
  for _ in pairs(names) do
    unique_agents = unique_agents + 1
  end
  truthy(saw_inherited_model and saw_configured_model, 'model inheritance and override paths were not both exercised')
  truthy(total_agents >= 2 and unique_agents == total_agents, 'runtime agent names were not unique per run')
end

vim.fn.delete(root, 'rf')
print 'headless ai_edit assertions passed'
