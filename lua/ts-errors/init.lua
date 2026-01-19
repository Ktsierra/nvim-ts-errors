--- ts-errors.nvim
--- A diagnostic plugin for TypeScript/JavaScript errors
--- Provides prettified, formatted error messages in floating windows

local config = require("ts-errors.config")
local ui = require("ts-errors.ui")
local parser = require("ts-errors.parser")
local formatter = require("ts-errors.formatter")

local M = {}

---@type number|nil
M._augroup = nil

--- Get the diagnostic at the current cursor position
-- Retrieves the diagnostic for the current cursor position.
-- Returns the diagnostic whose range contains the cursor column; if none match, returns the first diagnostic on the cursor's line; returns `nil` if there are no diagnostics on the line.
-- @return table|nil The diagnostic object at the cursor or the first diagnostic on the line, or `nil` if none exist.
function M._get_cursor_diagnostic()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  local diagnostics = vim.diagnostic.get(0, { lnum = line })

  if #diagnostics == 0 then
    return nil
  end

  -- Find the diagnostic that contains the cursor column
  for _, diag in ipairs(diagnostics) do
    if diag.col <= col and (diag.end_col or diag.col + 1) > col then
      return diag
    end
  end

  -- Return first diagnostic on line if none contain cursor
  return diagnostics[1]
end

--- Show prettified diagnostic at cursor
-- Show the prettified diagnostic for the diagnostic at the current cursor position.
-- If there is no diagnostic under the cursor, notifies the user.
-- @param opts? Optional table of options.
-- @param opts.enter? If true, focus (enter) the diagnostic float after opening.
function M.show(opts)
  local diag = M._get_cursor_diagnostic()
  if diag then
    ui.show(diag, opts)
  else
    vim.notify("No diagnostic at cursor", vim.log.levels.INFO)
  end
end

-- Toggle the visibility of the prettified diagnostic float.
-- Closes the float if it is open; otherwise shows the diagnostic at the cursor.
function M.toggle()
  if ui.is_open() then
    ui.close()
  else
    M.show()
  end
end

--- Close the diagnostic float
function M.close()
  ui.close()
end

--- Focus the diagnostic float (for scrolling)
function M.focus()
  ui.focus()
end

--- Format a diagnostic message for use in vim.diagnostic.config float.format
--- This uses cached formatted types when available.
--- If sync_format is enabled (default), it will block to format on first view.
--- Otherwise, first view is unformatted and triggers async format for next time.
---@param diagnostic vim.Diagnostic
-- Format a diagnostic message into a single-line, prettified string for display.
-- 
-- Parses the diagnostic.message into text and code parts, trims text parts, and
-- formats code parts using a cache or the configured prettier formatter.
-- Code fragments are wrapped in single quotes; asynchronous formatting may be
-- triggered for uncached fragments but the original code is returned for this call.
-- @param diagnostic Table representing a diagnostic; must include a `message` field.
-- @return string formatted message
function M.format(diagnostic)
  if not diagnostic or not diagnostic.message then
    return ""
  end

  local cfg = config.get()
  local message = diagnostic.message
  local parts = parser.parse(message)
  local result = {}

  for _, part in ipairs(parts) do
    if part.type == "text" then
      table.insert(result, vim.trim(part.content))
    elseif part.type == "code" then
      -- Try to get cached formatted version first
      local cached = formatter._cache_get(part.content)
      if cached then
        table.insert(result, "'" .. cached .. "'")
      elseif cfg.prettier.sync_format then
        -- Sync format (blocks but always formatted)
        local formatted = formatter.format_sync(part.content)
        table.insert(result, "'" .. formatted .. "'")
      else
        -- Async: return original, trigger format for next time
        formatter.format_async(part.content, function() end)
        table.insert(result, "'" .. part.content .. "'")
      end
    end
  end

  return table.concat(result, " ")
end

--- Go to next diagnostic and show prettified view
function M.goto_next()
  vim.diagnostic.goto_next()
  -- Small delay to ensure cursor position is updated
  vim.defer_fn(function()
    M.show()
  end, 10)
end

-- Move the cursor to the previous diagnostic and display its prettified view.
-- The prettified diagnostic is shown after the editor updates the cursor position.
function M.goto_prev()
  vim.diagnostic.goto_prev()
  vim.defer_fn(function()
    M.show()
  end, 10)
end

--- Setup auto-open on CursorHold
-- Enable or disable automatic opening of the diagnostic float on CursorHold for TypeScript/JavaScript files.
-- When enabling, creates an augroup "TSErrorsAutoOpen" and a CursorHold autocmd for *.ts, *.tsx, *.js, and *.jsx that shows the diagnostic at the cursor without entering the float.
-- If an existing augroup was present it is removed before applying the new setting; if `enable` is false the augroup is cleared and no autocmds are created.
-- @param enable boolean Whether to enable (true) or disable (false) the auto-open behavior.
function M._setup_auto_open(enable)
  if M._augroup then
    vim.api.nvim_del_augroup_by_id(M._augroup)
    M._augroup = nil
  end

  if not enable then
    return
  end

  local cfg = config.get()
  M._augroup = vim.api.nvim_create_augroup("TSErrorsAutoOpen", { clear = true })

  vim.api.nvim_create_autocmd("CursorHold", {
    group = M._augroup,
    pattern = { "*.ts", "*.tsx", "*.js", "*.jsx" },
    callback = function()
      local diag = M._get_cursor_diagnostic()
      if diag then
        -- Don't auto-enter the float
        ui.show(diag, { enter = false })
      end
    end,
  })
end

-- Install buffer-local keymaps for TypeScript and JavaScript filetypes.
-- Sets up an autocmd that, on the relevant FileType events, binds the configured
-- keys to show the prettified diagnostic, go to the next diagnostic, and go to
-- the previous diagnostic. Mappings are buffer-local and silent; descriptions
-- are provided for each mapping.
function M._setup_keymaps()
  local cfg = config.get()

  -- Only set up keymaps for TS/JS files
  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
    callback = function(event)
      local opts = { buffer = event.buf, silent = true }

      vim.keymap.set("n", cfg.keys.show, function()
        M.show({ enter = true })
      end, vim.tbl_extend("force", opts, { desc = "Show TS error" }))

      vim.keymap.set("n", cfg.keys.next, function()
        M.goto_next()
      end, vim.tbl_extend("force", opts, { desc = "Next TS error" }))

      vim.keymap.set("n", cfg.keys.prev, function()
        M.goto_prev()
      end, vim.tbl_extend("force", opts, { desc = "Prev TS error" }))
    end,
  })
end

-- Set up global user commands for controlling the prettified TS/JS diagnostic UI.
-- Creates the following commands:
--   - TSErrShow: show the prettified diagnostic at the cursor (enter the float).
--   - TSErrToggle: toggle the diagnostic float visibility.
--   - TSErrNext: navigate to the next diagnostic and show the prettified view.
--   - TSErrPrev: navigate to the previous diagnostic and show the prettified view.
--   - TSErrClose: close the diagnostic float.
--   - TSErrFocus: focus the diagnostic float to enable scrolling.
function M._setup_commands()
  vim.api.nvim_create_user_command("TSErrShow", function()
    M.show({ enter = true })
  end, { desc = "Show prettified TS diagnostic" })

  vim.api.nvim_create_user_command("TSErrToggle", function()
    M.toggle()
  end, { desc = "Toggle TS diagnostic float" })

  vim.api.nvim_create_user_command("TSErrNext", function()
    M.goto_next()
  end, { desc = "Go to next diagnostic and show" })

  vim.api.nvim_create_user_command("TSErrPrev", function()
    M.goto_prev()
  end, { desc = "Go to previous diagnostic and show" })

  vim.api.nvim_create_user_command("TSErrClose", function()
    M.close()
  end, { desc = "Close TS diagnostic float" })

  vim.api.nvim_create_user_command("TSErrFocus", function()
    M.focus()
  end, { desc = "Focus TS diagnostic float for scrolling" })
end

--- Setup the plugin
-- Initialize the plugin with the given options and register commands, buffer keymaps, and auto-open behavior.
-- @param opts? TSErrorsConfig Optional configuration overrides for the plugin; when omitted defaults are used.
function M.setup(opts)
  -- Initialize config
  config.setup(opts)
  local cfg = config.get()

  -- Setup commands
  M._setup_commands()

  -- Setup keymaps
  M._setup_keymaps()

  -- Setup auto-open if enabled
  M._setup_auto_open(cfg.auto_open)
end

return M