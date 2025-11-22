vim.lsp.config['lua_ls'] = {
    cmd = { 'lua-language-server' },
    filetypes = { 'lua' },
    root_markers = { { '.luarc.json', '.luarc.jsonc' }, '.git' },
    settings = {
        Lua = {
            runtime = {
                version = 'LuaJIT',
            }
        }
    }
}
vim.lsp.enable("lua_ls")

vim.api.nvim_create_autocmd('FileType', {
    pattern = 'java',
    callback = function()
        require'jdtls.jdtls_setup'.setup()
    end
})

vim.lsp.config['lemminx'] = {
    cmd = { "lemminx" },
    filetypes = { "xml", "xsd", "xsl", "xslt", "svg" },
    single_file_support = true,

    on_new_config = function(new_config, new_root_dir)
        local results = vim.fs.find('items.xsd', {
            path = new_root_dir,
            upward = false,
            stop = vim.env.HOME,
            limit = 1
        })

        if #results > 0 then
            local xsd_path = results[1]

            if not new_config.settings then new_config.settings = {} end
            if not new_config.settings.xml then new_config.settings.xml = {} end

            new_config.settings.xml.fileAssociations = {
                {
                    systemId = xsd_path,      -- Absolute path to items.xsd
                    pattern = "**/*items.xml" -- Apply to all items.xml files
                }
            }
        end
    end,
}

vim.diagnostic.config({ virtual_text = true })
