return {
  "ibhagwan/fzf-lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    -- 1. WINDOW OPTIONS
    winopts = {
      preview = {
        layout = "vertical",
        vertical = "down:50%",
        -- These settings help stabilize the window when toggling preview
        title = true,
        scrollbar = "float",
      },
    },

    -- 2. FZF ALGORITHM OPTIONS
    fzf_opts = {
      -- 'path': optimizes scoring for file paths
      ['--scheme'] = 'path',
      -- 'end': Prioritizes matches at the end of the string (the filename).
      --        If you type "Facade", it looks for files ending in "Facade".
      -- 'length': Prioritizes shorter matches.
      --        If you have "BulkBookingFacade" (exact) and "DefaultBulkBookingFacade",
      --        the shorter one (exact match) wins.
      ['--tiebreak'] = 'end,length',
    },

    -- 3. FILE SEARCH (Ctrl-P)
    files = {
      -- [UPDATED] Using 'rg' (ripgrep) instead of 'fd' for better stability.
      -- --sort path: Sorts alphabetically. Luckily, 'c'ustom < 'm'odules < 'p'latform.
      --              This forces Custom files to appear top of the list in ties.
      cmd = "rg --files --color=never --hidden --follow --no-messages --sort path " ..
            "-g '!.git' " ..
            "-g '!.idea' " ..
            "-g '!log' " ..
            "-g '!data' " ..
            "-g '!roles' " ..
            "-g '!temp'",
    },

    -- 4. CONTENT SEARCH (Live Grep)
    grep = {
      -- [UPDATED] Live grep command with the same exclusions and symlink support
      rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 " ..
                "-L " .. -- Follow Symlinks
                "-g '!.git' " ..
                "-g '!.idea' " ..
                "-g '!log' " ..
                "-g '!data' " ..
                "-g '!roles' " ..
                "-g '!temp'",
    },
  },
}
