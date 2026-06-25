return {
    'MeanderingProgrammer/render-markdown.nvim',
    -- Only decorates real markdown buffers, so load on the markdown filetype. The AI
    -- chat buffer sets syntax=markdown (NOT filetype), so it is deliberately untouched.
    ft = 'markdown',
    dependencies = { 'nvim-treesitter/nvim-treesitter', 'nvim-mini/mini.nvim' },            -- if you use the mini.nvim suite
    opts = {},
    config = function()
        require('render-markdown').setup({})
    end,
}
