return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    opts.autocmds = opts.autocmds or {}

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
        desc = "Debounced cwd session autosave on file changes",
        callback = save,
      },
    }
  end,
}
