return {
  "ibhagwan/fzf-lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    winopts = {
      preview = {
        layout = "vertical",   -- Stacks the windows vertically
        vertical = "down:50%", -- Puts preview at the bottom, taking 50% of height
      },
    },
  },
}
