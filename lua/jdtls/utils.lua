local M = {}

-- Dynamically determine OS and return appropriate jdtls config directory name
function M.get_os_config_dir()
  local uv = vim.uv or vim.loop
  local sysname = uv.os_uname().sysname
  if sysname == "Darwin" then
    return "config_mac"
  elseif sysname:match("Windows") then
    return "config_win"
  else
    return "config_linux"
  end
end

-- Resolve jdtls path, launcher jar, and config folder
function M.get_jdtls_paths()
  local paths = {}
  local config_dir = M.get_os_config_dir()

  -- 1. Check Mason packages path (default)
  local mason_path = vim.fn.stdpath("data") .. "/mason/packages/jdtls"
  if vim.fn.isdirectory(mason_path) == 1 then
    paths.root = mason_path
    paths.launcher = vim.fn.glob(mason_path .. "/plugins/org.eclipse.equinox.launcher_*.jar")
    paths.config = mason_path .. "/" .. config_dir
    return paths
  end

  -- 2. Check Arch Linux /usr/share/java/jdtls (AUR package)
  local arch_path = "/usr/share/java/jdtls"
  if vim.fn.isdirectory(arch_path) == 1 then
    paths.root = arch_path
    paths.launcher = vim.fn.glob(arch_path .. "/plugins/org.eclipse.equinox.launcher_*.jar")
    paths.config = arch_path .. "/" .. config_dir
    return paths
  end

  -- 3. Check env variable MASON_PATH as fallback
  local mason_env = vim.env.MASON_PATH
  if mason_env and vim.fn.isdirectory(mason_env) == 1 then
    paths.root = mason_env
    paths.launcher = vim.fn.glob(mason_env .. "/plugins/org.eclipse.equinox.launcher_*.jar")
    paths.config = mason_env .. "/" .. config_dir
    return paths
  end

  -- Default fallback to standard Mason path configuration
  paths.root = mason_path
  paths.launcher = vim.fn.glob(mason_path .. "/plugins/org.eclipse.equinox.launcher_*.jar")
  paths.config = mason_path .. "/" .. config_dir
  return paths
end

-- Treat empty strings as "unset". `vim.env.FOO` returns nil when a variable is
-- unset but "" when it is exported empty (e.g. `export JAVA_21_HOME=`); the bare
-- `a or b` idiom would wrongly pick the empty string because "" is truthy in Lua.
local function nonempty(v)
  if v and v ~= "" then return v end
  return nil
end

-- Resolve the JDK home jdtls should run on AND register as its JavaSE runtime.
-- Priority: JAVA_21_HOME -> JAVA_HOME -> distro fallback. On this machine
-- JAVA_HOME points at the SDKMAN `current` symlink (~/.sdkman/.../java/current),
-- so "whatever SDKMAN has set as current" is honoured automatically.
function M.get_java_home()
  return nonempty(vim.env.JAVA_21_HOME)
      or nonempty(vim.env.JAVA_HOME)
      or "/usr/lib/jvm/java-21-openjdk"
end

-- Safely get the java executable jdtls is launched with.
function M.get_java_cmd()
  local java_home = M.get_java_home()
  local exe = java_home .. "/bin/java"
  if vim.fn.executable(exe) == 1 then
    return exe
  end
  if vim.fn.executable("java") == 1 then
    return "java"
  end
  return "java"
end

-- Build LSP client capabilities advertising nvim-cmp's completion features.
-- This is what makes jdtls send auto-import edits (resolveSupport.additionalTextEdits)
-- and parameter snippets (snippetSupport) on completion. Without it, completing a
-- type like `Date` inserts the name but NOT `import java.util.Date;`.
-- Falls back to the protocol defaults if cmp-nvim-lsp is not loaded yet.
function M.make_capabilities()
  local caps = vim.lsp.protocol.make_client_capabilities()
  local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
  if ok then
    caps = cmp_lsp.default_capabilities(caps)
  end
  return caps
end

-- Locate a generated schema file named `basename` (e.g. "items.xsd", "beans.xsd",
-- "extensioninfo.xsd") anywhere under `root`. Prefers `fd` (fast, parallel,
-- symlink-aware) and falls back to vim.fs.find. Used to associate Hybris schemas
-- with their XML so lemminx can complete elements, attributes and enums. The
-- generated grammar is identical across extensions, so one representative file
-- per type is enough to drive completion for every matching XML. Returns an
-- absolute path or nil.
function M.find_schema(root, basename)
  if not root or root == "" or not basename or basename == "" then return nil end
  local pattern = "^" .. basename:gsub("%.", "\\.") .. "$"
  if vim.fn.executable("fd") == 1 then
    local res = vim.fn.systemlist({ "fd", "-L", "-t", "f", "-a", "--", pattern, root })
    if vim.v.shell_error == 0 and #res > 0 then
      return res[1]
    end
  end
  local hits = vim.fs.find(basename, { path = root, type = "file", limit = 1 })
  return hits[1]
end

-- Back-compat thin wrapper kept for any external callers.
function M.find_items_xsd(root)
  return M.find_schema(root, "items.xsd")
end

-- Find Lombok jar inside jdtls root or common locations
function M.get_lombok_jar(jdtls_root)
  if jdtls_root and jdtls_root ~= "" then
    local path = jdtls_root .. "/lombok.jar"
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end

  local mason_path = vim.fn.stdpath("data") .. "/mason/packages/jdtls/lombok.jar"
  if vim.fn.filereadable(mason_path) == 1 then
    return mason_path
  end

  local system_path = "/usr/share/java/lombok.jar"
  if vim.fn.filereadable(system_path) == 1 then
    return system_path
  end

  return nil
end


-- Walk upward from `start_path` (inclusive) and return the first ancestor
-- directory that CONTAINS one of the given marker sub-paths.
--
-- NOTE: this intentionally does NOT use `vim.fs.root`. `vim.fs.root` returns
-- `dirname(<matched marker>)`, which is only correct for single-segment markers
-- such as ".git". For a multi-segment marker like "bin/platform" the match is
-- ".../hybris/bin/platform" and its dirname is ".../hybris/bin" -- i.e. the
-- marker's parent, NOT the project root ".../hybris". That off-by-one is what
-- makes Hybris detection resolve to ".../hybris/bin" and then fail the
-- ".../hybris/bin/bin/platform" check. We resolve the root ourselves so
-- multi-segment markers work correctly.
local function find_ancestor_containing(start_path, markers)
  local uv = vim.uv or vim.loop
  local dir = vim.fn.fnamemodify(start_path, ":p"):gsub("/+$", "")
  if dir == "" then dir = "/" end -- a marker living at the filesystem root
  while dir and dir ~= "" do
    for _, sub in ipairs(markers) do
      if uv.fs_stat(dir .. "/" .. sub) then
        return dir
      end
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then break end
    dir = parent
  end
  return nil
end

-- The canonical Hybris *platform* root is the working tree that actually contains
-- bin/platform. Custom extensions are SYMLINKED in from a separate "extensions"
-- repo that has NO bin/platform of its own (only bin/custom + config), so a file
-- opened through its resolved real path has no bin/platform ancestor and the root
-- must be recovered from the environment or the cwd instead.
--   Priority: $HYBRIS_HOME_DIR -> $PLATFORM_HOME -> cwd (or an ancestor of it).
-- Every candidate is validated by the presence of bin/platform so a stray/empty
-- env var can never win. Returns an absolute path or nil.
function M.get_platform_root()
  local function valid(root)
    if root and root ~= "" then
      root = root:gsub("/+$", "")
      if vim.fn.isdirectory(root .. "/bin/platform") == 1 then return root end
    end
    return nil
  end

  -- $HYBRIS_HOME_DIR is the parent of the platform tree (mirrors hybris_setup):
  -- <HYBRIS_HOME_DIR>/hybris is the root. Accept the bare value too, just in case.
  local env_home = nonempty(vim.env.HYBRIS_HOME_DIR)
  if env_home then
    local r = valid(env_home .. "/hybris") or valid(env_home)
    if r then return r end
  end

  -- $PLATFORM_HOME points at <root>/bin/platform (set by setantenv); strip the
  -- trailing "/bin/platform" to recover <root>.
  local ph = nonempty(vim.env.PLATFORM_HOME)
  if ph then
    local r = valid(vim.fn.fnamemodify(ph:gsub("/+$", ""), ":h:h"))
    if r then return r end
  end

  -- The user opens nvim in the working Hybris tree, so cwd (or an ancestor) is the
  -- reliable last resort.
  return find_ancestor_containing(vim.fn.getcwd(), { "bin/platform" })
end

-- Detect whether we are inside a Hybris project or a normal Maven/Gradle one.
-- Returns: project_type ("hybris" | "normal"), root_dir (absolute path)
function M.detect_project(start_override)
  -- start_override (an absolute FILE path) lets callers resolve a project for a
  -- buffer other than the current one (e.g. lemminx root_dir, which is handed the
  -- attaching buffer). Falls back to the current buffer / cwd.
  local buf_name = start_override or vim.api.nvim_buf_get_name(0)
  local start_path = (buf_name ~= "") and vim.fs.dirname(buf_name) or vim.fn.getcwd()

  -- 1. Hybris: the AUTHORITATIVE root is the unique directory that directly
  --    contains bin/platform. Walk up from the file first.
  local hybris_root = find_ancestor_containing(start_path, { "bin/platform" })

  -- 2. Custom extensions live behind a `bin/custom` SYMLINK into a separate repo
  --    that has bin/custom + config/localextensions.xml but NO bin/platform. A file
  --    opened via that resolved real path -- which jdtls "go to definition" yields
  --    -- has no bin/platform ancestor, so the previous marker list ("bin/custom"
  --    or "config/localextensions.xml") anchored the root to the extensions repo
  --    and the bin/platform check in hybris_setup then bailed with
  --    "Could not resolve a valid Hybris root directory". When we are clearly inside
  --    a Hybris tree but cannot see bin/platform above us, recover the real platform
  --    root from env/cwd instead.
  if not hybris_root then
    local in_hybris_ctx = find_ancestor_containing(start_path, {
      "bin/custom",
      "config/localextensions.xml",
      "extensioninfo.xml",
    })
    if in_hybris_ctx then
      local recovered = M.get_platform_root()
      -- get_platform_root() resolves from $HYBRIS_HOME_DIR/$PLATFORM_HOME/cwd, which
      -- is INDEPENDENT of the opened file. Guard against misclassifying an unrelated
      -- project that merely happens to ship an extensioninfo.xml (or a dir named
      -- bin/custom): only treat THIS file as hybris if it actually lives inside the
      -- recovered platform root OR inside that root's (symlinked) bin/custom target
      -- -- the latter is where real custom-extension buffers resolve to.
      if recovered then
        local rstart = vim.fn.resolve(vim.fn.fnamemodify(start_path, ":p")):gsub("/+$", "")
        local rroot = vim.fn.resolve(recovered):gsub("/+$", "")
        local rcustom = vim.fn.resolve(recovered .. "/bin/custom"):gsub("/+$", "")
        local function under(base) return rstart == base or rstart:sub(1, #base + 1) == base .. "/" end
        if under(rroot) or under(rcustom) then
          hybris_root = recovered
        end
      end
    end
  end

  if hybris_root and vim.fn.isdirectory(hybris_root .. "/bin/platform") == 1 then
    return "hybris", hybris_root
  end

  -- 3. Normal Maven/Gradle/Git project.
  local normal_root = find_ancestor_containing(start_path, {
    "pom.xml",
    "build.gradle",
    "gradlew",
    "mvnw",
    ".git",
  })
  if normal_root then
    return "normal", normal_root
  end

  return "normal", vim.fn.getcwd()
end

-- Nearest ancestor directory that IS a Hybris extension root (i.e. directly
-- contains extensioninfo.xml), walking up from `start_path`. Returns the
-- extension directory or nil. Used to scope a per-extension lemminx instance so
-- it stays small and resolves that extension's own generated items/beans schemas.
function M.find_extension_root(start_path)
  if not start_path or start_path == "" then return nil end
  return find_ancestor_containing(start_path, { "extensioninfo.xml" })
end

-- Bind standard LSP and JDTLS-specific keymaps buffer-locally
function M.setup_keymaps(bufnr)
  local opts = { noremap = true, silent = true }

  -- 1. Standard Navigation & Info
  vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = bufnr, desc = "Go to Definition" })
  vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, { buffer = bufnr, desc = "Go to Declaration" })
  vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, { buffer = bufnr, desc = "Go to Implementation" })
  vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = bufnr, desc = "Hover Documentation" })
  vim.keymap.set('i', '<C-k>', vim.lsp.buf.signature_help, { buffer = bufnr, desc = "Signature Help" })
  
  -- FZF-Lua integration for references (every usage of the symbol under cursor)
  vim.keymap.set('n', 'gr', function()
    local ok, fzf = pcall(require, 'fzf-lua')
    if ok then
      fzf.lsp_references({
        jump1 = true,
        ignore_current_line = true,
      })
    else
      vim.lsp.buf.references()
    end
  end, { buffer = bufnr, desc = "References (all usages)" })

  -- Call hierarchy & implementations. Prefer fzf-lua's picker, fall back to the
  -- builtin quickfix-based handlers. Typical flow for "where is this impl used?":
  --   1. on an interface method, `gi` jumps to the implementation(s),
  --   2. on the implementation, `<leader>ji` lists everything that CALLS it.
  local function lsp_pick(fzf_fn, builtin_fn)
    return function()
      local ok, fzf = pcall(require, 'fzf-lua')
      if ok and fzf[fzf_fn] then
        fzf[fzf_fn]()
      else
        builtin_fn()
      end
    end
  end

  vim.keymap.set('n', '<leader>ji',
    lsp_pick('lsp_incoming_calls', vim.lsp.buf.incoming_calls),
    { buffer = bufnr, desc = "Incoming Calls (who calls this)" })
  vim.keymap.set('n', '<leader>jo',
    lsp_pick('lsp_outgoing_calls', vim.lsp.buf.outgoing_calls),
    { buffer = bufnr, desc = "Outgoing Calls (what this calls)" })
  vim.keymap.set('n', '<leader>js',
    lsp_pick('lsp_implementations', vim.lsp.buf.implementation),
    { buffer = bufnr, desc = "Implementations (interface -> impl)" })

  -- 2. Refactoring & Code Actions
  vim.keymap.set({ 'n', 'v' }, '<leader>ca', vim.lsp.buf.code_action, { buffer = bufnr, desc = "Code Actions" })
  vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { buffer = bufnr, desc = "Rename Symbol" })

  -- 3. JDTLS-specific features
  local ok, jdtls = pcall(require, 'jdtls')
  if ok then
    vim.keymap.set('n', '<leader>oi', jdtls.organize_imports, { buffer = bufnr, desc = "Organize Imports" })
    vim.keymap.set('n', '<leader>ev', jdtls.extract_variable, { buffer = bufnr, desc = "Extract Variable" })
    vim.keymap.set('v', '<leader>ev', function() jdtls.extract_variable(true) end, { buffer = bufnr, desc = "Extract Variable" })
    vim.keymap.set('n', '<leader>ec', jdtls.extract_constant, { buffer = bufnr, desc = "Extract Constant" })
    vim.keymap.set('v', '<leader>ec', function() jdtls.extract_constant(true) end, { buffer = bufnr, desc = "Extract Constant" })
    vim.keymap.set('v', '<leader>em', function() jdtls.extract_method(true) end, { buffer = bufnr, desc = "Extract Method" })
    -- Jump to the super / overridden method (e.g. impl method -> interface decl).
    vim.keymap.set('n', '<leader>jp', jdtls.super_implementation, { buffer = bufnr, desc = "Go to Super / Parent Implementation" })
  end

  -- 4. which-key buffer-local group names for the JDTLS maps. Registered
  -- per-buffer so they only show up inside Java files.
  local ok_wk, wk = pcall(require, 'which-key')
  if ok_wk then
    wk.add({
      { '<leader>e', group = "Extract / Refactor", mode = { 'n', 'v' }, buffer = bufnr },
      { '<leader>j', group = "Java / Navigation", buffer = bufnr },
    })
  end
end

return M
