local cmp = require('cmp')

cmp.setup({
  snippet = {
    expand = function(args)
      vim.snippet.expand(args.body)
    end,
  },
  window = {
    completion = cmp.config.window.bordered(),
    documentation = cmp.config.window.bordered(),
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-k>'] = cmp.mapping.select_prev_item({ behavior = 'select' }),
    ['<C-j>'] = cmp.mapping.select_next_item({ behavior = 'select' }),
    ['<Tab>'] = cmp.mapping.confirm({ select = false }), -- Recommended: set select to false for Tab
    ['<C-a>'] = cmp.mapping.abort(),
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-u>'] = cmp.mapping.scroll_docs(-4),
    ['<C-d>'] = cmp.mapping.scroll_docs(4),
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },
  }, {
      { name = 'buffer' },
    }),
  preselect = 'item', 
  completion = {
    completeopt = 'menu,menuone,noinsert'
  },
})

-- 3. Command Line Setup (Search / and ?)
cmp.setup.cmdline({ '/', '?' }, {
  mapping = cmp.mapping.preset.cmdline({
    ['<Tab>'] = {
      c = function()
        if cmp.visible() then
          cmp.confirm({ select = false })
        else
          cmp.complete()
        end
      end,
    },
    ['<C-j>'] = {
      c = function(fallback)
        if cmp.visible() then
          cmp.select_next_item()
        else
          fallback()
        end
      end,
    },
    ['<C-k>'] = {
      c = function(fallback)
        if cmp.visible() then
          cmp.select_prev_item()
        else
          fallback()
        end
      end,
    },
    ['<C-e>'] = {
      c = cmp.mapping.abort(),
    },
  }),
  sources = {
    { name = 'buffer' }
  }
})

cmp.setup.cmdline(':', {
  mapping = cmp.mapping.preset.cmdline({
    ['<Tab>'] = {
      c = function()
        if cmp.visible() then
          cmp.confirm({ select = false })
        else
          cmp.complete()
        end
      end,
    },
    ['<C-j>'] = {
      c = function(fallback)
        if cmp.visible() then
          cmp.select_next_item()
        else
          fallback()
        end
      end,
    },
    ['<C-k>'] = {
      c = function(fallback)
        if cmp.visible() then
          cmp.select_prev_item()
        else
          fallback()
        end
      end,
    },
    ['<C-e>'] = {
      c = cmp.mapping.abort(),
    },
  }),
  sources = cmp.config.sources({
    { name = 'path' }
  }, {
      {
        name = 'cmdline',
        option = {
          ignore_cmds = { 'Man', '!' }
        }
      }
    })
})
