return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  dependencies = {
    -- Used for the per-mapping icons in the popup (already present via fzf-lua).
    "nvim-tree/nvim-web-devicons",
  },
  config = function()
    require("config.whichkey")
  end,
}
