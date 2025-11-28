vim.g.mapleader = " "

vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)
vim.keymap.set("n", "<leader>w", vim.cmd.write)
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

-- Grep keybinding for visual mode -
vim.keymap.set("v", "<leader>ps", function()
    local saved_reg = vim.fn.getreg("v")
    local saved_type = vim.fn.getregtype("v")

    vim.cmd('noau normal! "vy')

    local selected_text = vim.fn.getreg("v")

    vim.fn.setreg("v", saved_reg, saved_type)

    if not selected_text or #selected_text == 0 then
        return
    end
    selected_text = string.gsub(selected_text, "\n", " ")
    selected_text = vim.fn.escape(selected_text, "\\.*+?^$()[]{}|")

    require('fzf-lua').live_grep({ search = selected_text })
end, { desc = "Grep Selected Text" })

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

