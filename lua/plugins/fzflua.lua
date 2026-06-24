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
      -- HYBRIS SYMLINKS — DO NOT REMOVE `--follow` (-L): config/ and bin/custom/ are
      -- symlinks into a separate extensions repo; --follow descends into them so
      -- they fuzzy-find as normal in-tree folders (ripgrep has symlink-cycle
      -- detection, so it is safe). Strip it and config/custom vanish from the picker.
      --
      -- SPEED: the platform tree is huge (~126k files). We additionally exclude only
      -- COMPILED / VENDORED artifacts (-> ~89k, ~1.8s) WITHOUT hiding a single
      -- editable source file:
      --   *.class/*.jar      : compiled bytecode / packaged libs (never edited).
      --   classes/testclasses: ant build OUTPUT; the originals live in the sibling
      --                        src/ testsrc/ resources/ web/ dirs, so the editable
      --                        copy is always still visible.
      --   eclipsebin         : jdtls/Eclipse compile output (incl. our generated
      --                        .project/.classpath output dirs).
      --   node_modules       : vendored JS deps.
      --   *.sha1/*.prefs     : checksum / IDE metadata noise.
      -- gensrc is deliberately KEPT: it is generated SOURCE you jump into (model beans).
      cmd = "rg --files --color=never --hidden --follow --no-messages " ..
            "-g '!.git' " ..
            "-g '!.idea' " ..
            "-g '!log' " ..
            "-g '!data' " ..
            "-g '!roles' " ..
            "-g '!temp' " ..
            "-g '!**/node_modules/**' " ..
            "-g '!**/classes/**' " ..
            "-g '!**/testclasses/**' " ..
            "-g '!**/eclipsebin/**' " ..
            "-g '!*.class' " ..
            "-g '!*.jar' " ..
            "-g '!*.sha1' " ..
            "-g '!*.prefs' ", -- <== trailing space prevents command corruption

      file_icons = true,
      git_icons = true,
    },

    -- 5. CONTENT SEARCH (Live Grep)
    grep = {
      -- `-L` (== --follow) is load-bearing for the symlinked config/ + bin/custom/.
      -- Mirror the `files` cmd's compiled/vendored exclusions so grepping the whole
      -- tree does not drown in *.class bytecode and node_modules copies.
      rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 " ..
                "--hidden " ..
                "-L " ..
                "-g '!.git' " ..
                "-g '!.idea' " ..
                "-g '!log' " ..
                "-g '!data' " ..
                "-g '!roles' " ..
                "-g '!temp' " ..
                "-g '!**/node_modules/**' " ..
                "-g '!**/classes/**' " ..
                "-g '!**/testclasses/**' " ..
                "-g '!**/eclipsebin/**' " ..
                "-g '!*.class' " ..
                "-g '!*.jar' " ..
                "-g '!*.sha1' " ..
                "-g '!*.prefs' ", -- <== trailing space
    },
  },
}
