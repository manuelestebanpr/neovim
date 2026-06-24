return {
  {
    "mason-org/mason.nvim",
    opts = {
      ui = {
        icons = {
          package_installed = "✓",
          package_pending = "➜",
          package_uninstalled = "✗"
        }
      }
    }
  },
  {
    'williamboman/mason-lspconfig.nvim',
    opts = {
      -- Auto-install these LSPs. emmet_language_server + html power JSP editing
      -- (~1900 storefront .jsp files): emmet abbreviation expansion + tag/attribute
      -- completion. Their jsp filetype wiring is in lua/config/lsp.lua.
      ensure_installed = { 'emmet_language_server', 'html' },
      automatic_enable = {
        exclude = {
          --needs external plugin
          'jdtls'
        }
      }
    }
  },
  {
    'mfussenegger/nvim-jdtls'
  }
}
