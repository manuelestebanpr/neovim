return {
  {
    "folke/noice.nvim",
    event = "VeryLazy",
    opts = {
    },
    dependencies = {
      "MunifTanjim/nui.nvim",
      "rcarriga/nvim-notify",
    },
    config = function()
      require("noice").setup({

        popupmenu = {
          backend = "cmp", 
        },

        -- Optional: If you want to force the classic cmdline while keeping other Noice features:
        -- cmdline = {
        --   view = "cmdline", 
        -- },
      })
    end,
  }
}
