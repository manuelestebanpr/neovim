local M = {}

-- 💀 CUSTOM LOGGER 💀
local log_file = os.getenv("HOME") .. "/jdtls_nvim.log"
local function log(msg)
  local file = io.open(log_file, "a")
  if file then
    file:write(os.date("!%Y-%m-%dTH%M%S").." - " .. msg .. "\n")
    file:close()
  end
end

-- Helper function to find all JARs in a directory (still useful for external deps)
local function get_jars_in_dir(directory_path)
  local jars = {}
  if vim.fn.isdirectory(directory_path) == 1 then
    local find_jars_cmd = "find " .. vim.fn.shellescape(directory_path) .. " -name '*.jar' -print 2>/dev/null"
    local handle = io.popen(find_jars_cmd)
    if handle then
      for jar_path in handle:lines() do
        table.insert(jars, jar_path)
      end
      handle:close()
    end
  end
  return jars
end


function M:setup()
  -- Clear the log file on setup
  io.open(log_file, "w"):close()
  log("JDTLS setup initiated...")

  local path_sep = package.config:sub(1,1)
  local config_dir_name = "config_mac"

  -- Define the root of your Hybris installation
  local hybris_root = "/Users/manolo/Documents/sapcommerce/hybriscert/hybris"
  log("Hybris root: " .. hybris_root)

  -- Define the root of your 'dev' extension
  local dev_extension_root = hybris_root .. path_sep .. "bin" .. path_sep .. "custom" .. path_sep .. "dev"
  log("Dev extension root: " .. dev_extension_root)

  -- Define the JDTLS workspace directory (specific to this multi-project setup)
  local workspace_dir = vim.fn.stdpath("data") .. path_sep .. "jdtls-workspace" .. path_sep .. "hybris_dev_platform"
  log("JDTLS workspace directory set to: " .. workspace_dir)

  -- ** NEW: Project Configuration Data **
  local projects_config = {
    -- Configuration for your 'dev' custom extension
    {
      name = "dev", -- Logical name for the project
      path = dev_extension_root, -- Root directory of the extension
      sourcePaths = {
        dev_extension_root .. path_sep .. "src",
      },
      outputPath = dev_extension_root .. path_sep .. "classes",
      -- Explicitly list JARs within the dev extension's lib
      rawClasspath = get_jars_in_dir(dev_extension_root .. path_sep .. "lib"),
      projectReferences = {
        "platform" -- CRITICAL: Declare dependency on the 'platform' project
      },
      javaCore = {
        compiler = {
            compliance = {
                '17', '17'
            }
        }
      },
      defaultJRE = {
        '/Users/manolo/.sdkman/candidates/java/17.0.17-sapmchn'
      }
    },
    -- Configuration for the Hybris 'platform' itself
    {
      name = "platform", -- Logical name for the platform project
      path = hybris_root .. path_sep .. "bin" .. path_sep .. "platform", -- Root directory for the platform's Java code
      sourcePaths = {
        hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "gensrc", -- Generated sources
        hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "ext" .. path_sep .. "core" .. path_sep .. "src",
        hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "ext" .. path_sep .. "servicelayer" .. path_sep .. "src",
      },
      outputPath = hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "classes", -- Platform's compiled classes (if any, often extensions)
      rawClasspath = (function() -- Using an immediately invoked function to build the classpath
        local classpath = {}

        -- Add JARs from platform/bootstrap/bin
        for _, jar in ipairs(get_jars_in_dir(hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "bootstrap" .. path_sep .. "bin")) do
          table.insert(classpath, jar)
        end

        -- Add JARs from platform/ext/core/lib
        for _, jar in ipairs(get_jars_in_dir(hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "ext" .. path_sep .. "core" .. path_sep .. "lib")) do
          table.insert(classpath, jar)
        end

        -- Add coreserver.jar directly
        table.insert(classpath, hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "ext" .. path_sep .. "core" .. path_sep .. "bin" .. path_sep .. "coreserver.jar")

        -- Add JARs from platform/ext/platformservices/lib
        for _, jar in ipairs(get_jars_in_dir(hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "ext" .. path_sep .. "platformservices" .. path_sep .. "lib")) do
          table.insert(classpath, jar)
        end

        -- Add JARs from platform/ext/servicelayer/lib
        for _, jar in ipairs(get_jars_in_dir(hybris_root .. path_sep .. "bin" .. path_sep .. "platform" .. path_sep .. "ext" .. path_sep .. "servicelayer" .. path_sep .. "lib")) do
          table.insert(classpath, jar)
        end

        return classpath
      end)(), -- Call the function immediately to get the compiled classpath table
      javaCore = {
        compiler = {
            compliance = {
                '17', '17'
            }
        }
      },
      defaultJRE = {
        '/Users/manolo/.sdkman/candidates/java/17.0.17-sapmchn'
      }
    },
  }

  log("JDTLS projects configured:")
  for i, proj in ipairs(projects_config) do
    log(string.format("  Project %d: %s (Path: %s)", i, proj.name, proj.path))
    if proj.projectReferences then
      log("    References: " .. table.concat(proj.projectReferences, ", "))
    end
    log("    Source Paths:")
    for _, sp in ipairs(proj.sourcePaths) do
      log("      - " .. sp)
    end
    log("    Output Path: " .. proj.outputPath)
    log("    Raw Classpath JARs: " .. #proj.rawClasspath)
    if #proj.rawClasspath > 0 then
      log("      First 5: " .. table.concat(vim.list_slice(proj.rawClasspath, 1, 5), ", "))
    end
  end


  -- Get the jdtls installation path
  local jdtls_install_path = vim.fn.stdpath("data") .. path_sep .. "mason" .. path_sep .. "packages" .. path_sep .. "jdtls"

  -- Find the launcher JAR
  local launcher_jar = vim.fn.glob(jdtls_install_path .. path_sep .. "plugins" .. path_sep .. "org.eclipse.equinox.launcher_*.jar")
  if launcher_jar == "" or launcher_jar == nil then
    log("ERROR: jdtls launcher JAR not found.")
    vim.notify("ERROR: jdtls launcher JAR not found.", vim.log.levels.ERROR)
    return
  end
  log("Launcher JAR found: " .. launcher_jar)

  -- Set the configuration path
  local config_path = jdtls_install_path .. path_sep .. config_dir_name
  log("Config path set to: " .. config_path)

  local config = {
    cmd = {
      "/Users/manolo/.sdkman/candidates/java/21.0.9-sapmchn/bin/java", -- Use the Java 21 SDK for JDTLS itself
      "-debug",
      "-Dlog.level=TRACE", -- LSP protocol log level
      "--add-modules=ALL-SYSTEM",
      "--add-opens",
      "java.base/java.util=ALL-UNNAMED",
      "--add-opens",
      "java.base/java.lang=ALL-UNNAMED",
      "-Declipse.application=org.eclipse.jdt.ls.core.id1",
      "-Dosgi.bundles.defaultStartLevel=4",
      "-Declipse.product=org.eclipse.jdt.ls.core.product",
      "-Dlog.protocol=true",
      "-Xmx4g",
      "-Dorg.eclipse.jdt.ls.core.debug.dumpClasspath=true",
      "-Dorg.eclipse.jdt.ls.core.debug.dumpProjectInfo=true",
      "-Dorg.eclipse.jdt.ls.core.debug=true",
      "-Dlog.level=DEBUG", -- JDTLS internal log level
      "-Dfile.encoding=UTF-8",
      "-jar",
      vim.fn.trim(launcher_jar),
      "-configuration",
      config_path,
      "-data",
      workspace_dir,
    },
    root_dir = hybris_root,

    settings = {
      java = {
        configuration = {
          runtimes = {
            {
              name = "JavaSE-17",
              path = "/Users/manolo/.sdkman/candidates/java/17.0.17-sapmchn",
              default = true,
            },
            {
              name = "JavaSE-21",
              path = "/Users/manolo/.sdkman/candidates/java/21.0.9-sapmchn",
            },
          },
        },
        project = {
          source = 17,
          target = 17,
          import = {
            generatesMetadataFromXml = true,
          },
        },
      },
    },
    init_options = {
      bundles = {},
      extendedClientCapabilities = {
        project = {
          projects = projects_config,
        }
      }
    },
    on_attach = function(client, bufnr)
      log("on_attach hook triggered for buffer: " .. bufnr)
      vim.notify("JDTLS: Server attached with multi-project (dev + platform) configuration.", vim.log.levels.INFO)
    end,
  }

  log("Starting jdtls server for multi-project (dev + platform) setup...")
  require("jdtls").start_or_attach(config)
end

return M
