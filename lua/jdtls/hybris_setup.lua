local M = {}
local jdtls = require('jdtls')

-- =============================================================================
-- 1. CONFIGURATION
-- =============================================================================

local hybris_home = vim.env.HYBRIS_HOME_DIR
local hybris_dir_name = hybris_home and vim.fn.fnamemodify(hybris_home, ":t") or "hybris_project"

local CONF = {
  HYBRIS_ROOT = hybris_home and (hybris_home .. "/hybris") or nil,
  JAVA_HOME = vim.env.JAVA_21_HOME,
  WORKSPACE_DATA = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/" .. hybris_dir_name,
  CONFIG_PATH = vim.env.MASON_PATH .. "/config_mac",
  JDTLS_JAR = vim.fn.glob(vim.env.MASON_PATH .. "/plugins/org.eclipse.equinox.launcher_*.jar"),
}

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

local function get_dependencies(ext_path)
  local xml_path = ext_path .. "/extensioninfo.xml"
  local content = read_file_content(xml_path)
  if not content then return {} end

  -- 1. Sanitize Comments (Handle multi-line comments safely)
  -- We remove anything between non-greedily
  content = content:gsub("<!%-%-(.-)%-%->", "")

  -- 2. Extract Requires
  local deps = {}
  -- Pattern matches <requires-extension ... name="VALUE" ... >
  for name in content:gmatch('<requires%-extension[^>]-name=["\']([^"\']+)["\']') do
    table.insert(deps, name)
  end

  return deps
end

-- Resolve dependencies recursively.
-- IMPORTANT: This function now serves two purposes:
-- 1. Populates STATE.workspace_folders (so JDTLS knows where the code is).
-- 2. Returns a Set (table) of ALL transitive dependencies for the caller.
local function resolve_dependencies_recursive(ext_name, accumulated_deps)
  -- If we've already processed this extension for the global workspace list, we still
  -- might need to return its dependencies for the current caller's classpath.

  local ext_path = STATE.name_to_path[ext_name]
  if not ext_path then
    if ext_name == "platform" then 
      ext_path = CONF.HYBRIS_ROOT .. "/bin/platform"
    else
      return
    end
  end

  -- Add to Global Workspace (if not already there)
  -- We use a separate check because STATE.processed_exts is global context
  if not STATE.processed_exts[ext_name] then
    STATE.processed_exts[ext_name] = true
    table.insert(STATE.workspace_folders, "file://" .. ext_path)
  end

  -- Get immediate deps
  local immediate_deps = get_dependencies(ext_path)

  for _, dep_name in ipairs(immediate_deps) do
    -- If we haven't seen this dependency in the current recursion chain:
    if not accumulated_deps[dep_name] then
      accumulated_deps[dep_name] = true

      -- Recurse: Go deeper to find the grandchildren
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

  -- STRICT CHECK: Only update Custom extensions. 
  if not ext_path:find("/bin/custom") then return end

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
    -- Filter out self, platform (usually implicit or handled via container), and broken links
    if dep_name ~= ext_name and dep_name ~= "platform" then

      local entry_str = string.format('\t<classpathentry exported="false" kind="src" path="/%s" />', dep_name)

      -- Check if entry already exists (string match)
      -- We use plain matching to avoid regex special char issues with paths
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
  vim.notify("Building Extension Map...", vim.log.levels.INFO)

  -- Reset State on reload
  STATE.workspace_folders = {}
  STATE.processed_exts = {}

  local cmd = string.format("fd -t f -F 'extensioninfo.xml' --absolute-path . %s/bin", CONF.HYBRIS_ROOT)
  local results = vim.fn.systemlist(cmd)

  for _, xml_path in ipairs(results) do
    local ext_path = vim.fs.dirname(xml_path)
    local ext_name = vim.fn.fnamemodify(ext_path, ":t")
    STATE.name_to_path[ext_name] = ext_path
  end

  -- Ensure Platform is in workspace
  resolve_dependencies_recursive("platform", {})

  -- Read localextensions.xml
  local local_ext_path = CONF.HYBRIS_ROOT .. "/config/localextensions.xml"
  local content = read_file_content(local_ext_path)

  if content then
    content = content:gsub("<!%-%-(.-)%-%->", "") -- Remove comments

    for ext_name in content:gmatch('<extension[^>]-name=["\']([^"\']+)["\']') do

      -- 1. Recursively find deps for THIS specific extension
      -- We pass a fresh table `extension_specific_deps` to capture the full tree for THIS extension
      local extension_specific_deps = {} 
      resolve_dependencies_recursive(ext_name, extension_specific_deps)

      -- 2. Update .classpath with the full list (children + grandchildren)
      update_classpath(ext_name, extension_specific_deps)
    end
  end
end

-- =============================================================================
-- 6. SETUP
-- =============================================================================

function M.setup()
  if not CONF.HYBRIS_ROOT then 
    vim.notify("HYBRIS_HOME_DIR not set", vim.log.levels.ERROR) 
    return 
  end

  prepare_workspace()

  jdtls.start_or_attach({
    cmd = {
      CONF.JAVA_HOME .. "/bin/java",
      "-Declipse.application=org.eclipse.jdt.ls.core.id1",
      "-Dosgi.bundles.defaultStartLevel=4",
      "-Declipse.product=org.eclipse.jdt.ls.core.product",
      "-Dlog.protocol=true",
      "-Dlog.level=ALL",
      "-Xmx4g",
      "-XX:+UseG1GC",
      "--add-modules=ALL-SYSTEM",
      "--add-opens", "java.base/java.util=ALL-UNNAMED",
      "--add-opens", "java.base/java.lang=ALL-UNNAMED",
      "-jar", CONF.JDTLS_JAR,
      "-configuration", CONF.CONFIG_PATH,
      "-data", CONF.WORKSPACE_DATA,
    },
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
            "**/dist/**",
            "**/tmp/**",
            "**/jalo/**"
          },
        },
        configuration = {
          runtimes = { { name = "JavaSE-21", path = CONF.JAVA_HOME, default = true } }
        }
      }
    },
    on_attach = function(client, _)
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
      client.notify("JDTLS Attached. Workspace size: " .. #STATE.workspace_folders, vim.log.levels.INFO)
    end
  })
end

function M.restore_backups()
  local cmd = string.format("fd -H -t f '.classpath.nvim_bak$' --absolute-path %s", CONF.HYBRIS_ROOT)
  local backups = vim.fn.systemlist(cmd)
  for _, bak in ipairs(backups) do
    local original = bak:gsub("%.nvim_bak$", "")
    vim.fn.rename(bak, original)
  end
  vim.notify("Restored all .classpath files.", vim.log.levels.INFO)
end

return M
