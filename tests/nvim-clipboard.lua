-- Exercise the real provider without accessing the host clipboard.
local spec = dofile(assert(vim.env.DOTFILES_ASTROCORE_CHECK))
local executable = vim.fn["provider#clipboard#Executable"]
vim.env.ZELLIJ, vim.env.SSH_CONNECTION, vim.env.SSH_TTY = "0", nil, nil
vim.g.clipboard = nil

for _, provider in ipairs { "pbcopy", "win32yank", "clip", "wl-copy", "xclip", "tmux" } do
  vim.fn["provider#clipboard#Executable"] = function() return provider end
  spec.init()
  assert(vim.g.clipboard == nil, provider .. " was overridden")
end

for _, variable in ipairs { "SSH_CONNECTION", "SSH_TTY" } do
  vim.env[variable] = "fixture"
  vim.fn["provider#clipboard#Executable"] = function() return "pbcopy" end
  spec.init()
  assert(vim.g.clipboard.name == "OSC 52 (Zellij)", "remote copy targeted the server clipboard")
  vim.env[variable], vim.g.clipboard = nil, nil
end

vim.fn["provider#clipboard#Executable"] = function() return "" end
vim.env.ZELLIJ = nil
spec.init()
assert(vim.g.clipboard == nil, "clipboard was overridden outside Zellij")
vim.env.ZELLIJ = "0"
vim.g.clipboard = "custom"
spec.init()
assert(vim.g.clipboard == "custom", "explicit clipboard was overridden")
vim.g.clipboard = nil
spec.init()
vim.fn["provider#clipboard#Executable"] = executable

local sent = {}
vim.api.nvim_ui_send = function(sequence) sent[#sent + 1] = sequence end
vim.opt.clipboard = "unnamedplus"
assert(vim.fn.has "clipboard" == 1)
assert(vim.fn["provider#clipboard#Executable"]() == "OSC 52 (Zellij)")
assert(vim.fn.getreg "+" == "", "initial paste should be empty and immediate")
assert(#sent == 0, "paste queried the remote clipboard")

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "clipboard café", "second line" })
vim.cmd "normal! ggyy"
assert(sent[#sent] == "\027]52;c;" .. vim.base64.encode "clipboard café\n" .. "\027\\")
local count = #sent
vim.cmd "normal! p"
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false),
  { "clipboard café", "clipboard café", "second line" }), "linewise paste was not preserved")
assert(#sent == count, "paste queried the remote clipboard")

vim.cmd "normal! gg0vey"
assert(sent[#sent] == "\027]52;c;" .. vim.base64.encode "clipboard" .. "\027\\")
assert(vim.fn.getreg "+" == "clipboard")
assert(vim.fn.getregtype "+" == "v")
vim.fn.setreg("*", { "first", "second" }, "\0226")
assert(sent[#sent] == "\027]52;p;" .. vim.base64.encode "first\nsecond\n" .. "\027\\")
assert(vim.fn.getregtype "*" == "\0226", "blockwise register type was lost")
assert(vim.deep_equal(vim.fn.getreg("*", 1, true), { "first", "second" }))
assert(vim.fn.getreg "+" == "clipboard", "clipboard registers shared their cache")
count = #sent
vim.cmd 'normal! "_dd'
assert(#sent == count, "black-hole deletion overwrote the clipboard")
assert(vim.v.errmsg == "", vim.v.errmsg)
print "PASS Neovim OSC 52 copying, local paste, and native provider guards"
