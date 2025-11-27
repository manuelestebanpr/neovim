local M = {}

-- =============================================================================
-- 1. CONFIGURATION & CONSTANTS
-- =============================================================================

local CONF = {
    -- Environment Variables
    HYBRIS_ROOT = vim.env.HYBRIS_HOME_DIR and (vim.env.HYBRIS_HOME_DIR .. "/hybris") or nil,
    JAVA_HOME = vim.env.JAVA_21_HOME,

    -- JDTLS Paths
    MASON_PATH = vim.fn.stdpath("data") .. "/mason/packages/jdtls",
    LOG_FILE = os.getenv("HOME") .. "/jdtls_hybris.log",

    -- Single Workspace Location (Ensures only one JDTLS instance ever runs)
    WORKSPACE_DATA = os.getenv("HOME") .. "/.local/share/nvim/sapcommerce/hybris_global_data",
}

-- Computed Paths
CONF.JDTLS_JAR = vim.fn.glob(CONF.MASON_PATH .. "/plugins/org.eclipse.equinox.launcher_*.jar")
CONF.CONFIG_PATH = CONF.MASON_PATH .. "/config_mac" -- Change to config_linux if on Linux

-- Global Cache
local CACHE = {
    scanned = false,
    workspace_folders = {}, -- List of "file://..." strings
    extension_map = {},     -- name -> path string
}


function M.setup()
    require("jdtls").start_or_attach({
        cmd = {
            CONF.JAVA_HOME .. "/bin/java",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.protocol=true",
            "-Dlog.level=ALL",

            -- PERFORMANCE SETTINGS
            "-Xmx4g",                    -- Huge heap for Hybris
            "-XX:+UseG1GC",              -- Better GC for large heaps
            "-XX:+UseStringDeduplication", -- Hybris has tons of duplicate strings (XML)
            "-XX:MaxMetaspaceSize=1g",

            "--add-modules=ALL-SYSTEM",
            "--add-opens", "java.base/java.util=ALL-UNNAMED",
            "--add-opens", "java.base/java.lang=ALL-UNNAMED",
            "-jar", CONF.JDTLS_JAR,
            "-configuration", CONF.CONFIG_PATH,

            -- SINGLE WORKSPACE DATA LOCATION
            "-data", CONF.WORKSPACE_DATA,
        },
        -- FORCE SINGLE ROOT
        root_dir = CONF.HYBRIS_ROOT,

        capabilities = require('cmp_nvim_lsp').default_capabilities(),

        init_options = {
            bundles = {},
            -- Load ALL known extensions so references work across projects
            workspaceFolders = CACHE.workspace_folders
        },

        settings = {
            java = {
                signatureHelp = { enabled = true },
                contentProvider = { preferred = "fernflower" },
                -- Don't auto-build entire world immediately, wait for interaction
                autobuild = { enabled = false },
                import = {
                    gradle = { enabled = false },
                    maven = { enabled = false },
                },
                configuration = {
                    runtimes = { { name = "JavaSE-21", path = CONF.JAVA_HOME } }
                }
            }
        },

        on_attach = function(client, bufnr)
            print("Attached to buffer: " .. vim.api.nvim_buf_get_name(bufnr))
            -- Setup Shutdown Logic
            setup_autoshutdown(client.id)
        end
    })
end

return M
