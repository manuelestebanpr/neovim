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
CONF.CONFIG_PATH = CONF.MASON_PATH .. "/config_mac"

-- Global Cache
local CACHE = {
    scanned = false,
    workspace_folders = {},
    extension_map = {},
}

-- Shutdown Timer Storage
local shutdown_timer = nil
-- =============================================================================
-- 3. PERFORMANCE SCANNER (PLATFORM + MODULES + CUSTOM)
-- =============================================================================

local function get_extension_name(path)
    return vim.fn.fnamemodify(path, ":t")
end

local function load_hybris_ecosystem()
    if CACHE.scanned then return end

    vim.notify("Starting Full Hybris Ecosystem Scan...")

    -- 1. Add Platform (Manually)
    local platform_path = CONF.HYBRIS_ROOT .. "/bin/platform"
    if vim.fn.isdirectory(platform_path) == 1 then
        CACHE.extension_map["platform"] = platform_path
        table.insert(CACHE.workspace_folders, "file://" .. platform_path)
    end

    -- 2. Fast Scan Function (using system find for speed on huge dirs)
    local function fast_scan(base_path, depth)
        if vim.fn.isdirectory(base_path) == 0 then return end

        -- Optimizing find: exclude .git, exclude resources, look only for directory containing extensioninfo.xml
        local cmd = string.format(
            "find %s -maxdepth %d -type f -name 'extensioninfo.xml' -print", 
            base_path, depth
        )

        local results = vim.fn.systemlist(cmd)
        for _, xml_path in ipairs(results) do
            local ext_path = vim.fs.dirname(xml_path)
            local ext_name = get_extension_name(ext_path)

            -- Avoid duplicates
            if not CACHE.extension_map[ext_name] then
                CACHE.extension_map[ext_name] = ext_path
                table.insert(CACHE.workspace_folders, "file://" .. ext_path)
            end
        end
    end

    -- Scan Custom (Priority)
    fast_scan(CONF.HYBRIS_ROOT .. "/bin/custom", 3)

    -- Scan Modules (Heavy)
    fast_scan(CONF.HYBRIS_ROOT .. "/bin/modules", 4)

    CACHE.scanned = true
    vim.notify(string.format("Scan Complete. Loaded %d extensions.", #CACHE.workspace_folders))
end

-- =============================================================================
-- 4. DEPENDENCY INJECTION
-- =============================================================================

local function get_requirements(ext_path)
    local xml_file = ext_path .. "/extensioninfo.xml"
    if vim.fn.filereadable(xml_file) == 0 then return {} end

    -- Read file (safely join lines to handle multi-line tags)
    local content = table.concat(vim.fn.readfile(xml_file), " ")
    local requires = {}
    for name in content:gmatch('<requires%-extension[^>]*name="([^"]+)"') do
        table.insert(requires, name)
    end
    return requires
end

local function resolve_recursive_deps(ext_name, visited, result_paths)
    if visited[ext_name] then return end
    visited[ext_name] = true

    local path = CACHE.extension_map[ext_name]
    if not path then return end -- Dependency not found in workspace

    result_paths[path] = true

    local children = get_requirements(path)
    for _, child in ipairs(children) do
        resolve_recursive_deps(child, visited, result_paths)
    end
end

local function inject_classpath(target_path)
    local classpath_file = target_path .. "/.classpath"
    local backup_file = target_path .. "/.classpath.nvim_bak"

    -- Create backup if not exists
    if vim.fn.filereadable(backup_file) == 0 then
        copy_file(classpath_file, backup_file)
    end
    -- ALWAYS restore from backup first to ensure clean state
    copy_file(backup_file, classpath_file)

    -- Calculate Dependencies
    local ext_name = get_extension_name(target_path)
    local deps_paths = {}
    resolve_recursive_deps(ext_name, {}, deps_paths)

    -- Generate XML entries
    local entries = {}
    for path, _ in pairs(deps_paths) do
        local name = get_extension_name(path)
        if name ~= ext_name and name ~= "platform" and name ~= "hybris" then
            table.insert(entries, string.format('\t<classpathentry exported="false" kind="src" path="/%s" />', name))
        end
    end

    -- Write changes
    local lines = vim.fn.readfile(classpath_file)
    local new_lines = {}
    local injected = false

    for _, line in ipairs(lines) do
        if line:match("</classpath>") then
            for _, entry in ipairs(entries) do
                table.insert(new_lines, entry)
            end
            table.insert(new_lines, line)
            injected = true
        else
            table.insert(new_lines, line)
        end
    end

    if injected then
        vim.fn.writefile(new_lines, classpath_file)
        vim.notify("Injected dependencies for: " .. ext_name)
    end
end

-- =============================================================================
-- 5. AUTO SHUTDOWN MANAGER
-- =============================================================================

local function setup_autoshutdown(client_id)
    vim.api.nvim_create_autocmd("LspDetach", {
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client or client.id ~= client_id then return end

            -- Check how many buffers are still attached to this client
            local attached_buffers = 0
            for _, buf in pairs(vim.api.nvim_list_bufs()) do
                if vim.lsp.buf_is_attached(buf, client_id) then
                    attached_buffers = attached_buffers + 1
                end
            end

            -- If 0 buffers (Note: current buffer is detaching, so count might technically be 1 inside the event, 
            -- but we check if others exist). 
            -- Better check: Active buffers count.
            if attached_buffers <= 1 then -- <= 1 because the current one is detaching
                if shutdown_timer then shutdown_timer:stop() end

                vim.notify("No active buffers. Starting 20s shutdown timer...")
                shutdown_timer = vim.defer_fn(function()
                    -- Re-check just in case user opened a file quickly
                    local still_attached = 0
                    for _, buf in pairs(vim.api.nvim_list_bufs()) do
                        if vim.lsp.buf_is_attached(buf, client_id) then
                            still_attached = still_attached + 1
                        end
                    end

                    if still_attached == 0 then
                        vim.notify("Timeout reached. Stopping JDTLS.")
                        client.stop(client, true)
                    else
                        vim.notify("Shutdown aborted. New buffer attached.")
                    end
                end, 20000) -- 20 seconds
            end
        end
    })

    vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
            if args.data.client_id == client_id then
                if shutdown_timer then
                    vim.notify("Buffer attached. Cancelling shutdown timer.")
                    shutdown_timer:stop()
                    shutdown_timer = nil
                end
            end
        end
    })
end

-- =============================================================================
-- 6. RESTORE CLASSPATH FUNCTION 
-- =============================================================================

-- Public function to be used globally
function M.restore_backups()
    if not CONF.HYBRIS_ROOT then
        vim.notify("HYBRIS_ROOT not set, cannot restore backups.", vim.log.levels.ERROR)
        return
    end

    local custom_dir = CONF.HYBRIS_ROOT .. "/bin/custom"

    -- 1. Find all backup files
    local cmd = string.format("find %s -type f -name '.classpath.nvim_bak'", custom_dir)
    local backups = vim.fn.systemlist(cmd)

    if #backups == 0 then
        vim.notify("No .classpath backups found in /bin/custom", vim.log.levels.WARN)
        return
    end

    local count = 0
    for _, backup_file in ipairs(backups) do
        local target_file = backup_file:gsub("%.nvim_bak$", "")
        local content = vim.fn.readfile(backup_file)

        if vim.fn.writefile(content, target_file) == 0 then
            count = count + 1
            -- Optional: Remove backup after restore?
            -- vim.fn.delete(backup_file) 
        end
    end

    vim.notify("Restored " .. count .. " .classpath files.", vim.log.levels.INFO)
end

-- =============================================================================
-- 6. MAIN SETUP
-- =============================================================================

function M.setup()
    if not CONF.HYBRIS_ROOT or not CONF.JAVA_HOME then
        return vim.notify("Error: Env Vars HYBRIS_HOME_DIR or JAVA_21_HOME missing", vim.log.levels.ERROR)
    end

    -- 1. Initialize Workspace Cache (One time scan)
    load_hybris_ecosystem()

    -- 2. Determine Current Context
    local current_buf_name = vim.api.nvim_buf_get_name(0)
    -- Find the extension folder for the current file
    local current_ext_path = nil

    -- Helper to find which cached path this file belongs to
    -- We iterate finding the longest matching path prefix
    local longest_match_len = 0
    for _, path in pairs(CACHE.extension_map) do
        if current_buf_name:sub(1, #path) == path and #path > longest_match_len then
            current_ext_path = path
            longest_match_len = #path
        end
    end

    -- If inside hybris but not a specific extension, fallback to root
    if not current_ext_path then
        if current_buf_name:find(CONF.HYBRIS_ROOT, 1, true) then
            -- Valid hybris file, but maybe in config folder or root
            vim.notify("File in Hybris root/config, generic attach.")
        else
            return -- Not a hybris file
        end
    else
        -- 3. Inject Dependencies for THIS extension immediately
        inject_classpath(current_ext_path)
    end

    -- 4. Start JDTLS
    -- KEY FIX: We force 'root_dir' to be HYBRIS_ROOT. 
    -- This makes Neovim reuse the same client for all Hybris files.

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
            vim.notify("Attached to buffer: " .. vim.api.nvim_buf_get_name(bufnr))
            setup_autoshutdown(client.id)
        end
    })
end

return M
