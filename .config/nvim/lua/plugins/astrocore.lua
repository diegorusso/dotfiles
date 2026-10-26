---@type LazySpec
return {
  "AstroNvim/astrocore",
  init = function()
    if not vim.env.ZELLIJ or vim.g.clipboard ~= nil then return end
    local provider = vim.fn["provider#clipboard#Executable"]()
    if not vim.env.SSH_CONNECTION and not vim.env.SSH_TTY
      and provider ~= "" and provider ~= "OSC 52"
    then return end

    local clipboard = { name = "OSC 52 (Zellij)", copy = {}, paste = {} }
    for _, register in ipairs { "+", "*" } do
      local contents = { {}, "v" }
      local copy = require("vim.ui.clipboard.osc52").copy(register)
      clipboard.copy[register] = function(lines, regtype)
        contents = { lines, regtype }
        copy(lines)
      end
      -- Avoid clipboard reads that can time out through Zellij; terminal paste handles external text.
      clipboard.paste[register] = function() return contents end
    end
    vim.g.clipboard = clipboard
    vim.g.loaded_clipboard_provider = nil
    vim.cmd.runtime "autoload/provider/clipboard.vim"
  end,
  ---@type AstroCoreOpts
  opts = {
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 },
      autopairs = true,
      cmp = true,
      diagnostics = true,
      highlighturl = true,
      notifications = true,
    },
    diagnostics = {
      virtual_text = true,
      virtual_lines = false,
      underline = true,
    },
    options = {
      opt = {
        relativenumber = false,
        number = true,
        spell = false,
        signcolumn = "yes",
        wrap = false,
      },
    },
    mappings = {
      n = {
        ["]b"] = { function() require("astrocore.buffer").nav(vim.v.count1) end, desc = "Next buffer" },
        ["[b"] = { function() require("astrocore.buffer").nav(-vim.v.count1) end, desc = "Previous buffer" },
        ["<Leader>bd"] = {
          function()
            require("astroui.status.heirline").buffer_picker(
              function(bufnr) require("astrocore.buffer").close(bufnr) end
            )
          end,
          desc = "Close buffer from tabline",
        },
      },
    },
  },
}
