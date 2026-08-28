-- Loaded before the staged AstroNvim configuration. Validation is deferred
-- until after VimEnter so startup plugins and user VimEnter handlers have run.

local marker_path = assert(vim.env.DOTFILES_ASTRONVIM_HEALTH_MARKER)

local function validate()
  if vim.v.vim_did_enter ~= 1 then error "VimEnter did not complete" end
  if vim.v.errmsg ~= "" then error("startup reported an error: " .. vim.v.errmsg) end

  for _, module_name in ipairs { "lazy", "astronvim", "astrocore", "astrolsp" } do
    local ok, message = pcall(require, module_name)
    if not ok then error(("unable to load %s: %s"):format(module_name, message)) end
  end

  local lock_path = vim.fn.stdpath "config" .. "/lazy-lock.json"
  local lock_contents = table.concat(vim.fn.readfile(lock_path), "\n")
  local lock = vim.json.decode(lock_contents)
  if type(lock) ~= "table" or next(lock) == nil then error "lazy-lock.json is empty" end

  local lazy_config = require "lazy.core.config"
  for plugin_name, locked in pairs(lock) do
    local plugin = lazy_config.plugins[plugin_name]
    if not plugin or type(plugin.dir) ~= "string" or vim.fn.isdirectory(plugin.dir) ~= 1 then
      error("locked plugin is unavailable: " .. plugin_name)
    end
    if type(locked) ~= "table" or type(locked.commit) ~= "string" then
      error("locked plugin has no commit: " .. plugin_name)
    end

    local result = vim.system({ "git", "-C", plugin.dir, "rev-parse", "HEAD" }, { text = true }):wait()
    local installed_commit = vim.trim(result.stdout or "")
    if result.code ~= 0 or installed_commit ~= locked.commit then
      error(
        ("locked plugin revision mismatch for %s: expected %s, found %s"):format(
          plugin_name,
          locked.commit,
          installed_commit ~= "" and installed_commit or "unavailable"
        )
      )
    end
  end

  local marker, open_error = io.open(marker_path, "w")
  if not marker then error("unable to create health marker: " .. tostring(open_error)) end
  assert(marker:write "ok\n")
  assert(marker:close())
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      local ok, message = xpcall(validate, debug.traceback)
      if not ok then
        io.stderr:write("AstroNvim startup validation failed:\n" .. message .. "\n")
        vim.cmd "cquit 1"
      else
        vim.cmd "qa!"
      end
    end)
  end,
})
