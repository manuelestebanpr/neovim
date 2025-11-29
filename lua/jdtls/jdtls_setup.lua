local M = {}

function M.setup()
  -- =============================================================================
  -- 1. PATH CONFIGURATION (Mason & Workspace)
  -- =============================================================================

local CONF = {
    JAVA_HOME = vim.env.JAVA_21_HOME,
}

  local mason_path = vim.fn.stdpath("data") .. "/mason/packages/jdtls"
  local launcher_jar = vim.fn.glob(mason_path .. "/plugins/org.eclipse.equinox.launcher_*.jar")
  local config_path = mason_path .. "/config_mac" 

  local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ':p:h:t')
  local workspace_dir = os.getenv("HOME") .. "/.cache/jdtls/workspace/" .. project_name

  -- =============================================================================
  -- 2. JDTLS CONFIGURATION
  -- =============================================================================
  
  local config = {
    cmd = {
      CONF.JAVA_HOME .. "/bin/java",
      "-Declipse.application=org.eclipse.jdt.ls.core.id1",
      "-Dosgi.bundles.defaultStartLevel=4",
      "-Declipse.product=org.eclipse.jdt.ls.core.product",
      "-Dlog.protocol=true",
      "-Dlog.level=ALL",
      "-Xmx1g",
      "--add-modules=ALL-SYSTEM",
      "--add-opens", "java.base/java.util=ALL-UNNAMED",
      "--add-opens", "java.base/java.lang=ALL-UNNAMED",
      
      -- Mason Paths
      "-jar", launcher_jar,
      "-configuration", config_path,
      
      -- Workspace Data
      "-data", workspace_dir
    },

    root_dir = vim.fs.root(0, {'.git', 'mvnw', 'gradlew', 'pom.xml'}),

    init_options = {
      bundles = {}
    },

    settings = {
      java = {
      }
    },

    on_attach = function(client, bufnr)
      local msg = string.format(
        "Client ID: %s\nRoot: %s",
        client.id,
        client.config.root_dir
      )
      
      vim.notify(msg, vim.log.levels.INFO, {
        title = "JDTLS Attached",
        timeout = 3000
      })
    end
  }

  require('jdtls').start_or_attach(config)
end

return M
