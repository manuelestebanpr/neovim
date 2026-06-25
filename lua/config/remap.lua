vim.g.mapleader = " "

vim.keymap.set("n", "<leader>w", function()
    local success, err = pcall(function()
        -- Force write: overwrite even when the file changed on disk underneath us
        -- (e.g. Hybris/Backoffice regenerates a *-backoffice-config.xml that is open),
        -- which would otherwise abort with "E13: File has been changed since reading it".
        vim.cmd("silent! write!")
    end)

    if not success then
        vim.notify("Error saving file: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local file_name = vim.fn.expand("%:t")
    local size = vim.fn.getfsize(vim.fn.expand("%"))
    if size < 0 then size = 0 end

    local msg = string.format('"%s" %dB written', file_name, size)
    vim.notify(msg, vim.log.levels.INFO, { title = "File Saved" })
end, { desc = "Save File (force write!)" })

-- mini.files is the only file explorer (netrw is disabled in init.lua).
-- <leader>pv opens it at the current file; <leader>pn opens it rooted at the cwd
-- (see lua/plugins/minifiles.lua).
vim.keymap.set("n", "<leader>pn", function()
    require("mini.files").open(vim.uv.cwd())
end, { desc = "File Explorer at cwd (mini.files)" })
vim.keymap.set("n", "<leader>sn", "<cmd>nohlsearch<CR>", { desc = "Clear Search Highlights" })


vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move Selection Up" })
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move Selection Down" })

vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Half Page Down & Center" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Half Page Up & Center" })

vim.keymap.set("x", "<leader>p", "\"_dP", { desc = "Paste (keep register)" })

vim.keymap.set("v", "<leader>x", "\"_d", { desc = "Delete (no yank)" })

-- CUSTOM KEYMAP SAP COMMERCE DELETE .classpath
vim.keymap.set("n", "<leader>clr", function()
    require'jdtls.hybris_setup'.restore_backups()
end, { desc = "Restore Hybris .classpath backups" })

-- :HybrisReimport -- force a re-scan after editing extensioninfo.xml /
-- localextensions.xml (the per-session guard otherwise serves the stale workspace
-- for the rest of the session). Registered here in remap (always loaded) rather
-- than in hybris_setup (lazy-required) so the command exists from startup; it
-- lazy-requires the module only when actually invoked.
vim.api.nvim_create_user_command("HybrisReimport", function()
    require('jdtls.hybris_setup').reimport()
end, { desc = "Re-scan Hybris extensions and rebuild the jdtls workspace" })

-- :HybrisMavenDeps -- check (and, when a real mvn is on PATH, resolve) each custom
-- extension's external-dependencies.xml into lib/. Bang (:HybrisMavenDeps!) is
-- report-only and never spawns mvn. Most lib/ are already ant-populated, so this is
-- usually a sub-second no-op; it surfaces extensions whose maven jars are missing.
vim.api.nvim_create_user_command("HybrisMavenDeps", function(o)
    require('jdtls.hybris_setup').maven_deps({ fix = not o.bang })
end, { bang = true, desc = "Check/resolve external-dependencies.xml into lib/ for custom extensions" })

-- :HybrisResources -- show the per-machine jdtls sizing (heap / GC / build threads)
-- and how to override it. Useful to confirm what was picked on this macOS/CachyOS box.
vim.api.nvim_create_user_command("HybrisResources", function()
    local r = require('jdtls.hybris_setup').resources()
    vim.notify(string.format(
        "jdtls sizing on this machine:\n  RAM=%dGB  cores=%d\n  -Xmx=%dg  maxConcurrentBuilds=%d  GC=%s\n  override: $NVIM_JDTLS_XMX_GB, $NVIM_JDTLS_GC (g1|zgc|parallel)",
        r.total_gb, r.cores, r.xmx_gb, r.builds, r.gc), vim.log.levels.INFO, { title = "Hybris jdtls resources" })
end, { desc = "Show per-machine jdtls heap/GC/build-thread sizing" })

vim.keymap.set("n", "<leader>ps", function()
    require('fzf-lua').live_grep()
end, {desc = "Search Text (live grep)"})

vim.keymap.set("n", "<leader>psf", function()
    require('fzf-lua').files()
end, {desc = "Search Files"})

-- Fast picker scoped to the user's OWN code: bin/custom only (~12k files vs ~89k
-- for the whole tree). Daily-driver search; skips platform+modules entirely.
-- Anchored to an ABSOLUTE, symlink-resolved path (not the literal "bin/custom")
-- so it works from any cwd -- jumping into a custom file changes nvim's notion of
-- the buffer dir, and a relative path would then search nothing. Resolving the
-- bin/custom symlink to its real extensions-repo location also matches how the
-- rest of the config handles these symlinks; rg follows the explicit path arg.
local function hybris_custom_dir()
    local ok, utils = pcall(require, 'jdtls.utils')
    local root = ok and utils.get_platform_root()
    if not root then return nil end
    local custom = vim.fn.resolve(root .. '/bin/custom')
    return vim.fn.isdirectory(custom) == 1 and custom or nil
end

vim.keymap.set("n", "<leader>pc", function()
    local dir = hybris_custom_dir() or 'bin/custom'
    require('fzf-lua').files({
        prompt = 'CustomFiles> ',
        cmd = "rg --files --color=never --hidden --follow --no-messages " .. vim.fn.shellescape(dir) .. " " ..
              "-g '!**/node_modules/**' " ..
              "-g '!**/classes/**' " ..
              "-g '!**/testclasses/**' " ..
              "-g '!**/eclipsebin/**' " ..
              "-g '!*.class' " ..
              "-g '!*.jar' " ..
              "-g '!*.sha1' " ..
              "-g '!*.prefs' ",
    })
end, { desc = "Search Files (bin/custom only)" })

-- Live grep scoped to bin/custom only (your code), for the same reason.
vim.keymap.set("n", "<leader>pC", function()
    require('fzf-lua').live_grep({
        prompt = 'CustomGrep> ',
        search_paths = { hybris_custom_dir() or 'bin/custom' },
    })
end, { desc = "Live Grep (bin/custom only)" })

vim.keymap.set("n", "<leader>psg", function()
    require('fzf-lua').git_commits()
end, {desc = "Search Git Commits"})

vim.keymap.set("n", "<leader>psb", function()
    require('fzf-lua').git_branches()
end, {desc = "Search Git Branches"})

vim.keymap.set("n", "<leader>psr", function()
    require('fzf-lua').resume()
end, {desc = "Resume Last Search"})

-- ---------------------------------------------------------------------------
-- Hybris jdtls: import the workspace ONCE per session, attach cheaply per buffer.
-- ---------------------------------------------------------------------------
local hybris_group = vim.api.nvim_create_augroup("hybris_jdtls", { clear = true })

-- EAGER PRE-WARM AT STARTUP. When nvim opens inside a Hybris tree we boot jdtls in
-- the BACKGROUND immediately, so the JVM + project import + workspace indexing run
-- while you browse (fzf, reading) and the FIRST java file you open attaches to an
-- already-warming server instead of cold-starting. Two cases:
--   (a) `nvim path/Foo.java` -- a hybris buffer is already loaded: import + attach it.
--   (b) bare `nvim` / `nvim .` in the hybris folder -- no file: M.warm() boots a
--       buffer-less client (vim.lsp.start{attach=false}); the first file reuses it.
-- Gated to an actual Hybris root (cwd or the open buffer) so it never fires for an
-- unrelated project. NOTE: warming runs the one-time import which generates missing
-- .project/.classpath in the extensions repo -- intended, this is the "load on
-- startup" the workflow wants; `<leader>clr` reverts those files.
vim.api.nvim_create_autocmd('VimEnter', {
  group = hybris_group,
  callback = function()
    vim.schedule(function()
      local ok, utils = pcall(require, 'jdtls.utils')
      if not ok then return end

      local cur = vim.api.nvim_get_current_buf()
      local ft = vim.bo[cur].filetype
      local fname = vim.api.nvim_buf_get_name(cur)

      -- (a) startup buffer is a hybris java/xml file -> import + attach it.
      if (ft == 'java' or ft == 'xml') and fname ~= '' then
        local ptype, root_dir = utils.detect_project(fname)
        if ptype == 'hybris' then
          vim.defer_fn(function()
            pcall(function()
              local h = require('jdtls.hybris_setup')
              h.import(root_dir)
              h.attach(cur, root_dir)
            end)
          end, 50)
          return
        end
      end

      -- (b) no hybris buffer open, but cwd is a hybris root -> eager buffer-less boot.
      -- Opt out with $NVIM_HYBRIS_NO_WARM=1 on a RAM-constrained machine (then jdtls
      -- boots on the first java/xml file instead of at startup).
      if vim.env.NVIM_HYBRIS_NO_WARM == '1' then return end
      local root = utils.get_platform_root()
      if root and vim.fn.isdirectory(root .. '/bin/platform') == 1 then
        vim.defer_fn(function()
          pcall(function() require('jdtls.hybris_setup').warm(root) end)
        end, 50)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd('FileType', {
  group = hybris_group,
  -- Trigger on java AND xml: opening a Hybris config/items/beans xml should also
  -- boot the jdtls workspace so it is warm by the time you jump to a .java file.
  pattern = { 'java', 'xml' },
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    local utils = require('jdtls.utils')

    -- Resolve the project from THE BUFFER BEING OPENED, not just the current
    -- buffer / cwd. detect_project(file_path) only returns 'hybris' when a real
    -- bin/platform root is resolvable, so the expensive hybris import can never
    -- misfire for an external project merely opened from a hybris cwd, and a plain
    -- Java file deterministically goes to jdtls_setup (plain).
    local fname = vim.api.nvim_buf_get_name(args.buf)
    local project_type, root_dir = utils.detect_project(fname ~= '' and fname or nil)

    if project_type == 'hybris' then
      -- import() is the per-session, per-root guard: a no-op (cache hit) after the
      -- first buffer / the VimEnter pre-warm. attach() is cheap and only wires THIS
      -- buffer to the already-running client.
      local hybris = require('jdtls.hybris_setup')
      hybris.import(root_dir)
      hybris.attach(args.buf, root_dir)
    elseif project_type == 'maven' and ft == 'java' then
      -- Maven / Spring project (a pom.xml was found): start the plain jdtls Java
      -- language server. Only Java buffers trigger it; a stray xml is left to lemminx.
      require('jdtls.jdtls_setup').setup(root_dir)
    end
    -- Everything else gets NO jdtls on purpose: a Java file with no pom.xml and no
    -- Hybris platform (gradle/bare project), and every non-Java filetype, falls back
    -- to whatever mason-lspconfig automatic_enable + vim.lsp.enable provide, plus the
    -- generic nvim-cmp buffer/path completion. jdtls is reserved for Hybris + Maven.
  end,
})

-- Defensive force-stop of our jdtls on quit. nvim's built-in VimLeavePre already
-- sends a graceful shutdown; c:stop(true) escalates to an immediate SIGTERM so a
-- busy/indexing jdtls is signalled to die on a normal :q instead of lingering. This
-- shrinks the orphan window for the common quit path; it cannot help SIGKILL /
-- terminal-close (the autocmd never runs) -- that residual case is what the startup
-- reaper (hybris_setup.reap_stale_jdtls) covers.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = hybris_group,
  desc = 'Hybris: force-stop our jdtls on quit so it cannot orphan',
  callback = function()
    for _, c in ipairs(vim.lsp.get_clients({ name = 'jdtls' })) do
      pcall(function() c:stop(true) end)
    end
  end,
})
