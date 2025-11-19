local M = {}

-- =============================================================================
-- CONFIGURATION CONSTANTS
-- =============================================================================

local HYBRIS_ROOT = "/Users/manuel.perez02/Documents/cert/hybriscert/hybris"
local JAVA_21_HOME = "/Users/manuel.perez02/.sdkman/candidates/java/21.0.9-sapmchn"
local JAVA_17_HOME = "/Users/manuel.perez02/.sdkman/candidates/java/17.0.17-sapmchn"

-- JDTLS Paths
local MASON_PATH = os.getenv("HOME") .. "/.local/share/nvim/mason/packages/jdtls"
local JDTLS_JAR = vim.fn.glob(MASON_PATH .. "/plugins/org.eclipse.equinox.launcher_*.jar")
local CONFIG_PATH = MASON_PATH .. "/config_mac"
local LOMBOK_PATH = MASON_PATH .. "/lombok.jar"

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
-- HELPER: READ ECLIPSE METADATA
-- =============================================================================

local function get_eclipse_project_name(path)
    local project_file = path .. "/.project"
    if vim.fn.filereadable(project_file) == 0 then
        return nil, "No .project file"
    end

    local lines = vim.fn.readfile(project_file)
    for _, line in ipairs(lines) do
        local name = line:match("<name>(.-)</name>")
        if name then
            return name:match("^%s*(.-)%s*$"), nil
        end
    end
    return nil, "Name tag not found"
end

-- =============================================================================
-- EXTENSION DISCOVERY
-- =============================================================================

local function resolve_hybris_vars(path_str)
    if not path_str then return nil end
    local bin_dir = HYBRIS_ROOT .. "/bin"
    local config_dir = HYBRIS_ROOT .. "/config"
    
    local resolved = path_str:gsub("%${HYBRIS_BIN_DIR}", bin_dir)
    resolved = resolved:gsub("%${HYBRIS_CONFIG_DIR}", config_dir)
    
    if not resolved:find("^/") then
        resolved = bin_dir .. "/" .. resolved
    end
    resolved = resolved:gsub("//", "/")
    
    if vim.fn.isdirectory(resolved) == 1 then
        return resolved
    else
        return nil
    end
end

local function get_active_extensions()
    log("Parsing localextensions.xml...")
    local xml_path = HYBRIS_ROOT .. "/config/localextensions.xml"
    local extensions = {}
    
    -- Note: We do NOT add platform here automatically anymore.
    -- We handle Platform separately to ensure it is first and validated against bootstrap.

    if vim.fn.filereadable(xml_path) == 0 then
        log("[ERROR] localextensions.xml not found at " .. xml_path)
        return extensions
    end

    local lines = vim.fn.readfile(xml_path)
    for _, line in ipairs(lines) do
        local name = line:match('<extension%s+name=["\']([^"\']+)["\']')
        local dir = line:match('<extension%s+dir=["\']([^"\']+)["\']') or
                    line:match('<path%s+dir=["\']([^"\']+)["\']')

        if dir then
            local full_path = resolve_hybris_vars(dir)
            if full_path then
                local ext_name = vim.fn.fnamemodify(full_path, ":t")
                table.insert(extensions, { name = ext_name, path = full_path })
            end
        elseif name then
            local candidates = {
                HYBRIS_ROOT .. "/bin/custom/" .. name,
                HYBRIS_ROOT .. "/bin/modules/" .. name,
                HYBRIS_ROOT .. "/bin/platform/ext/" .. name
            }
            for _, candidate in ipairs(candidates) do
                if vim.fn.isdirectory(candidate) == 1 then
                    table.insert(extensions, { name = name, path = candidate })
                    break
                end
            end
        end
    end
    return extensions
end

-- =============================================================================
-- WORKSPACE REGISTRATION
-- =============================================================================

local function register_extensions_to_workspace()
    local status, err = pcall(function()
        log("=== Starting Workspace Registration ===")
        -- 1. CRITICAL: Register Platform FIRST
        -- The .classpath is in /bin/platform, but sources are often in /bin/platform/bootstrap
        local platform_root = HYBRIS_ROOT .. "/bin/platform"
        local platform_bootstrap = platform_root .. "/bootstrap"
        if vim.fn.isdirectory(platform_root) == 1 and vim.fn.filereadable(platform_root .. "/.classpath") == 1 then
            local internal_name = get_eclipse_project_name(platform_root)
            log(string.format("Importing [CORE] Platform | Path: %s | Internal Name: '%s'", platform_root, internal_name or "unknown"))
            -- Verify bootstrap existence (per user request) for logging
            if vim.fn.isdirectory(platform_bootstrap .. "/gensrc") == 1 then
                log(" - Verified: bin/platform/bootstrap/gensrc exists.")
            else
                log(" - WARNING: bin/platform/bootstrap/gensrc NOT found.")
            end

            vim.lsp.buf.add_workspace_folder(platform_root)
        else
            log("[CRITICAL ERROR] bin/platform is missing .classpath! Dependencies will fail.")
        end

        -- 2. Register Custom Extensions
        local extensions = get_active_extensions()
        local count = 0
        for _, ext in ipairs(extensions) do
            -- Skip if it's platform (already added)
            if ext.name ~= "platform" then
                local internal_name, name_err = get_eclipse_project_name(ext.path)
                if internal_name then
                    log(string.format("Importing [%s] %s", ext.name, ext.path))
                    vim.lsp.buf.add_workspace_folder(ext.path)
                    count = count + 1
                else
                    -- log(string.format("[SKIP] %s: %s", ext.name, name_err))
                end
            end
        end
        log("=== Registered " .. count .. " extensions ===")
        -- 3. Attempt to refresh buffer to fix 'Non-project file' status
        vim.defer_fn(function() 
            vim.cmd("checktime") 
        end, 200)
    end)

    if not status then
        log("[CRITICAL ERROR] Registration crashed: " .. tostring(err))
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

    -- 1. Workspace Directory
    local root_hash = vim.fn.sha256(HYBRIS_ROOT)
    local workspace_dir = os.getenv("HOME") .. "/.local/share/eclipse/hybris_" .. root_hash

    -- 2. Command
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
        "-javaagent:" .. LOMBOK_PATH,
        "-jar", JDTLS_JAR,
        "-configuration", CONFIG_PATH,
        "-data", workspace_dir,
    }

    -- 3. Configuration
    local config = {
        cmd = cmd,
        root_dir = HYBRIS_ROOT,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        settings = {
            java = {
                eclipse = { downloadSources = true },
                maven = { downloadSources = true },
                implementationsCodeLens = { enabled = true },
                referencesCodeLens = { enabled = true },
                configuration = {
                    runtimes = {
                        { name = "JavaSE-17", path = JAVA_17_HOME, default = true },
                        { name = "JavaSE-21", path = JAVA_21_HOME },
                    }
                }
            }
        },

        init_options = {
            bundles = {},
            extendedClientCapabilities = { resolveAdditionalTextEditsSupport = true },
        },

        on_attach = function(client, bufnr)
            log("JDTLS Client Attached. ID: " .. client.id)

            vim.api.nvim_buf_create_user_command(bufnr, 'JdtlsShowLogs', function()
                vim.cmd("split " .. LOG_FILE)
            end, { desc = "View JDTLS Logs" })

            vim.api.nvim_buf_create_user_command(bufnr, 'JdtlsRetryImport', function()
                register_extensions_to_workspace()
            end, { desc = "Force Import" })

            -- Reduced delay to 500ms to attach faster
            vim.defer_fn(function()
                register_extensions_to_workspace()
            end, 500)
        end,
    }

    require("jdtls").start_or_attach(config)
end

return M
