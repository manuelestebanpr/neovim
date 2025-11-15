local M = {}

-- 💀 CUSTOM LOGGER 💀
local log_file = os.getenv("HOME") .. "/jdtls_nvim.log"
local function log(msg)
    local file = io.open(log_file, "a")
    if file then
        file:write(os.date("!%Y-%m-%dT%H:%M:%S").." - " .. msg .. "\n")
        file:close()
    end
end

function M:setup()
    -- Clear the log file on setup
    io.open(log_file, "w"):close()
    log("JDTLS setup initiated...")

    -- 1. 💀 EXPLICIT ROOT on 'platform' 💀
    local path_sep = package.config:sub(1,1)
    local config_dir_name = "config_mac"
    local root_dir = "/Users/manuel.perez02/Documents/cert/hybriscert/hybris/bin/platform"
    log("Root directory set to: " .. root_dir)

    -- 2. Get the jdtls installation path
    local jdtls_install_path = vim.fn.stdpath("data") .. path_sep .. "mason" .. path_sep .. "packages" .. path_sep .. "jdtls"

    -- 3. Find the launcher JAR
    local launcher_jar = vim.fn.glob(jdtls_install_path .. path_sep .. "plugins" .. path_sep .. "org.eclipse.equinox.launcher_*.jar")
    if launcher_jar == "" or launcher_jar == nil then
        log("ERROR: jdtls launcher JAR not found.")
        vim.notify("ERROR: jdtls launcher JAR not found.", vim.log.levels.ERROR)
        return
    end
    log("Launcher JAR found: " .. launcher_jar)
    -- 4. Set the configuration path
    local config_path = jdtls_install_path .. path_sep .. config_dir_name
    log("Config path set to: " .. config_path)

    -- 5. Calculate the workspace
    local project_name = vim.fn.fnamemodify(root_dir, ':t') -- Now 'platform'
    local workspace_dir = vim.fn.stdpath("data") .. path_sep .. "jdtls-workspace" .. path_sep .. project_name
    log("Workspace dir set to: " .. workspace_dir)

    -- 6. Define the base config
    local config = {
        cmd = {
            "/Users/manuel.perez02/.sdkman/candidates/java/21.0.9-sapmchn/bin/java",
            "-debug",
            "-Dlog.level=TRACE",
            "--add-modules=ALL-SYSTEM",
            "--add-opens",
            "java.base/java.util=ALL-UNNAMED",
            "--add-opens",
            "java.base/java.lang=ALL-UNNAMED",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.protocol=true",
            "-Xmx1g",
            "-jar",
            vim.fn.trim(launcher_jar),
            "-configuration",
            config_path,
            "-data",
            workspace_dir,
        },

        root_dir = root_dir, -- Rooted on 'platform'

        settings = {
            java = {},
        },
        init_options = {
            bundles = {},
        },

        -- 💀 ON_ATTACH WITH THE *NATIVE* JDTLS IMPORT COMMAND 💀
        on_attach = function(client, bufnr)
            log("on_attach hook triggered for buffer: " .. bufnr)
            vim.defer_fn(function()
                log("defer_fn callback started.")
                if not client.config.flags or not client.config.flags.did_import_projects then
                    log("Import guard passed. Starting project import...")
                    if not client.config.flags then client.config.flags = {} end
                    client.config.flags.did_import_projects = true -- Mark as "running"

                    vim.notify("JDTLS: Starting SAP project import...", vim.log.levels.INFO)

                    local workspace_root = vim.fn.fnamemodify(client.config.root_dir, ":h")
                    log("Workspace root (one level up) set to: " .. workspace_root)

                    local folders_to_scan = { "platform", "custom", "modules" }
                    local total_projects_found = 0

                    for _, folder_name in ipairs(folders_to_scan) do
                        log("Scanning folder: " .. folder_name)
                        local search_path = workspace_root .. path_sep .. folder_name
                        local pattern = "**" .. path_sep .. ".project"
                        local project_files = vim.fn.globpath(search_path, pattern, false, true)
                        log("Found " .. #project_files .. " projects in " .. folder_name)

                        if #project_files > 0 then
                            for _, file_path in ipairs(project_files) do
                                local project_dir = vim.fn.fnamemodify(file_path, ':h')
                                -- 💀 THIS IS THE FIX 💀
                                -- We use the server's native command, not a vim.lsp command
                                local project_uri = vim.uri_from_fname(project_dir)
                                -- This tells jdtls to "import" the project
                                client.request("java.project.import", { uri = project_uri }, function(err, result)
                                    if err then
                                        log("ERROR importing " .. project_dir .. ": " .. vim.inspect(err))
                                    else
                                        -- This log will now confirm success
                                        log("Successfully imported: " .. project_dir)
                                    end
                                end)
                            end
                            total_projects_found = total_projects_found + #project_files
                        end
                    end

                    log("Total projects sent to import: " .. total_projects_found)
                    vim.notify(
                        "JDTLS: Sent " .. total_projects_found .. " projects to server for import.",
                        vim.log.levels.INFO
                    )
                else
                    log("Import guard FAILED. Projects already imported or import in progress.")
                end
            end, 10000) -- Increased to 10 seconds
        end,
    }

    -- 7. Start the server
    log("Starting jdtls server...")
    require("jdtls").start_or_attach(config)
end

return M
