require("lazy").setup({
  {
    "AstroNvim/AstroNvim",
    version = "5.3.15",
    import = "astronvim.plugins",
    opts = {
      mapleader = " ",
      maplocalleader = ",",
      icons_enabled = true,
      pin_plugins = true,
      update_notifications = true,
    },
  },
  { import = "plugins" },
  -- Aerial 3.1 supports Neovim 0.12's Tree-sitter API.
  { "stevearc/aerial.nvim", version = "3.1.0" },
} --[[@as LazySpec]], {
  lockfile = vim.fn.stdpath "config" .. "/lazy-lock.json",
  install = { colorscheme = { "astrotheme", "habamax" } },
  ui = { backdrop = 100 },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "zipPlugin",
      },
    },
  },
} --[[@as LazyConfig]])
