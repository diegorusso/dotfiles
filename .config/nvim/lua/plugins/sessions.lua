---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    opts.autocmds = opts.autocmds or {}

    opts.autocmds.restore_session = {
      {
        event = "VimEnter",
        desc = "Restore the previous directory session when Neovim opens without arguments",
        nested = true,
        callback = function()
          if vim.fn.argc(-1) == 0 then
            require("resession").load(vim.fn.getcwd(), {
              dir = "dirsession",
              silence_errors = true,
            })
          end
        end,
      },
    }

    local pending = false
    local save = function()
      if pending then return end
      pending = true
      vim.defer_fn(function()
        pending = false
        if require("astrocore.buffer").is_valid_session() then
          require("resession").save(vim.fn.getcwd(), {
            dir = "dirsession",
            notify = false,
          })
        end
      end, 1000)
    end

    opts.autocmds.session_autosave_events = {
      {
        event = { "BufWritePost", "BufAdd", "BufDelete", "BufFilePost" },
        desc = "Debounce directory session saves after file changes",
        callback = save,
      },
    }
  end,
}
