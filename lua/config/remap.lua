vim.g.mapleader = " "

vim.keymap.set("n", "<leader>w", function()
    local success, err = pcall(function()
        vim.cmd("silent! write")
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
end)

vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)
vim.keymap.set("n", "<leader>sn", "<cmd>nohlsearch<CR>", { desc = "Clear search highlights" })


vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")

vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")

vim.keymap.set("x", "<leader>p", "\"_dP")

vim.keymap.set("v", "<leader>x", "\"_d")

-- CUSTOM KEYMAP SAP COMMERCE DELETE .classpath 
vim.keymap.set("n", "<leader>clr", function()
    require'jdtls.hybris_setup'.restore_backups()
end, { desc = "Restore Hybris .classpath backups" })

vim.keymap.set("n", "<leader>ps", function()
    require('fzf-lua').live_grep()
end, {desc = "Grep Search Text"})

vim.keymap.set("n", "<leader>psf", function()
    require('fzf-lua').files()
end, {desc = "Grep Search Files"})

vim.keymap.set("n", "<leader>psg", function()
    require('fzf-lua').git_commits()
end, {desc = "Grep Search Files"})

vim.keymap.set("n", "<leader>psb", function()
    require('fzf-lua').git_branches()
end, {desc = "Grep Search Files"})

vim.api.nvim_create_autocmd('FileType', {
    pattern = 'java',
    callback = function()
        require'jdtls.hybris_setup'.setup()
    end
})

