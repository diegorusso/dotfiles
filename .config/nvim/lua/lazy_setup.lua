local legacy_nvim = vim.fn.has "nvim-0.11" == 0

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
  -- Aerial 3.1 fixes the Neovim 0.12 Tree-sitter API change, but requires 0.11+.
  { "stevearc/aerial.nvim", version = legacy_nvim and "2.7.0" or "3.1.0" },
} --[[@as LazySpec]], {
  lockfile = vim.fn.stdpath "config" .. (legacy_nvim and "/lazy-lock-nvim-0.10.json" or "/lazy-lock.json"),
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
