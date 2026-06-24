local M = {}
local utils = require('jdtls.utils')

function M.setup(detected_root)
  -- =============================================================================
  -- 1. PATH CONFIGURATION (Mason/System & Workspace)
  -- =============================================================================
  local paths = utils.get_jdtls_paths()
  if not paths.launcher or paths.launcher == "" then
    vim.notify("JDTLS launcher JAR not found. Please install jdtls via Mason (:MasonInstall jdtls) or check your system installation.", vim.log.levels.ERROR, { title = "JDTLS Setup Error" })
    return
  end
  local java_cmd = utils.get_java_cmd()


  local root_dir = detected_root or vim.fs.root(0, { '.git', 'mvnw', 'gradlew', 'pom.xml' }) or vim.fn.getcwd()
  local project_name = vim.fn.fnamemodify(root_dir, ':p:h:t')
  local workspace_dir = os.getenv("HOME") .. "/.cache/jdtls/workspace/" .. vim.fn.sha256(root_dir):sub(1, 8) .. "_" .. project_name

  -- =============================================================================
  -- 2. JDTLS CONFIGURATION
  -- =============================================================================
  local cmd = {
    java_cmd,
    "-Declipse.application=org.eclipse.jdt.ls.core.id1",
    "-Dosgi.bundles.defaultStartLevel=4",
    "-Declipse.product=org.eclipse.jdt.ls.core.product",
    "-Dlog.protocol=true",
    "-Dlog.level=ALL",
    "-Xmx2g",
    "-XX:+UseG1GC",
    "-Djava.import.generatesMetadataFilesAtProjectRoot=false",
  }

  local lombok_jar = utils.get_lombok_jar(paths.root)
  if lombok_jar then
    table.insert(cmd, "-javaagent:" .. lombok_jar)
  end

  table.insert(cmd, "--add-modules=ALL-SYSTEM")
  table.insert(cmd, "--add-opens")
  table.insert(cmd, "java.base/java.util=ALL-UNNAMED")
  table.insert(cmd, "--add-opens")
  table.insert(cmd, "java.base/java.lang=ALL-UNNAMED")
  
  -- Dynamic Paths
  table.insert(cmd, "-jar")
  table.insert(cmd, paths.launcher)
  table.insert(cmd, "-configuration")
  table.insert(cmd, paths.config)
  
  -- Workspace Data
  table.insert(cmd, "-data")
  table.insert(cmd, workspace_dir)

  local java_home = utils.get_java_home()

  local config = {
    cmd = cmd,

    root_dir = root_dir,

    -- Advertise nvim-cmp completion features so completing a type also inserts
    -- its `import ...;` (additionalTextEdits) and method completions carry
    -- parameter snippets. extendedClientCapabilities unlocks jdtls extras
    -- (decompiled class navigation, resolved organize-imports, etc.).
    capabilities = utils.make_capabilities(),

    init_options = {
      bundles = {},
      extendedClientCapabilities = require('jdtls').extendedClientCapabilities,
    },

    settings = {
      java = {
        signatureHelp = { enabled = true },
        contentProvider = { preferred = "fernflower" },
        -- Tell jdtls which JDK to compile/index against. Without a registered
        -- runtime, java.lang/java.util resolution can silently fall back or
        -- break; this pins it to the SDKMAN `current` JDK (see utils.get_java_home).
        configuration = {
          runtimes = { { name = "JavaSE-21", path = java_home, default = true } },
        },
        completion = {
          -- Fill method calls with placeholder args (snippet) instead of just `()`.
          guessMethodArguments = true,
          favoriteStaticMembers = {
            "org.hamcrest.MatcherAssert.assertThat",
            "org.hamcrest.Matchers.*",
            "org.hamcrest.CoreMatchers.*",
            "org.junit.jupiter.api.Assertions.*",
            "java.util.Objects.requireNonNull",
            "java.util.Objects.requireNonNullElse",
            "org.mockito.Mockito.*"
          },
          filteredTypes = {
            "com.sun.*",
            "sun.*",
            "jdk.*",
            "org.graalvm.*",
            "oracle.*"
          }
        },
        sources = {
          organizeImports = {
            starThreshold = 9999,
            staticStarThreshold = 9999,
          }
        }
      }
    },

    on_attach = function(client, bufnr)
      -- Bind keymaps and code actions
      utils.setup_keymaps(bufnr)

      local msg = string.format(
        "Attached to: %s\nRoot: %s",
        project_name,
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
