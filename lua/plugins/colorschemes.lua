return {
  {
    "rebelot/kanagawa.nvim",
    enabled = true,
    config = function()
        require('kanagawa').setup({
            colors = {
                theme = {
                    all = {
                        ui = {
                            bg = "#1e1f22",        -- IntelliJ Ultimate New UI dark editor background
                            bg_gutter = "#1e1f22", -- Gutter background matches editor
                            bg_m1 = "#2b2d30",     -- IntelliJ Tool Window / Sidebar background
                            bg_m2 = "#2b2d30",
                            bg_m3 = "#2b2d30",
                            bg_dim = "#2b2d30",    -- Secondary backgrounds
                            fg = "#bcbec4",        -- IntelliJ New UI default text color
                            fg_dim = "#7a7e85",    -- IntelliJ New UI comments/dim text color
                        }
                    }
                }
            },
            overrides = function(colors)
                local theme = colors.theme
                return {
                    -- Force main editing area backgrounds to match IntelliJ
                    Normal = { fg = theme.ui.fg, bg = theme.ui.bg },
                    NormalNC = { fg = theme.ui.fg, bg = theme.ui.bg },
                    SignColumn = { bg = theme.ui.bg },
                    LineNr = { fg = "#5a5d63", bg = theme.ui.bg }, -- IntelliJ line number gray
                    CursorLine = { bg = "#26282e" },               -- IntelliJ Cursor/Caret Row highlight
                    CursorLineNr = { fg = "#bcbec4", bg = "#26282e", bold = true },

                    -- Status and tabs matching IntelliJ UI headers
                    StatusLine = { fg = "#bcbec4", bg = "#2b2d30" },
                    StatusLineNC = { fg = "#7a7e85", bg = "#2b2d30" },
                    TabLine = { fg = "#7a7e85", bg = "#2b2d30" },
                    TabLineSel = { fg = "#bcbec4", bg = "#1e1f22", bold = true },
                    TabLineFill = { bg = "#2b2d30" },

                    -- Selection matching IntelliJ's blue highlight
                    Visual = { bg = "#214283" },

                    -- Floating UI elements / Popups matching IntelliJ popups
                    NormalFloat = { fg = theme.ui.fg, bg = theme.ui.bg_m1 },
                    FloatBorder = { fg = "#43454a", bg = theme.ui.bg_m1 }, -- IntelliJ border gray

                    -- Existing overrides
                    ["@lsp.type.class"]         = { link = "@type" },
                    ["@lsp.type.interface"]     = { link = "@type" },
                    ["@lsp.type.enum"]          = { link = "@type" },
                    ["@lsp.type.keyword"]       = { link = "@keyword" },
                    ["@lsp.type.modifier"]      = { link = "@keyword.modifier" },

                    ["@lsp.mod.static"]         = { bold = true },
                }
            end
        })
        require("kanagawa").load("dragon")
    end,
  }
}
