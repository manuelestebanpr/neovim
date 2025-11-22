 return {
  {
    "rebelot/kanagawa.nvim",
    enabled = true,
         config = function()
             require('kanagawa').setup({
                 -- ... your other config
                 overrides = function()
                     return {

                         ["@lsp.type.class"]         = { link = "@type" },
                         ["@lsp.type.interface"]     = { link = "@type" },
                         ["@lsp.type.enum"]          = { link = "@type" },
                         ["@lsp.type.keyword"]       = { link = "@keyword" },
                         ["@lsp.type.modifier"]      = { link = "@keyword.modifier" }, -- For 'private', 'public'

                         ["@lsp.mod.static"]         = { bold = true },
                     }
                 end
             })
             require("kanagawa").load("dragon")
         end,
  }
}
