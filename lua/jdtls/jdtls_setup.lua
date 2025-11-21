local M = {}

-- =============================================================================
-- CONFIGURATION CONSTANTS
-- =============================================================================

local HYBRIS_ROOT = "/Users/manuel.perez02/Documents/cert/hybriscert/hybris"
local JAVA_21_HOME = "/Users/manuel.perez02/.sdkman/candidates/java/21.0.9-sapmchn"

-- JDTLS Paths
local MASON_PATH = os.getenv("HOME") .. "/.local/share/nvim/mason/packages/jdtls"
local JDTLS_JAR = vim.fn.glob(MASON_PATH .. "/plugins/org.eclipse.equinox.launcher_*.jar")
local CONFIG_PATH = MASON_PATH .. "/config_mac"

-- Logging
local LOG_FILE = os.getenv("HOME") .. "/jdtls_nvim.log"

-- =============================================================================
-- LOGGING UTILITIES
-- =============================================================================

local function clear_log()
    local file = io.open(LOG_FILE, "w")
    if file then
        file:write(os.date("!%Y-%m-%dTH%M%S") .. " - [INIT] Log cleared.\n")
        file:close()
    end
end

local function log(msg)
    local file = io.open(LOG_FILE, "a")
    if file then
        file:write(os.date("!%Y-%m-%dTH%M%S") .. " - " .. msg .. "\n")
        file:close()
    end
end

-- =============================================================================
-- SIMPLIFIED EXTENSION FINDER
-- =============================================================================

local function get_hybris_extensions_workspace_paths()
    log("Parsing localextensions.xml for optimized path resolution...")

    local config_file = HYBRIS_ROOT .. "/config/localextensions.xml"
    local f = io.open(config_file, "r")
    if not f then return {} end

    local xml_content = f:read("*a")
    f:close()

    local active_extensions = {}
    local resolved_paths = {}

    for line in xml_content:gmatch("[^\r\n]+") do
        if not line:match("^%s*<!%-%-") then
            local ext_name = line:match('<extension%s+name="([^"]+)"')
            if ext_name then
                active_extensions[ext_name] = true
            end

            local explicit_dir = line:match('<path%s+dir="([^"]+)"')
            if explicit_dir then
                local full_path = explicit_dir:gsub("${HYBRIS_BIN_DIR}", HYBRIS_ROOT .. "/bin")
                local derived_name = full_path:match("([^/]+)$")
                active_extensions[derived_name] = full_path -- Store directly as path
            end
        end
    end

    local function find_extension_path(name)
        local search_dirs = {
            HYBRIS_ROOT .. "/bin/custom/",
            HYBRIS_ROOT .. "/bin/modules/",
        }

        for _, search_base in ipairs(search_dirs) do
            local cmd = string.format("find %s -maxdepth 3 -type d -name '%s' -print -quit", search_base, name)
            local path = vim.fn.system(cmd)

            path = path:gsub("%s+", "")

            if path ~= "" then
                return path
            end
        end
        return nil
    end

    for name, value in pairs(active_extensions) do
        local path = value

        if type(value) ~= "string" then
            path = find_extension_path(name)

            if not path then
                log("warning: [" .. name .. "] listed in config but not found in /bin/custom or /bin/modules.")
            end
        end

        if path and path ~= "" then
            log("Local Extension Defined (Name): [" .. name .. "] -> " .. path)
            resolved_paths[name] = path
        end
    end

    local path_list = {}
    table.insert(path_list, HYBRIS_ROOT)
    table.insert(path_list, HYBRIS_ROOT .. "/bin/platform")

    for _, path in pairs(resolved_paths) do
        table.insert(path_list, path)
    end

    return path_list
end

local function get_current_extension_root()
    local current_file = vim.api.nvim_buf_get_name(0)
    if current_file == "" then return nil end

    local lines = vim.api.nvim_buf_get_lines(0, 0, 20, false)
    local chunk = table.concat(lines, "\n")

    local pkg_name = chunk:match("package%s+([%w%.]+);")

    if not pkg_name then
        return nil
    end

    local pkg_path = pkg_name:gsub("%.", "/")

    local idx = current_file:find(pkg_path, 1, true)

    if not idx then
        log("Error: File path does not match package declaration.")
        return nil
    end

    -- 4. Extract the 'Source Root' by cutting the string at the index
    -- Input:  /hybris/bin/custom/myext/src/com/my/commerce/core/File.java
    -- Cut at 'com/...'
    -- Result: /hybris/bin/custom/myext/src/
    local source_root = current_file:sub(1, idx - 1)

    source_root = source_root:gsub("/$", "")

    local extension_root = vim.fn.fnamemodify(source_root, ":h")

    if vim.fn.filereadable(extension_root .. "/.classpath") == 1 then
        local ext_name = vim.fn.fnamemodify(extension_root, ":t")

        log("--- Extension Detected (Fast Jump) ---")
        log("Name: " .. ext_name)
        log("Path: " .. extension_root)
        log("--------------------------------------")
        return extension_root
    else
        -- Edge Case: Sometimes structure is 'myext/web/src'. 
        -- If .classpath isn't found, try one level higher.
        local parent_up = vim.fn.fnamemodify(extension_root, ":h")
        if vim.fn.filereadable(parent_up .. "/.classpath") == 1 then
            return parent_up
        end

        log("Warning: Calculated root " .. extension_root .. " has no .classpath")
        return nil
    end
end

-- =============================================================================
-- JDTLS SETUP
-- =============================================================================

function M.setup()
    clear_log()
    log("Initializing JDTLS Setup for SAP Commerce...")
    if vim.fn.isdirectory(JAVA_21_HOME) == 0 then
        vim.notify("JDTLS Error: Java 21 not found", vim.log.levels.ERROR)
        return
    end

    -- 1. Workspace Directory (Cache)
    local root_hash = vim.fn.sha256(HYBRIS_ROOT)
    local workspace_dir = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/hybris_" .. root_hash

    -- 2. Resolve Extension Paths
    local active_local_extensions = get_hybris_extensions_workspace_paths()
    local extension_root = get_current_extension_root()

    -- 3. Generate Workspace Folders (Unique & Prefixed with file://)
    local workspace_folders_gen = {}
    local seen_paths = {}

    -- Helper to ensure we don't add duplicate folders
    local function add_workspace_folder(path)
        if path and path ~= "" and not seen_paths[path] then
            table.insert(workspace_folders_gen, "file://" .. path)
            seen_paths[path] = true
        end
    end

    -- A. Priority: Root and Platform
    add_workspace_folder(HYBRIS_ROOT)
    add_workspace_folder(HYBRIS_ROOT .. "/bin/platform")

    -- B. Priority: Current detected extension (where I am editing now)
    if extension_root then
        add_workspace_folder(extension_root)
    end

    -- C. Priority: All other active extensions from config
    for _, path in ipairs(active_local_extensions) do
        add_workspace_folder(path)
    end

    log("Total workspace folders loaded: " .. #workspace_folders_gen)

    -- 4. Command
    local cmd = {
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
    }

    -- 5. Configuration
    local config = {
        cmd = cmd,
        root_dir = HYBRIS_ROOT,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        settings = {
            java = {
                signatureHelp = { enabled = true },
                configuration = {
                    runtimes = {
                        { name = "JavaSE-21", path = JAVA_21_HOME },
                    }
                },
                import = {
                    gradle = { enabled = true },
                    maven = { enabled = true }
                },
            },
        },
        init_options = {
            bundles = {},
            workspaceFolders = workspace_folders_gen
        },
        on_attach = function (client)
            log("JDTLS Client Attached. ID: " .. client.id)

            local folders = client.workspace_folders
            if folders then
                log("Workspace folders confirmed by client: " .. #folders)
            else
                log("No workspace folders detected by client.")
            end
        end
    }
    require("jdtls").start_or_attach(config)
end

return M
