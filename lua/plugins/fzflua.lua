return {
  "ibhagwan/fzf-lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    -- 1. WINDOW OPTIONS
    winopts = {
      preview = {
        layout = "vertical",
        vertical = "down:50%",
        title = true,
        scrollbar = "float",
      },
    },

    -- 2. FZF ALGORITHM OPTIONS
    opts = {
      -- 'path': Optimized scoring for file paths
      ['--scheme'] = 'path',

      -- [CRITICAL FOR "EXACT" MATCHING]
      -- 1. 'length': The shortest result wins. If you type "user", "user.lua" beats "user_profile.lua".
      -- 2. 'end': Matches at the end of the line (filename) beat matches in the middle (folder name).
      ['--tiebreak'] = 'length,end',
      
      -- [PERFORMANCE] Disable history to speed up opening
      ['--history'] = '',
    },

    -- 3. FILE SEARCH (Ctrl-P)
    files = {
      -- [UPDATED] Reverted to 'rg' for stability, but optimized for speed.
      -- 1. Removed '--sort path': This is the #1 cause of slowness. We let fzf handle sorting visually.
      -- 2. Added proper spacing at the end of every line to prevent errors.
      cmd = "rg --files --color=never --hidden --follow --no-messages " ..
            "-g '!.git' " ..
            "-g '!.idea' " ..
            "-g '!log' " ..
            "-g '!data' " ..
            "-g '!roles' " ..
            "-g '!temp' ", -- <== Space added here to prevent command corruption

      file_icons = true,
      git_icons = true,
    },

    -- 4. CONTENT SEARCH (Live Grep)
    grep = {
      -- [UPDATED] Live grep with identical exclusions
      rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 " ..
                "--hidden " ..
                "-L " ..
                "-g '!.git' " ..
                "-g '!.idea' " ..
                "-g '!log' " ..
                "-g '!data' " ..
                "-g '!roles' " ..
                "-g '!temp' ", -- <== Space added here
    },
  },
}
