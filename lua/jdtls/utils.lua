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

-- Safely get the java command from environment or PATH
function M.get_java_cmd()
  local java_home = vim.env.JAVA_21_HOME or vim.env.JAVA_HOME
  if java_home and java_home ~= "" then
    local exe = java_home .. "/bin/java"
    if vim.fn.executable(exe) == 1 then
      return exe
    end
  end
  if vim.fn.executable("java") == 1 then
    return "java"
  end
  return "java"
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

-- Detect whether we are inside a Hybris project or a normal Maven/Gradle one.
-- Returns: project_type ("hybris" | "normal"), root_dir (absolute path)
function M.detect_project()
  local buf_name = vim.api.nvim_buf_get_name(0)
  local start_path = (buf_name ~= "") and vim.fs.dirname(buf_name) or vim.fn.getcwd()

  -- 1. Hybris: the root is the directory that directly contains bin/platform.
  --    (bin/custom and config/localextensions.xml resolve to the same root.)
  local hybris_root = find_ancestor_containing(start_path, {
    "bin/platform",
    "config/localextensions.xml",
    "bin/custom",
  })
  if hybris_root then
    return "hybris", hybris_root
  end

  -- 2. Normal Maven/Gradle/Git project.
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

-- Bind standard LSP and JDTLS-specific keymaps buffer-locally
function M.setup_keymaps(bufnr)
  local opts = { noremap = true, silent = true }

  -- 1. Standard Navigation & Info
  vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = bufnr, desc = "Go to Definition" })
  vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, { buffer = bufnr, desc = "Go to Declaration" })
  vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, { buffer = bufnr, desc = "Go to Implementation" })
  vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = bufnr, desc = "Hover Documentation" })
  vim.keymap.set('i', '<C-k>', vim.lsp.buf.signature_help, { buffer = bufnr, desc = "Signature Help" })
  
  -- FZF-Lua integration for references
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
  end, { buffer = bufnr, desc = "FZF LSP References" })

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
  end

  -- 4. which-key buffer-local group name for the JDTLS extract/refactor maps.
  -- Registered per-buffer so it only shows up inside Java files.
  local ok_wk, wk = pcall(require, 'which-key')
  if ok_wk then
    wk.add({
      { '<leader>e', group = "Extract / Refactor", mode = { 'n', 'v' }, buffer = bufnr },
    })
  end
end

return M
