local M = {}

-- =============================================================================
-- CONFIGURATION CONSTANTS
-- =============================================================================

local HYBRIS_ROOT = "/Users/manolo/Documents/sapcommerce/hybriscert/hybris"
local JAVA_21_HOME = "/Users/manolo/.sdkman/candidates/java/21.0.9-sapmchn"

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
    local workspace_dir = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/hybris_" .. root_hash

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
        "-jar", JDTLS_JAR,
        "-configuration", CONFIG_PATH,
        "-data", workspace_dir,
    }

    -- 3. Configuration
    local config = {
        cmd = cmd,
        root_dir = HYBRIS_ROOT, -- This is the project root for LSP client
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
                    gradle =  {
                        enabled = true
                    },
                    maven =  {
                        enabled =  true
                    }
                },
            },
        },
        init_options = {
            bundles = {},
            workspaceFolders = {
                "file://" .. HYBRIS_ROOT,
                "file://" .. HYBRIS_ROOT .. "/bin/platform",
             --   "file://" .. HYBRIS_ROOT .. "/bin/modules/",
                "file://" .. HYBRIS_ROOT .. "/bin/custom/trainingflexiblesearch",
                "file://" .. HYBRIS_ROOT .. "/bin/custom/dev"
            }
        },
        on_attach = function (client, bufnr)
            log("JDTLS Client Attached. ID: " .. client.id)

            local folders = client.workspace_folders
            if folders then
                log("Workspace folders loaded: " .. #folders)
            else
                log("No workspace folders detected by client.")
            end
        end

    }
    require("jdtls").start_or_attach(config)
end

return M
