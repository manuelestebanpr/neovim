-- lua/plugins/minifiles.lua
-- mini.files is THE file explorer. netrw is fully disabled in init.lua
-- (g:loaded_netrw / g:loaded_netrwPlugin).
--
-- `use_as_default_explorer = true` makes mini.files hijack any directory buffer,
-- so `nvim .`, `nvim <some/dir>` and `:edit <dir>` all open the explorer at that
-- path instead of netrw. For the *startup* hijack to fire, mini.files must already
-- be set up when the directory buffer is entered (which happens right after init,
-- before any keys/event lazy-trigger would load the plugin) -- hence `lazy = false`.
-- Only the mini.files module is required, so the rest of the mini.nvim suite is not
-- pulled in and startup cost stays minimal.
--
-- In a SAP Commerce hybris project, config/ and bin/custom/ are `ln -s` symlinks
-- into a separate extensions repo. mini.files descends into a directory symlink AT
-- its in-tree path (…/hybris/config, …/hybris/bin/custom) and lists the real
-- contents -- verified against this project -- consistent with how fzf (--follow)
-- and jdtls (vim.fn.resolve) already treat them. The link on disk is never touched.
--
-- mini.nvim is also a render-markdown dependency; lazy merges both specs into the
-- same plugin (this spec owns the config).

return {
  "nvim-mini/mini.nvim",
  lazy = false,
  config = function()
    require("mini.files").setup({
      -- Hijack directory buffers so mini.files replaces netrw everywhere.
      options = { use_as_default_explorer = true },
      windows = { preview = true, width_focus = 30, width_preview = 70 },
    })
  end,
  keys = {
    {
      "<leader>pv",
      function()
        local MiniFiles = require("mini.files")
        -- Toggle: close if already open, else open at the current file (revealing
        -- it) or, when the buffer has no real file, at the cwd.
        if not MiniFiles.close() then
          local buf = vim.api.nvim_buf_get_name(0)
          local at = (buf ~= "" and vim.uv.fs_stat(buf)) and buf or vim.uv.cwd()
          MiniFiles.open(at)
        end
      end,
      desc = "File Explorer (mini.files)",
    },
  },
}
