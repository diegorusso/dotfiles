-- Bootstrap the pinned lazy.nvim release, then load the AstroNvim configuration.

local version = vim.version()
if version.major ~= 0 or version.minor ~= 12 then
  error(("This configuration requires Neovim 0.12.x (found %s)"):format(tostring(version)))
end

local lazy_path = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"

if not vim.uv.fs_stat(lazy_path) then
  local result = vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=v11.17.5",
    "https://github.com/folke/lazy.nvim.git",
    lazy_path,
  }

  if vim.v.shell_error ~= 0 then error(("Unable to install lazy.nvim:\n%s"):format(result)) end
end

vim.opt.rtp:prepend(lazy_path)

if not pcall(require, "lazy") then error(("Unable to load lazy.nvim from %s"):format(lazy_path)) end

require "lazy_setup"
require "polish"
