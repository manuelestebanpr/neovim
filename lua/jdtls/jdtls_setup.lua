local M = {}

-- =============================================================================
-- 1. CONFIGURATION CONSTANTS
-- =============================================================================
-- Custom file location TODO: need to update this so its loaded from .env
--
local HYBRIS_ROOT = vim.env.HYBRIS_HOME_DIR .. "/hybris"
local JAVA_21_HOME = vim.env.JAVA_21_HOME
-- JDTLS Paths
local MASON_PATH = os.getenv("HOME") .. "/.local/share/nvim/mason/packages/jdtls"
local JDTLS_JAR = vim.fn.glob(MASON_PATH .. "/plugins/org.eclipse.equinox.launcher_*.jar")
local CONFIG_PATH = MASON_PATH .. "/config_mac"

-- Logging
local LOG_FILE = os.getenv("HOME") .. "/jdtls_nvim.log"

-- Cache for filesystem lookups
local PATH_CACHE = {}

-- =============================================================================
-- 2. UTILITIES (LOGGING & I/O)
-- =============================================================================

local function clear_log()
    local file = io.open(LOG_FILE, "w")
    if file then
        file:write(os.date("!%Y-%m-%dTH%M%S") .. " - [INIT] Log cleared.\n")
        file:close()
    end
end

local function log(msg, indent_level)
    local file = io.open(LOG_FILE, "a")
    if not file then return end

    local indent = indent_level and (string.rep("  ", indent_level) .. "↳ ") or ""
    file:write(os.date("!%Y-%m-%dTH%M%S") .. " - " .. indent .. msg .. "\n")
    file:close()
end

--- Optimized Pure Lua File Copy (Avoids os.execute shell spawn)
local function copy_file_lua(src, dest)
    local infile = io.open(src, "rb")
    if not infile then return false end
    local content = infile:read("*a")
    infile:close()

    local outfile = io.open(dest, "wb")
    if not outfile then return false end
    outfile:write(content)
    outfile:close()
    return true
end

-- =============================================================================
-- 3. FILESYSTEM & PARSING
-- =============================================================================

local function resolve_extension_path_fs(ext_name)
    if PATH_CACHE[ext_name] then return PATH_CACHE[ext_name] end

    local search_dirs = {
        HYBRIS_ROOT .. "/bin/custom/",
        HYBRIS_ROOT .. "/bin/modules/",
    }

    for _, search_base in ipairs(search_dirs) do
        local cmd = string.format("find %s -maxdepth 3 -type d -name '%s' -print -quit", search_base, ext_name)
        local path = vim.fn.system(cmd):gsub("%s+", "")

        if path ~= "" then
            PATH_CACHE[ext_name] = path
            return path
        end
    end

    PATH_CACHE[ext_name] = nil
    return nil
end

local function get_required_extensions(extension_path)
    local f = io.open(extension_path .. "/extensioninfo.xml", "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()

    local requires = {}
    for name in content:gmatch('<requires%-extension[^>]*name="([^"]+)"') do
        table.insert(requires, name)
    end
    return requires
end

local function get_local_extensions_map()
    local f = io.open(HYBRIS_ROOT .. "/config/localextensions.xml", "r")
    if not f then return {} end
    local xml_content = f:read("*a")
    f:close()

    local active_map = {}
    for line in xml_content:gmatch("[^\r\n]+") do
        if not line:match("^%s*<!%-%-") then
            local ext_name = line:match('<extension%s+name="([^"]+)"')
            if ext_name then active_map[ext_name] = true end

            local explicit_dir = line:match('<path%s+dir="([^"]+)"')
            if explicit_dir then
                local full_path = HYBRIS_ROOT .. "/bin"
                local derived_name = full_path:match("([^/]+)$")
                active_map[derived_name] = full_path
                PATH_CACHE[derived_name] = full_path
            end
        end
    end
    return active_map
end

-- =============================================================================
-- 4. RECURSIVE DEPENDENCY RESOLVER
-- =============================================================================

local function resolve_dependencies_recursive(ext_name, collected_paths, visited, local_ext_map, level)
    if visited[ext_name] then return end
    visited[ext_name] = true

    local path = local_ext_map[ext_name]
    if type(path) ~= "string" then
        path = resolve_extension_path_fs(ext_name)
    end

    if not path then
        log("Warning: Dependency [" .. ext_name .. "] not found.", level)
        return
    end

    if not collected_paths[path] then
        collected_paths[path] = true
        log("Resolved: [" .. ext_name .. "]", level)
    end

    for _, child_name in ipairs(get_required_extensions(path)) do
        resolve_dependencies_recursive(child_name, collected_paths, visited, local_ext_map, level + 1)
    end
end

-- =============================================================================
-- 5. CLASSPATH PARCHER FOR .classpath files
-- =============================================================================
local function inject_classpath_dependencies(target_ext_path, dependency_paths)
    local classpath_file = target_ext_path .. "/.classpath"
    local backup_file = target_ext_path .. "/.classpath.nvim_bak"

    -- 1. Idempotency: Restore backup if exists, else create one
    if vim.fn.filereadable(backup_file) == 1 then
        copy_file_lua(backup_file, classpath_file)
    else
        copy_file_lua(classpath_file, backup_file)
    end

    local f = io.open(classpath_file, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    -- 2. Generate Entries
    local entries_list = {}
    table.insert(entries_list, '\n\t')

    for path, _ in pairs(dependency_paths) do
        if path ~= target_ext_path
            and path ~= HYBRIS_ROOT
            and path ~= (HYBRIS_ROOT .. "/bin/platform")
            and path ~= (HYBRIS_ROOT .. "/bin/modules") then

            -- Use Project Name only (Linked Resource style)
            local ext_name = vim.fn.fnamemodify(path, ":t")
            local entry = string.format('\t<classpathentry exported="false" kind="src" path="/%s" />', ext_name)
            table.insert(entries_list, entry)
        end
    end

    table.insert(entries_list, '\t\n')

    -- 3. Inject & Write
    local injection_str = table.concat(entries_list, "\n")
    local new_content = content:gsub("</classpath>", injection_str .. "</classpath>")

    local fw = io.open(classpath_file, "w")
    if fw then
        fw:write(new_content)
        fw:close()
        log("Injected dependencies into .classpath (Excluding platform/root/modules).")
    end
end
-- =============================================================================
-- 6. JDTLS SETUP
-- =============================================================================

function M.setup()
    clear_log()
    log("Initializing Optimized JDTLS Setup...")

    if vim.fn.isdirectory(JAVA_21_HOME) == 0 then
        return vim.notify("JDTLS Error: Java 21 not found", vim.log.levels.ERROR)
    end

    -- Context Detection
    local current_file = vim.api.nvim_buf_get_name(0)
    local current_ext_path = nil
    local current_ext_name = nil

    if current_file ~= "" then
        local root = vim.fs.root(current_file, {".classpath", "extensioninfo.xml"})
        if root then
            current_ext_path = root
            current_ext_name = vim.fn.fnamemodify(root, ":t")
            log("Context: " .. current_ext_name)
        end
    end

    -- Cache Config
    local root_hash = vim.fn.sha256(HYBRIS_ROOT .. (current_ext_name or "global"))
    local workspace_dir = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/hybris_" .. root_hash

    -- Dependency Resolution
    local local_ext_map = get_local_extensions_map()
    local all_paths = {}

    -- Always include Platform & Root
    all_paths[HYBRIS_ROOT] = true
    all_paths[HYBRIS_ROOT .. "/bin/platform"] = true

    -- Include Local Extensions
    for name, val in pairs(local_ext_map) do
        local path = (type(val) == "string") and val or resolve_extension_path_fs(name)
        if path then all_paths[path] = true end
    end

    -- Recursive Dependencies (If inside an extension)
    if current_ext_path then
        all_paths[current_ext_path] = true
        resolve_dependencies_recursive(current_ext_name, all_paths, {}, local_ext_map, 0)
        inject_classpath_dependencies(current_ext_path, all_paths)
    end

    -- Workspace Folders Generation
    local workspace_folders = {}
    for path, _ in pairs(all_paths) do
        table.insert(workspace_folders, "file://" .. path)
    end
    log("Workspace Folders: " .. #workspace_folders)

    -- Start JDTLS
    require("jdtls").start_or_attach({
        cmd = {
            JAVA_21_HOME .. "/bin/java",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.protocol=true",
            "-Dlog.level=ALL",
            "-Xmx4g",
            "--add-modules=ALL-SYSTEM",
            "--add-opens", "java.base/java.util=ALL-UNNAMED",
            "--add-opens", "java.base/java.lang=ALL-UNNAMED",
            "-jar", JDTLS_JAR,
            "-configuration", CONFIG_PATH,
            "-data", workspace_dir,
        },
        root_dir = HYBRIS_ROOT,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        settings = {
            java = {
                signatureHelp = { enabled = true },
                contentProvider = { preferred = "fernflower" },
                configuration = {
                    runtimes = { { name = "JavaSE-21", path = JAVA_21_HOME } }
                },
            },
        },
        init_options = {
            bundles = {},
            workspaceFolders = workspace_folders
        },
        on_attach = function(client, bufnr)

            log("JDTLS Attached. ID: " .. client.id)

            local function restore_classpath()
                local current_buf_name = vim.api.nvim_buf_get_name(bufnr)
                local root = vim.fs.root(current_buf_name, {".classpath.nvim_bak"})

                if root then
                    local src = root .. "/.classpath.nvim_bak"
                    local dest = root .. "/.classpath"

                    if copy_file_lua(src, dest) then
                        vim.notify("Success: .classpath restored from backup.", vim.log.levels.INFO)
                        log("Manual Restore: .classpath restored for " .. root)
                    else
                        vim.notify("Error: Failed to restore .classpath.", vim.log.levels.ERROR)
                    end
                else
                    vim.notify("No backup (.classpath.nvim_bak) found for this project.", vim.log.levels.WARN)
                end
            end

            vim.keymap.set("n", "<leader>cld", restore_classpath, {
                buffer = bufnr,
                desc = "Restore original .classpath (remove injected dependencies)"
            })

        end
    })
end

return M
