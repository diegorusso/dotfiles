require("lazy").setup({
  {
    "AstroNvim/AstroNvim",
    version = "6.1.0",
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
