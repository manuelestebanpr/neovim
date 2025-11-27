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
