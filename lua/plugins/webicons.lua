return {
  "nvim-lualine/lualine.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons", -- Required for icons
  },
  config = function()
    require("lualine").setup({
      options = {
        icons_enabled = true, -- Ensure icons are enabled in Lualine options
      },
    })
  end,
}
