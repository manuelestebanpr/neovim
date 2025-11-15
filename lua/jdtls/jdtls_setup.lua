local M = {}

function M:setup()
    -- 1. Determine OS-specific paths
    local path_sep = package.config:sub(1,1)
    local os_name = vim.loop.os_uname().sysname
    local config_dir_name

    if os_name == "Darwin" then
        config_dir_name = "config_mac"
    elseif os_name == "Linux" then
        config_dir_name = "config_linux"
    elseif os_name:match("Windows") then
        config_dir_name = "config_win"
    else
        vim.notify("Unsupported OS for jdtls: " .. os_name, vim.log.levels.ERROR)
        return
    end

    -- 2. Get the jdtls installation path from mason
    local jdtls_install_path = vim.fn.stdpath("data") .. path_sep .. "mason" .. path_sep .. "packages" .. path_sep .. "jdtls"

    -- 3. Find the launcher JAR dynamically
    local launcher_jar = vim.fn.glob(jdtls_install_path .. path_sep .. "plugins" .. path_sep .. "org.eclipse.equinox.launcher_*.jar")
    
    -- 4. Set the *correct* dynamic configuration path
    local config_path = jdtls_install_path .. path_sep .. config_dir_name

    -- ----------------------------------------------------------------------
    -- DEBUGGING: PRINT THE PATHS
    -- ----------------------------------------------------------------------
    --    vim.notify("JDTLS Launcher JAR: " .. vim.fn.trim(launcher_jar), vim.log.levels.INFO, { title = "JDTLS Debug" })
    --  vim.notify("JDTLS Config Path: " .. config_path, vim.log.levels.INFO, { title = "JDTLS Debug" })
    -- ----------------------------------------------------------------------

    if launcher_jar == "" or launcher_jar == nil then
        vim.notify("ERROR: jdtls launcher JAR not found.", vim.log.levels.ERROR)
        return
    end
    local config = {
        cmd = {
            "/Users/manuel.perez02/.sdkman/candidates/java/current/bin/java",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.protocol=true",
            "-Dlog.level=WARN",
            "-Xmx1g",
            "-jar",
            vim.fn.trim(launcher_jar),
            "-configuration",
            config_path,
        },
        settings = {
            java = {},
        },
        init_options = {
            bundles = {},
        },
    }

    local root_dir = require("jdtls.setup").find_root({ ".git", ".project", "build.xml" })
    if not root_dir then
        return
    end

    local project_name = vim.fn.fnamemodify(root_dir, ':t')
    local workspace_dir = vim.fn.stdpath("data") .. path_sep .. "jdtls-workspace" .. path_sep .. project_name

    config.root_dir = root_dir
    table.insert(config.cmd, "-data")
    table.insert(config.cmd, workspace_dir)

    require("jdtls").start_or_attach(config)
end

return M
