-- =============================================================================
-- Java debugging (nvim-dap) — IntelliJ-style remote debugging for Hybris & Spring
-- -----------------------------------------------------------------------------
-- This module is the single setup entry point for the whole debugging stack. It
-- is loaded lazily (see lua/plugins/dap.lua) the first time you open a Java file
-- or press a <leader>d… key, so it costs nothing at startup.
--
-- What you get (mirrors IntelliJ's debugger UX):
--   * Breakpoints with red-dot signs; toggle / conditional / clear-all.
--   * A bottom DOCK (nvim-dap-ui) that opens automatically when a session starts,
--     showing Variables (scopes) + call Frames + Watches + Breakpoints + a REPL —
--     like IntelliJ's bottom debug panel.
--   * Inline variable values at end-of-line while stopped (nvim-dap-virtual-text),
--     like IntelliJ's inline values.
--   * A fzf-lua breakpoint picker (<leader>dl) that lists every breakpoint and
--     JUMPS to its file:line on <Enter> (Ctrl-x deletes one) — the easiest way to
--     "see all my breakpoints and move to them".
--   * Remote ATTACH to an already-running JVM over JDWP (the way you debug a live
--     Hybris server or a Spring boot app started with -agentlib:jdwp=…). Hybris
--     defaults to port 8000, generic Spring to 5005.
--
-- The actual `java` DAP adapter is provided by nvim-jdtls (require('jdtls').setup_dap),
-- which talks to the running jdtls language server to obtain the debug port. The
-- debug plugin JARs (java-debug-adapter, java-test) are loaded INTO jdtls as
-- init_options.bundles — see jdtls.utils.get_dap_bundles + the two *_setup.lua.
-- =============================================================================

local M = {}

local did_setup = false

-- Hybris servers expose JDWP on 8000 (`./hybrisserver.sh debug`); plain Spring
-- Boot / `-agentlib:jdwp` defaults to 5005. The prompt remembers nothing fancy —
-- 8000 is offered first because this is primarily a Hybris box.
local DEFAULT_HYBRIS_PORT = 8000
local DEFAULT_SPRING_PORT = 5005

-- ---------------------------------------------------------------------------
-- Signs & highlights (IntelliJ-ish: red breakpoint dot, green stopped arrow).
-- ---------------------------------------------------------------------------
local function define_signs()
  local function hl(name, opts) vim.api.nvim_set_hl(0, name, opts) end
  -- Defined with default=true semantics via explicit set; chosen to read well on
  -- both light and dark colourschemes used here.
  hl('DapBreakpoint',          { fg = '#e06c75' })
  hl('DapBreakpointCondition', { fg = '#e5c07b' })
  hl('DapLogPoint',            { fg = '#61afef' })
  hl('DapStopped',             { fg = '#98c379' })
  hl('DapStoppedLine',         { bg = '#2e3d2c' })

  vim.fn.sign_define('DapBreakpoint',          { text = '●', texthl = 'DapBreakpoint' })
  vim.fn.sign_define('DapBreakpointCondition', { text = '◆', texthl = 'DapBreakpointCondition' })
  vim.fn.sign_define('DapBreakpointRejected',  { text = '○', texthl = 'DapBreakpoint' })
  vim.fn.sign_define('DapLogPoint',            { text = '◆', texthl = 'DapLogPoint' })
  vim.fn.sign_define('DapStopped',
    { text = '▶', texthl = 'DapStopped', linehl = 'DapStoppedLine', numhl = 'DapStopped' })
end

-- ---------------------------------------------------------------------------
-- nvim-dap-ui: one BOTTOM dock laid out as columns, like IntelliJ's debug panel.
-- ---------------------------------------------------------------------------
local function setup_ui(dapui)
  dapui.setup({
    -- Play/step controls in the REPL element's winbar.
    controls = { enabled = true, element = 'repl' },
    floating = { border = 'rounded', mappings = { close = { 'q', '<Esc>' } } },
    layouts = {
      {
        position = 'bottom',
        size = 10, -- rows
        elements = {
          { id = 'scopes',      size = 0.34 }, -- Variables (the "attributes & variables" panel)
          { id = 'stacks',      size = 0.22 }, -- Call frames
          { id = 'watches',     size = 0.18 }, -- Watch expressions
          { id = 'breakpoints', size = 0.13 }, -- All breakpoints
          { id = 'repl',        size = 0.13 }, -- Evaluate / console
        },
      },
    },
  })
end

-- ---------------------------------------------------------------------------
-- Register the Java adapter (via jdtls) + the remote-attach configurations.
-- Idempotent: safe to call again after jdtls restarts.
-- ---------------------------------------------------------------------------
function M.register_java()
  local ok_dap, dap = pcall(require, 'dap')
  if not ok_dap then return end
  local ok_jdtls, jdtls = pcall(require, 'jdtls')
  if not ok_jdtls then return end

  -- Registers dap.adapters.java; hotcodereplace='auto' applies edited methods to
  -- the live JVM without a restart (IntelliJ's "HotSwap").
  pcall(function() jdtls.setup_dap({ hotcodereplace = 'auto' }) end)

  -- Remote-attach configs. dap.run / dap.continue offer these when no launch
  -- config exists (the normal case for Hybris — you attach, you don't launch).
  -- setup_dap_main_class_configs (Spring/maven only) APPENDS launch configs after
  -- these, so both coexist.
  local attach = {
    {
      type = 'java', request = 'attach',
      name = 'Attach to JVM — localhost:' .. DEFAULT_HYBRIS_PORT .. ' (Hybris)',
      hostName = '127.0.0.1', port = DEFAULT_HYBRIS_PORT,
    },
    {
      type = 'java', request = 'attach',
      name = 'Attach to JVM — localhost:' .. DEFAULT_SPRING_PORT .. ' (Spring)',
      hostName = '127.0.0.1', port = DEFAULT_SPRING_PORT,
    },
    {
      type = 'java', request = 'attach',
      name = 'Attach to JVM — prompt host:port',
      hostName = function() return vim.fn.input('Debug host [127.0.0.1]: ', '127.0.0.1') end,
      port = function()
        return tonumber(vim.fn.input('Debug port [' .. DEFAULT_HYBRIS_PORT .. ']: ',
          tostring(DEFAULT_HYBRIS_PORT)))
      end,
    },
  }

  dap.configurations.java = dap.configurations.java or {}
  -- Replace any attach configs we previously added (keep launch configs jdtls
  -- resolved), then prepend ours so they head the picker.
  local kept = {}
  for _, c in ipairs(dap.configurations.java) do
    if not (c.request == 'attach' and type(c.name) == 'string' and c.name:find('Attach to JVM', 1, true)) then
      table.insert(kept, c)
    end
  end
  local merged = {}
  vim.list_extend(merged, attach)
  vim.list_extend(merged, kept)
  dap.configurations.java = merged

  -- Disable nvim-jdtls's DYNAMIC main-class auto-discovery provider. setup_dap()
  -- registers dap.providers.configs['jdtls']; on <leader>dc (dap.continue with no
  -- session) nvim-dap would invoke it -> vscode.java.resolveMainClass, a
  -- workspace-wide scan that stalls ~2s and toasts "Discovering main classes took
  -- too long" on a huge Hybris workspace. We don't need it: Hybris uses the attach
  -- configs above, and Maven projects get STATIC launch configs from
  -- setup_dap_main_class_configs() (jdtls_setup.lua) which also nils this provider.
  -- (A single resolveMainClass still runs at attach-enrich time; that one is cheap
  -- and unavoidable without prefilling mainClass/projectName -- not the full scan.)
  if dap.providers and dap.providers.configs then
    dap.providers.configs['jdtls'] = nil
  end
end

-- Directly start a remote attach, prompting only for the port (default Hybris
-- 8000). Bound to <leader>da for the common "attach to my running server" flow.
function M.attach_remote()
  local ok_dap, dap = pcall(require, 'dap')
  if not ok_dap then return end
  local port = tonumber(vim.fn.input('Attach to JVM port [' .. DEFAULT_HYBRIS_PORT .. ']: ',
    tostring(DEFAULT_HYBRIS_PORT)))
  if not port then
    vim.notify('Debug attach cancelled (no port).', vim.log.levels.WARN)
    return
  end
  dap.run({
    type = 'java', request = 'attach',
    name = 'Attach to JVM — localhost:' .. port,
    hostName = '127.0.0.1', port = port,
  })
end

-- ---------------------------------------------------------------------------
-- Keymaps under <leader>d (a previously-unused prefix). All carry a `desc` so
-- which-key lists them automatically; the group name is registered below.
-- ---------------------------------------------------------------------------
local function setup_keymaps()
  local dap = require('dap')
  -- dapui is optional: degrade <leader>du/<leader>de to a notice if it's absent
  -- rather than erroring out of the whole keymap setup.
  local function dapui_call(method, ...)
    local ok, dapui = pcall(require, 'dapui')
    if ok and dapui[method] then return dapui[method](...) end
    vim.notify('nvim-dap-ui not available', vim.log.levels.WARN)
  end
  local function fzf(fn)
    return function()
      local ok, f = pcall(require, 'fzf-lua')
      if ok and f[fn] then f[fn]() else vim.notify('fzf-lua not available', vim.log.levels.WARN) end
    end
  end
  local function map(lhs, rhs, desc, mode)
    vim.keymap.set(mode or 'n', lhs, rhs, { desc = desc, silent = true })
  end

  -- Breakpoints
  map('<leader>db', dap.toggle_breakpoint, 'Debug: Toggle Breakpoint')
  map('<leader>dB', function()
    dap.set_breakpoint(vim.fn.input('Breakpoint condition: '))
  end, 'Debug: Conditional Breakpoint')
  map('<leader>dC', dap.clear_breakpoints, 'Debug: Clear ALL Breakpoints')
  -- See every breakpoint and jump to its file:line (Enter), or delete it (Ctrl-x).
  map('<leader>dl', fzf('dap_breakpoints'), 'Debug: List Breakpoints (jump to file:line)')

  -- Session control
  map('<leader>dc', dap.continue, 'Debug: Continue / Start (pick config)')
  map('<leader>da', M.attach_remote, 'Debug: Attach to running JVM (remote)')
  map('<leader>dx', function()
    dap.terminate()
    pcall(function() require('dapui').close({}) end)
  end, 'Debug: Terminate / Stop')
  map('<leader>dp', dap.pause, 'Debug: Pause')
  map('<leader>dR', dap.run_last, 'Debug: Run Last')

  -- Stepping
  map('<leader>do', dap.step_over, 'Debug: Step Over')
  map('<leader>di', dap.step_into, 'Debug: Step Into')
  map('<leader>dO', dap.step_out, 'Debug: Step Out')
  map('<leader>dk', dap.up, 'Debug: Up one frame')
  map('<leader>dj', dap.down, 'Debug: Down one frame')

  -- Inspection / UI
  map('<leader>du', function() dapui_call('toggle') end, 'Debug: Toggle UI dock')
  map('<leader>dr', function() dap.repl.toggle() end, 'Debug: Toggle REPL')
  map('<leader>de', function() dapui_call('eval', nil, { enter = true }) end,
    'Debug: Evaluate expression', { 'n', 'v' })
  map('<leader>df', fzf('dap_frames'), 'Debug: Stack Frames (fzf)')
  map('<leader>dv', fzf('dap_variables'), 'Debug: Variables (fzf)')

  -- JUnit (needs the java-test bundle). Debug the test under the cursor / the class.
  map('<leader>dt', function() require('jdtls').test_nearest_method() end, 'Debug: Test Nearest Method')
  map('<leader>dT', function() require('jdtls').test_class() end, 'Debug: Test Class')

  -- Function keys for IntelliJ/VSCode muscle memory (also work without the menu).
  map('<F5>',  dap.continue,            'Debug: Continue')
  map('<F9>',  dap.toggle_breakpoint,   'Debug: Toggle Breakpoint')
  map('<F10>', dap.step_over,           'Debug: Step Over')
  map('<F11>', dap.step_into,           'Debug: Step Into')
  -- Step Out: bind both encodings of Shift-F11 (xterm-style terminals deliver it as
  -- <F23>; others send a literal <S-F11>), so it works regardless of terminal.
  map('<S-F11>', dap.step_out,          'Debug: Step Out')
  map('<F23>',   dap.step_out,          'Debug: Step Out')

  -- which-key group label for the <leader>d menu.
  local ok_wk, wk = pcall(require, 'which-key')
  if ok_wk then wk.add({ { '<leader>d', group = 'Debug (Java)' } }) end
end

-- ---------------------------------------------------------------------------
-- One-shot setup, run when nvim-dap first loads.
-- ---------------------------------------------------------------------------
function M.setup()
  if did_setup then return end
  did_setup = true

  local ok_dap, dap = pcall(require, 'dap')
  if not ok_dap then return end
  local ok_ui, dapui = pcall(require, 'dapui')
  local ok_vt, vt = pcall(require, 'nvim-dap-virtual-text')

  -- Make sure the debug adapter JARs exist in Mason (async install if missing).
  pcall(function() require('jdtls.utils').ensure_dap_installed() end)

  define_signs()

  if ok_vt then
    vt.setup({
      enabled = true,
      commented = false,
      only_first_definition = true,
      all_references = false,
      virt_text_pos = 'eol',
      highlight_changed_variables = true,
    })
  end

  if ok_ui then
    setup_ui(dapui)
    -- Auto-open the bottom dock when a session starts; auto-close when it ends.
    dap.listeners.after.event_initialized['dapui_config']  = function() dapui.open({}) end
    dap.listeners.before.event_terminated['dapui_config']  = function() dapui.close({}) end
    dap.listeners.before.event_exited['dapui_config']      = function() dapui.close({}) end
  end

  M.register_java()
  setup_keymaps()
end

return M
