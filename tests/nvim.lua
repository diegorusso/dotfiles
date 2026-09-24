-- Loaded before init.lua by tests/check-nvim.sh, in disposable XDG directories.
local function validate()
  assert(vim.v.vim_did_enter == 1)
  assert(vim.v.errmsg == "", vim.v.errmsg)
  assert(require("astronvim").version() == "v6.1.0")

  local function edit(name, lines)
    vim.fn.writefile(lines, name)
    vim.cmd.edit(vim.fn.fnameescape(name))
    return vim.api.nvim_get_current_buf()
  end

  local markdown = edit("injection.md", { "# Example", "", "```lua", "local value = 1", "```" })
  local parser = assert(vim.treesitter.get_parser(markdown, "markdown"))
  parser:parse(true)
  assert(parser:children().lua, "fenced Lua injection was lost")
  assert(vim.treesitter.highlighter.active[markdown], "Markdown highlighting is disabled")
  vim.api.nvim_buf_set_lines(markdown, 3, 4, false, { "local value = 2" })
  local completed = false
  parser:parse(true, function(err)
    assert(not err, err)
    assert(parser:children().lua, "fenced Lua injection was lost after editing")
    completed = true
  end)
  assert(vim.wait(2000, function() return completed end), "async parse did not finish")
  vim.cmd "silent write"

  local lua_buf = edit("example.lua", { "local function example(first, second)", "  return first + second", "end" })
  assert(vim.treesitter.highlighter.active[lua_buf], "Lua highlighting is disabled")
  assert(vim.bo[lua_buf].indentexpr == "v:lua.require'nvim-treesitter'.indentexpr()")
  local mappings = vim.api.nvim_buf_get_keymap(lua_buf, "n")
  local move
  for _, map in ipairs(mappings) do
    if map.lhs == "]F" then move = map.callback end
  end
  assert(move, "function textobject movement mapping is missing")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  move()
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "function movement did not reach the end")
  assert(not vim.o.relativenumber and vim.o.number and not vim.o.wrap and not vim.o.spell)
  local diagnostics = vim.diagnostic.config()
  assert(diagnostics.virtual_text and diagnostics.virtual_lines == false)

  local lsp = require "astrolsp"
  assert(not lsp.autoformat_enabled(lua_buf), "format on save was enabled")
  assert(vim.lsp.codelens.is_enabled(), "codelens was disabled")
  assert(vim.lsp.semantic_tokens.is_enabled(), "semantic tokens were disabled")
  assert(not vim.lsp.inlay_hint.is_enabled(), "inlay hints were enabled")
  assert(vim.deep_equal(vim.lsp.config.clangd.cmd, { "clangd", "--background-index" }))
  assert(vim.lsp.config.clangd.capabilities.offsetEncoding == "utf-8")

  local resession = require "resession"
  local cwd = vim.fn.getcwd()
  resession.save(cwd, { dir = "dirsession", notify = false })
  vim.cmd.enew()
  -- Exercise the configured no-argument startup restore callback.
  require("astrocore").config.autocmds.restore_session[1].callback()
  assert(vim.api.nvim_buf_get_name(0):match("/example.lua$"), "directory session was not restored")
  -- Autopairs/autotag intentionally pcall deletion of absent mappings during
  -- buffer cleanup. Neovim retains their handled E31 in v:errmsg.
  assert(vim.v.errmsg == "" or vim.v.errmsg == "E31: No such mapping", vim.v.errmsg)
  local messages = vim.api.nvim_exec2("messages", { output = true }).output
  assert(not messages:find("stack traceback:", 1, true), messages)
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      local ok, err = xpcall(validate, debug.traceback)
      if not ok then
        io.stderr:write(tostring(err) .. "\n")
        vim.cmd "cquit 1"
      else
        vim.cmd "qa!"
      end
    end)
  end,
})
