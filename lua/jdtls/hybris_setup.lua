local M = {}
local jdtls = require('jdtls')
local utils = require('jdtls.utils')

-- =============================================================================
-- 1. CONFIGURATION
-- =============================================================================

local CONF = {}
local REAL_CUSTOM_PATH = nil

local function init_paths(hybris_root)
  if CONF.HYBRIS_ROOT then return end

  if not hybris_root then
    local env_root = vim.env.HYBRIS_HOME_DIR
    if env_root then
      hybris_root = env_root .. "/hybris"
    else
      local _, root = utils.detect_project()
      hybris_root = root
    end
  end

  CONF.HYBRIS_ROOT = hybris_root

  local hybris_dir_name = vim.fn.fnamemodify(CONF.HYBRIS_ROOT, ":h:t")
  if hybris_dir_name == "" or hybris_dir_name == "/" then
    hybris_dir_name = "hybris_project"
  end

  local paths = utils.get_jdtls_paths()

  CONF.JAVA_CMD = utils.get_java_cmd()
  CONF.JAVA_HOME = vim.env.JAVA_21_HOME or vim.env.JAVA_HOME or "/usr/lib/jvm/java-21-openjdk"
  CONF.WORKSPACE_DATA = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/" .. hybris_dir_name
  CONF.CONFIG_PATH = paths.config
  CONF.JDTLS_JAR = paths.launcher

  local logical_custom = CONF.HYBRIS_ROOT .. "/bin/custom"
  if vim.fn.isdirectory(logical_custom) == 1 then
    local resolved = vim.fn.resolve(logical_custom)
    REAL_CUSTOM_PATH = vim.fn.fnamemodify(resolved, ":p"):gsub("/+$", "")
  else
    REAL_CUSTOM_PATH = nil
  end
end

local STATE = {
  name_to_path = {},
  workspace_folders = {},
  processed_exts = {},
}

-- =============================================================================
-- 2. I/O UTILS
-- =============================================================================

local function read_file_content(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- =============================================================================
-- 3. XML PARSING & DEPENDENCIES
-- =============================================================================

-- Parses extensioninfo.xml to find <requires-extension> entries
local function get_dependencies(ext_path)
  local xml_path = ext_path .. "/extensioninfo.xml"
  local content = read_file_content(xml_path)
  if not content then return {} end

  content = content:gsub("<!%-%-(.-)%-%->", "") -- Remove comments safely

  local deps = {}
  for name in content:gmatch('<requires%-extension[^>]-name=["\']([^"\']+)["\']') do
    table.insert(deps, name)
  end

  return deps
end

-- Recursively resolves deps: populates workspace (global) and dependency tree (local)
local function resolve_dependencies_recursive(ext_name, accumulated_deps)
  local ext_path = STATE.name_to_path[ext_name]

  -- Handle platform special case if path not found in map
  if not ext_path and ext_name == "platform" then
    ext_path = CONF.HYBRIS_ROOT .. "/bin/platform"
  end

  if not ext_path then return end

  -- [Requirement 1 & 2] If this ext isn't in workspace yet, add it now
  if not STATE.processed_exts[ext_name] then
    STATE.processed_exts[ext_name] = true
    table.insert(STATE.workspace_folders, "file://" .. ext_path)
  end

  -- Traverse dependencies regardless of workspace state to build full tree
  local immediate_deps = get_dependencies(ext_path)

  for _, dep_name in ipairs(immediate_deps) do
    if not accumulated_deps[dep_name] then
      accumulated_deps[dep_name] = true -- Mark visited for this recursion chain
      resolve_dependencies_recursive(dep_name, accumulated_deps)
    end
  end
end

-- =============================================================================
-- 4. CLASSPATH INJECTION
-- =============================================================================

local function update_classpath(ext_name, dependencies)
  local ext_path = STATE.name_to_path[ext_name]
  if not ext_path then return end

  --  Standard: Path contains "/bin/custom/" anywhere
  --  Linked: Path matches the resolved physical custom path
  local is_standard_custom = ext_path:find("/bin/custom/", 1, true)
  local is_linked_custom = REAL_CUSTOM_PATH and ext_path:find(REAL_CUSTOM_PATH, 1, true)

  if not (is_standard_custom or is_linked_custom) then return end

  local classpath_file = ext_path .. "/.classpath"
  if vim.fn.filereadable(classpath_file) == 0 then return end

  -- 1. Create Backup
  local backup_file = ext_path .. "/.classpath.nvim_bak"
  if vim.fn.filereadable(backup_file) == 0 then
    vim.fn.writefile(vim.fn.readfile(classpath_file), backup_file)
    vim.notify("Backed up .classpath for " .. ext_name, vim.log.levels.DEBUG)
  end

  -- 2. Read lines
  local lines = vim.fn.readfile(classpath_file)
  local file_content_str = table.concat(lines, "\n")
  local new_lines = {}
  local injected_count = 0

  -- 3. Prepare entries
  local entries_to_add = {}
  for dep_name, _ in pairs(dependencies) do
    if dep_name ~= ext_name and dep_name ~= "platform" then
      local entry_str = string.format('\t<classpathentry exported="false" kind="src" path="/%s" />', dep_name)
      if not string.find(file_content_str, 'path="/' .. dep_name .. '"', 1, true) then
        table.insert(entries_to_add, entry_str)
      end
    end
  end

  if #entries_to_add == 0 then return end

  -- 4. Inject
  for _, line in ipairs(lines) do
    if string.find(line, "</classpath>") then
      for _, entry in ipairs(entries_to_add) do
        table.insert(new_lines, entry)
        injected_count = injected_count + 1
      end
      table.insert(new_lines, line)
    else
      table.insert(new_lines, line)
    end
  end

  if injected_count > 0 then
    vim.fn.writefile(new_lines, classpath_file)
    vim.notify(string.format("Updated %s: Added %d transitive dependencies.", ext_name, injected_count), vim.log.levels.INFO)
  end
end

-- =============================================================================
-- 5. ORCHESTRATOR
-- =============================================================================

local function prepare_workspace()
  vim.notify("Building Extension Map & Resolving Workspace...", vim.log.levels.INFO)

  -- Reset State
  STATE.workspace_folders = {}
  STATE.processed_exts = {}
  STATE.name_to_path = {}

  -- 1. Build Global Map: Find ALL extensions in /bin (recursively)
  -- This creates a master list of every available extension in the system.
  local cmd = string.format("fd -L -t f -F 'extensioninfo.xml' --absolute-path . %s/bin", CONF.HYBRIS_ROOT)
  local results = vim.fn.systemlist(cmd)

  for _, xml_path in ipairs(results) do
    local ext_path = vim.fs.dirname(xml_path)
    local ext_name = vim.fn.fnamemodify(ext_path, ":t")
    STATE.name_to_path[ext_name] = ext_path
  end

  -- 2. PASS 1: Force Load ALL Custom Extensions & Inject Classpaths
  -- We iterate the map first to ensure everything in /custom/ is added to the workspace,
  -- regardless of whether it appears in localextensions.xml.
  vim.notify("Scanning and Injecting Classpaths for ALL Custom Extensions...", vim.log.levels.INFO)

  for name, path in pairs(STATE.name_to_path) do
    local is_standard_custom = path:find("/bin/custom/", 1, true)
    local is_linked_custom = REAL_CUSTOM_PATH and path:find(REAL_CUSTOM_PATH, 1, true)

    if is_standard_custom or is_linked_custom then
      -- 1. Calculate dependencies specifically for this extension
      local custom_deps = {} 

      -- 2. Add to workspace (and recursive dependencies) if not already present
      resolve_dependencies_recursive(name, custom_deps)

      -- 3. Update the .classpath file
      update_classpath(name, custom_deps)
    end
  end

  -- 3. PASS 2: Fill gaps using localextensions.xml
  -- This catches platform extensions or standard modules (like smartedit, solr) 
  -- that are enabled but live outside /custom/.
  resolve_dependencies_recursive("platform", {}) 

  local logical_config = CONF.HYBRIS_ROOT .. "/config"
  local resolved_config = vim.fn.resolve(logical_config)
  local local_ext_path = resolved_config .. "/localextensions.xml"

  local content = read_file_content(local_ext_path)
  if content then
    content = content:gsub("<!%-%-(.-)%-%->", "")
    for ext_name in content:gmatch('<extension[^>]-name=["\']([^"\']+)["\']') do
      -- If the custom extension loop (Pass 1) already added this, 
      -- STATE.processed_exts will prevent duplicates efficiently.
      resolve_dependencies_recursive(ext_name, {})
    end
  end
end

-- =============================================================================
-- 6. SETUP
-- =============================================================================

function M.setup(detected_root)
  init_paths(detected_root)

  if not CONF.HYBRIS_ROOT or vim.fn.isdirectory(CONF.HYBRIS_ROOT .. "/bin/platform") == 0 then
    vim.notify("Could not resolve a valid Hybris root directory. Ensure you are in a Hybris project.", vim.log.levels.ERROR, { title = "JDTLS Hybris Setup Error" })
    return
  end

  if not CONF.JDTLS_JAR or CONF.JDTLS_JAR == "" then
    vim.notify("JDTLS launcher JAR not found. Please install jdtls via Mason (:MasonInstall jdtls) or check your system installation.", vim.log.levels.ERROR, { title = "JDTLS Setup Error" })
    return
  end

  prepare_workspace()

  local cmd = {
    CONF.JAVA_CMD,
    "-Declipse.application=org.eclipse.jdt.ls.core.id1",
    "-Dosgi.bundles.defaultStartLevel=4",
    "-Declipse.product=org.eclipse.jdt.ls.core.product",
    "-Dlog.protocol=true",
    "-Dlog.level=ALL",
    "-Xmx4g",
    "-XX:+UseG1GC",
    "-Djava.import.generatesMetadataFilesAtProjectRoot=false",
  }

  local lombok_jar = utils.get_lombok_jar(CONF.JDTLS_JAR and vim.fn.fnamemodify(CONF.JDTLS_JAR, ":h:h"))
  if lombok_jar then
    table.insert(cmd, "-javaagent:" .. lombok_jar)
  end

  table.insert(cmd, "--add-modules=ALL-SYSTEM")
  table.insert(cmd, "--add-opens")
  table.insert(cmd, "java.base/java.util=ALL-UNNAMED")
  table.insert(cmd, "--add-opens")
  table.insert(cmd, "java.base/java.lang=ALL-UNNAMED")
  table.insert(cmd, "-jar")
  table.insert(cmd, CONF.JDTLS_JAR)
  table.insert(cmd, "-configuration")
  table.insert(cmd, CONF.CONFIG_PATH)
  table.insert(cmd, "-data")
  table.insert(cmd, CONF.WORKSPACE_DATA)

  jdtls.start_or_attach({
    cmd = cmd,
    root_dir = CONF.HYBRIS_ROOT,
    init_options = {
      bundles = {},
      workspaceFolders = STATE.workspace_folders,
    },
    settings = {
      java = {
        signatureHelp = { enabled = true },
        contentProvider = { preferred = "fernflower" },
        autobuild = { enabled = false },
        import = {
          gradle = { enabled = false },
          maven = { enabled = false },
          exclusions = {
            "**/node_modules/**",
            "**/.git/**",
            "**/bower_components/**",
            "**/dist/**"
          },
        },
        configuration = {
          runtimes = { { name = "JavaSE-21", path = CONF.JAVA_HOME, default = true } }
        }
      }
    },
    on_attach = function(client, bufnr)
      -- Bind keymaps and code actions buffer-locally
      utils.setup_keymaps(bufnr)

      client.config.settings = vim.tbl_deep_extend('force', client.config.settings, {
        files = {
          exclude = {
            ["**/.git"] = true,
            ["**/node_modules"] = true,
            ["**/bower_components"] = true,
            ["**/dist"] = true,
            ["**/tmp"] = true,
            ["**/.classpath.nvim_bak"] = true
          }
        }
      })
      vim.notify("JDTLS Attached (Hybris). Workspace size: " .. #STATE.workspace_folders, vim.log.levels.INFO)
    end
  })
end

function M.restore_backups()
  init_paths()
  if not CONF.HYBRIS_ROOT or vim.fn.isdirectory(CONF.HYBRIS_ROOT .. "/bin/platform") == 0 then
    vim.notify("Could not resolve Hybris root directory. Ensure you are in a Hybris project.", vim.log.levels.ERROR)
    return
  end
  local cmd = string.format("fd -L -H -t f '.classpath.nvim_bak$' --absolute-path %s", CONF.HYBRIS_ROOT)
  local backups = vim.fn.systemlist(cmd)
  if #backups == 0 then
    vim.notify("No .classpath backups found to restore.", vim.log.levels.INFO)
    return
  end
  for _, bak in ipairs(backups) do
    local original = bak:gsub("%.nvim_bak$", "")
    vim.fn.rename(bak, original)
  end
  vim.notify("Restored all .classpath files.", vim.log.levels.INFO)
end

return M
