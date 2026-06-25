-- Java debugging stack (nvim-dap + dap-ui + virtual-text). Loaded lazily: on the
-- first Java file (ft) so signs/adapter are ready, or on the first <leader>d… /
-- F5 / F9 key. All wiring lives in lua/config/dap.lua. The debug-adapter JARs are
-- loaded INTO jdtls (init_options.bundles, see jdtls.utils.get_dap_bundles); these
-- plugins are only the client + UI.
return {
  {
    'mfussenegger/nvim-dap',
    ft = 'java',
    keys = {
      { '<leader>db', desc = 'Debug: Toggle Breakpoint' },
      { '<leader>dc', desc = 'Debug: Continue / Start' },
      { '<leader>da', desc = 'Debug: Attach to running JVM' },
      { '<leader>dl', desc = 'Debug: List Breakpoints' },
      { '<leader>du', desc = 'Debug: Toggle UI dock' },
      { '<F5>', desc = 'Debug: Continue' },
      { '<F9>', desc = 'Debug: Toggle Breakpoint' },
      { '<F10>', desc = 'Debug: Step Over' },
      { '<F11>', desc = 'Debug: Step Into' },
    },
    dependencies = {
      { 'rcarriga/nvim-dap-ui', dependencies = { 'nvim-neotest/nvim-nio' } },
      'theHamsta/nvim-dap-virtual-text',
    },
    config = function()
      require('config.dap').setup()
    end,
  },
}
