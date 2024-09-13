-- Read the docs: https://www.lunarvim.org/docs/configuration
-- Example configs: https://github.com/LunarVim/starter.lvim
-- Video Tutorials: https://www.youtube.com/watch?v=sFA9kX-Ud_c&list=PLhoH5vyxr6QqGu0i7tt_XoVK9v-KvZ3m6
-- Forum: https://www.reddit.com/r/lunarvim/
-- Discord: https://discord.com/invite/Xb9B4Ny

lvim.colorscheme = "vim"
vim.o.colorcolumn = "79"

lvim.builtin.which_key.mappings["sF"] = { "<cmd>Telescope find_files hidden=true no_ignore=true<cr>", "Find File Everywhere" }
lvim.builtin.which_key.mappings["sT"] = {
  function()
  require("telescope.builtin").live_grep {
    additional_args = function(args) return vim.list_extend(args, { "--hidden", "--no-ignore" }) end,
  }
  end,
  "Text Everywhere",
}

lvim.format_on_save = false
vim.diagnostic.config({ virtual_text = true })
lvim.builtin.treesitter.highlight.enable = true
lvim.builtin.treesitter.ensure_installed = { "cpp", "c", "python" }
