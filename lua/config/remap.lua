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
end, { desc = "Save File" })

vim.keymap.set("n", "<leader>pv", vim.cmd.Ex, { desc = "File Explorer (netrw)" })
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

vim.keymap.set("n", "<leader>ps", function()
    require('fzf-lua').live_grep()
end, {desc = "Search Text (live grep)"})

vim.keymap.set("n", "<leader>psf", function()
    require('fzf-lua').files()
end, {desc = "Search Files"})

vim.keymap.set("n", "<leader>psg", function()
    require('fzf-lua').git_commits()
end, {desc = "Search Git Commits"})

vim.keymap.set("n", "<leader>psb", function()
    require('fzf-lua').git_branches()
end, {desc = "Search Git Branches"})

vim.keymap.set("n", "<leader>psr", function()
    require('fzf-lua').resume()
end, {desc = "Resume Last Search"})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'java',
  callback = function()
    local utils = require('jdtls.utils')
    local project_type, root_dir = utils.detect_project()

    if project_type == 'hybris' then
      require('jdtls.hybris_setup').setup(root_dir)
    else
      require('jdtls.jdtls_setup').setup(root_dir)
    end
  end
})
