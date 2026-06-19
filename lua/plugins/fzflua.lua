-- Helper to dynamically detect fzf version and apply compatible flags
local fzf_opts = {}
local cache_path = vim.fn.stdpath("cache") .. "/fzf_version_cache"
local version_num

-- Try reading from cache
local f = io.open(cache_path, "r")
if f then
  local cached_ver = f:read("*all")
  f:close()
  version_num = tonumber(cached_ver)
end

-- If cache doesn't exist, run the system command and save it
if not version_num then
  local fzf_version_raw = vim.fn.system("fzf --version")
  if vim.v.shell_error == 0 then
    local major, minor = fzf_version_raw:match("(%d+)%.(%d+)")
    if major and minor then
      version_num = tonumber(major) * 1000 + tonumber(minor)
      -- Save to cache
      local wf = io.open(cache_path, "w")
      if wf then
        wf:write(tostring(version_num))
        wf:close()
      end
    end
  end
end

-- Set options based on version
if version_num then
  -- Multiple tiebreakers and 'end' option require version >= 0.36.0
  if version_num >= 36 then
    fzf_opts['--tiebreak'] = 'length,end'
  else
    fzf_opts['--tiebreak'] = 'length'
  end

  -- --scheme=path requires version >= 0.42.0
  if version_num >= 42 then
    fzf_opts['--scheme'] = 'path'
  end
end

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
        delay = 100, -- Delay preview by 100ms for faster UI initialization and buttery smooth scrolling
      },
    },

    -- 2. DYNAMIC FZF ALGORITHM OPTIONS
    fzf_opts = fzf_opts,

    -- 3. PREVIEWER OPTIONS
    previewers = {
      builtin = {
        syntax_limit_b = 1024 * 100, -- Limit syntax highlighting to files < 100KB to prevent lag
      },
    },

    -- 4. FILE SEARCH (Ctrl-P)
    files = {
      -- [UPDATED] Reverted to 'rg' for stability, but optimized for speed.
      -- 1. Removed '--sort path': This is the #1 cause of slowness. We let fzf handle sorting visually.
      -- 2. Added proper spacing at the end of every line to prevent errors.
      --
      -- HYBRIS SYMLINKS — DO NOT REMOVE `--follow`: in a SAP Commerce project the
      -- `config/` and `bin/custom/` folders are `ln -s` symlinks into a separate
      -- extensions repo. `--follow` (a.k.a. `-L`) makes ripgrep descend into them
      -- so they fuzzy-find as if they were normal in-tree folders, WITHOUT touching
      -- the link itself. ripgrep has built-in symlink-cycle detection, so following
      -- is safe. Strip this flag and config/custom silently vanish from the picker.
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

    -- 5. CONTENT SEARCH (Live Grep)
    grep = {
      -- [UPDATED] Live grep with identical exclusions.
      -- HYBRIS SYMLINKS — `-L` (== `--follow`) is load-bearing here for the exact
      -- same reason as the `files` cmd above: it lets live-grep search INTO the
      -- symlinked `config/` and `bin/custom/` extension folders without resolving
      -- or removing the link. Keep it in sync with the `files` cmd's `--follow`.
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
