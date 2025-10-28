local input_window = require('opencode.ui.input_window')
local output_window = require('opencode.ui.output_window')
local IdleDetector = require('opencode.idle')
local M = {}

---@type IdleDetector|nil
local idle_detector = nil

function M.setup_autocmds(windows)
  local group = vim.api.nvim_create_augroup('OpencodeWindows', { clear = true })
  input_window.setup_autocmds(windows, group)
  output_window.setup_autocmds(windows, group)

  -- Only keep shared autocmds here (e.g., WinClosed, CursorHold for all windows)
  local wins = { windows.input_win, windows.output_win, windows.footer_win }
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = table.concat(wins, ','),
    callback = function(opts)
      local closed_win = tonumber(opts.match)
      if vim.tbl_contains(wins, closed_win) then
        -- Guard against git commit workflows that manage their own buffers/windows
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
            if ft == 'gitcommit' or ft == 'NeogitCommitMessage' then
              return
            end
          end
        end
        -- Immediate protected close without schedule to avoid race conditions
        pcall(require('opencode.ui.ui').close_windows, windows)
      end
    end,
  })

  -- Based on CursorHold, update context if user is not focused on opencode window
  vim.api.nvim_create_autocmd('CursorHold', {
    group = group,
    pattern = '*',
    callback = function()
      local ui = require('opencode.ui.ui')
      local context = require('opencode.context')
      local state = require('opencode.state')

      if not ui.is_opencode_focused() then
        -- User is in regular code window, update context and track position
        context.load()
        state.last_code_win_before_opencode = vim.api.nvim_get_current_win()
      else
        -- User is in opencode window, save cursor positions for restoration
        local pos = vim.api.nvim_win_get_cursor(0)
        if windows.input_win and vim.api.nvim_get_current_win() == windows.input_win then
          state.last_input_window_position = pos
        elseif windows.output_win and vim.api.nvim_get_current_win() == windows.output_win then
          state.last_output_window_position = pos
        end
      end

      M.cleanup()
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    pattern = '*',
    callback = function()
      require('opencode.state').is_opencode_focused = require('opencode.ui.ui').is_opencode_focused()
    end,
  })
end

function M.setup_resize_handler(windows)
  local resize_group = vim.api.nvim_create_augroup('OpencodeResize', { clear = true })
  vim.api.nvim_create_autocmd('VimResized', {
    group = resize_group,
    callback = function()
      require('opencode.ui.topbar').render()
      require('opencode.ui.footer').update_window(windows)
      require('opencode.ui.input_window').update_dimensions(windows)
      require('opencode.ui.output_window').update_dimensions(windows)
    end,
  })

  vim.api.nvim_create_autocmd('WinResized', {
    group = resize_group,
    callback = function(args)
      local win = tonumber(args.match)
      if not win or not vim.api.nvim_win_is_valid(win) or not output_window.mounted() then
        return
      end

      local floating = vim.api.nvim_win_get_config(win).relative ~= ''
      if floating then
        return
      end

      require('opencode.ui.topbar').render()
      require('opencode.ui.footer').update_window(windows)
    end,
  })
end

function M.cleanup()
  if idle_detector ~= nil then
    idle_detector:stop()
    idle_detector = nil
  end
end

return M
