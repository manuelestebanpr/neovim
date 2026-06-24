vim.diagnostic.config({ virtual_text = true })

-- Completion capabilities shared by every server here so nvim-cmp gets snippet
-- support, documentation/detail resolution, etc. (see jdtls.utils.make_capabilities).
local capabilities = require('jdtls.utils').make_capabilities()

vim.lsp.config['lua_ls'] = {
    cmd = { 'lua-language-server' },
    filetypes = { 'lua' },
    capabilities = capabilities,
    root_markers = { { '.luarc.json', '.luarc.jsonc' }, '.git' },
    settings = {
        Lua = {
            runtime = {
                version = 'LuaJIT',
            }
        }
    }
}

-- lemminx (XML LS). Used mainly for SAP Commerce *items.xml / *beans.xml /
-- extensioninfo.xml (schema-driven completion of elements, attributes and enums;
-- trigger with <C-Space>).
--
-- NOTE: `on_new_config` is an old nvim-lspconfig field and is IGNORED by the
-- native vim.lsp.config / vim.lsp.enable framework (which mason-lspconfig v2 uses).
-- The per-root schema associations must run from a native hook -- `before_init`,
-- which receives the resolved root and may mutate `config.settings` before the
-- server is initialised.
vim.lsp.config['lemminx'] = {
    cmd = { "lemminx" },
    filetypes = { "xml", "xsd", "xsl", "xslt", "svg" },
    capabilities = capabilities,
    single_file_support = true,

    -- Resolve a real root so before_init has somewhere to search for schemas.
    -- Without it, opening a lone *.xml can leave rootPath empty and the Hybris
    -- associations are never applied (the symptom: no completion). Scope to the
    -- enclosing Hybris extension (the dir with extensioninfo.xml) when present so
    -- each instance stays small and uses that extension's own generated schemas;
    -- otherwise fall back to the detected project root.
    root_dir = function(bufnr, on_dir)
        local utils = require('jdtls.utils')
        local fname = vim.api.nvim_buf_get_name(bufnr)
        local start = (fname ~= "") and vim.fs.dirname(fname) or vim.fn.getcwd()
        local ext_root = utils.find_extension_root(start)
        if ext_root then
            on_dir(ext_root)
            return
        end
        local _, root = utils.detect_project(fname)
        on_dir(root or start)
    end,

    settings = {
        xml = {
            format = { enabled = true },
            completion = { autoCloseTags = true },
            -- Let XMLs that DO carry an xsi:schemaLocation (e.g. *-spring.xml)
            -- fetch their schema so completion works there too (cached after the
            -- first fetch). Schema-less files like *-backoffice-config.xml are
            -- unaffected -- the cockpit schemas ship inside platform jars, not as
            -- loose .xsd files, so they can't be associated from the project.
            downloadExternalResources = { enabled = true },
        },
    },

    before_init = function(params, config)
        local root = params.rootPath
        if (not root or root == "") and params.workspaceFolders and params.workspaceFolders[1] then
            root = vim.uri_to_fname(params.workspaceFolders[1].uri)
        end
        if not root or root == "" then return end

        local utils = require('jdtls.utils')
        local associations = {}
        local function associate(basename, pattern)
            local xsd = utils.find_schema(root, basename)
            if xsd then
                table.insert(associations, { systemId = xsd, pattern = pattern })
            end
        end

        associate("items.xsd", "**/*items.xml")
        associate("beans.xsd", "**/*beans.xml")
        associate("extensioninfo.xsd", "**/extensioninfo.xml")
        if #associations == 0 then return end

        config.settings = vim.tbl_deep_extend('force', config.settings or {}, {
            xml = { fileAssociations = associations },
        })
    end,

    on_attach = function(client, bufnr)
        -- Re-indent / pretty-print the buffer with lemminx. Handy for the
        -- badly-laid-out XML you mentioned; <C-Space> drives completion.
        vim.keymap.set('n', '<leader>cf', function()
            vim.lsp.buf.format({ async = true })
        end, { buffer = bufnr, desc = "Format XML (lemminx)" })
    end,
}

-- Explicitly enable the non-jdtls servers. mason-lspconfig's automatic_enable
-- also does this, but being explicit makes the intent clear and order-independent
-- (jdtls is started by nvim-jdtls from the FileType autocmd, not here).
vim.lsp.enable({ 'lua_ls', 'lemminx' })

