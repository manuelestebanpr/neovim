-- lua/plugins/minifiles.lua
-- mini.files as the primary file explorer (<leader>pv), replacing netrw for the
-- one thing netrw can't do here.
--
-- In a SAP Commerce hybris project, config/ and bin/custom/ are `ln -s` symlinks
-- into a separate extensions repo. netrw's tree liststyle cannot browse a
-- directory symlink in place: it resolves the link and "redirects" you to the
-- real …/hybris-extensions/… path (or, forced to keep the path, shows nothing).
-- mini.files descends into a directory symlink AT its in-tree path
-- (…/hybris/config, …/hybris/bin/custom) and lists the real contents — verified
-- against this project — so the symlinks behave like normal in-tree folders,
-- consistent with how fzf (--follow) and jdtls (vim.fn.resolve) already treat
-- them. The link on disk is never touched.
--
-- mini.nvim is already installed (it is a render-markdown dependency); this spec
-- merges into that same plugin and only adds the mini.files setup + keymap.
-- netrw stays available via :Ex and <leader>pn.

return {
  "nvim-mini/mini.nvim",
  config = function()
    require("mini.files").setup({
      -- Leave plain `:Ex` to netrw; mini.files is opened explicitly via its map.
      options = { use_as_default_explorer = false },
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
