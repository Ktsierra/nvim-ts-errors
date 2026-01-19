--- UI module for TypeScript errors floating window
--- Handles markdown rendering, floating window management, scroll/focus

local config = require("ts-errors.config")
local parser = require("ts-errors.parser")
local formatter = require("ts-errors.formatter")

local M = {}

---@type number|nil Current floating window handle
M._float_win = nil

---@type number|nil Current floating buffer handle
M._float_buf = nil

---@type table|nil Current diagnostic being displayed
M._current_diagnostic = nil

--- Check if float window is valid and visible
-- Checks whether the floating diagnostic window is currently open and valid.
-- @return `true` if the floating diagnostic window is open and valid, `false` otherwise.
function M.is_open()
  return M._float_win ~= nil and vim.api.nvim_win_is_valid(M._float_win)
end

-- Closes the active floating window (if any) and clears the module's float state.
-- After closing, resets M._float_win, M._float_buf, and M._current_diagnostic to nil.
function M.close()
  if M._float_win and vim.api.nvim_win_is_valid(M._float_win) then
    vim.api.nvim_win_close(M._float_win, true)
  end
  M._float_win = nil
  M._float_buf = nil
  M._current_diagnostic = nil
end

--- Calculate window dimensions based on content and config
---@param lines string[]
-- Compute the optimal floating window width and height for the provided markdown lines.
-- Dimensions respect configured max/min bounds and the current Neovim screen size.
-- @param lines table Array of strings representing the content lines to display.
-- @return number width The computed window width in columns.
-- @return number height The computed window height in rows.
function M._calculate_dimensions(lines)
  local cfg = config.get()
  local max_width = math.min(cfg.ui.max_width, vim.o.columns - 4)
  local max_height = math.min(cfg.ui.max_height, vim.o.lines - 6)
  local min_height = cfg.ui.min_height or 15

  -- Calculate content width (longest line)
  local content_width = 0
  for _, line in ipairs(lines) do
    local line_width = vim.fn.strdisplaywidth(line)
    if line_width > content_width then
      content_width = line_width
    end
  end

  -- Calculate dimensions with padding
  local width = math.min(content_width + 4, max_width)
  local height = math.min(#lines + 2, max_height)

  -- Apply minimums
  width = math.max(width, 60)
  height = math.max(height, min_height)

  return width, height
end

--- Setup keymaps for the floating buffer
-- Install buffer-local key mappings for a floating diagnostic buffer.
-- Sets mappings to close the float (configured close key and <Esc>) and to allow common scrolling/navigation keys to behave normally inside the float.
-- @param bufnr number The buffer handle to attach the mappings to.
function M._setup_float_keymaps(bufnr)
  local cfg = config.get()
  local opts = { noremap = true, silent = true, buffer = bufnr }

  -- Close mappings
  vim.keymap.set("n", cfg.keys.close, M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)

  -- Scroll mappings
  vim.keymap.set("n", "<C-d>", "<C-d>", opts)
  vim.keymap.set("n", "<C-u>", "<C-u>", opts)
  vim.keymap.set("n", "<C-f>", "<C-f>", opts)
  vim.keymap.set("n", "<C-b>", "<C-b>", opts)
  vim.keymap.set("n", "j", "j", opts)
  vim.keymap.set("n", "k", "k", opts)
  vim.keymap.set("n", "G", "G", opts)
  vim.keymap.set("n", "gg", "gg", opts)
end

--- Create or update the floating window with content
---@param lines string[]
-- Display a markdown-formatted floating window containing the given lines.
-- Creates a scratch buffer and centered floating window, applies UI and buffer options,
-- sets up buffer-local keymaps, and registers autocommands to close and clean up the float
-- when focus returns to the source window or the window is closed.
-- @param lines string[] The lines of markdown to display in the floating buffer.
-- @param opts? table Optional settings:
--   - enter? boolean: if false, do not focus the floating window after opening (defaults to true).
--   - title? string: override for the floating window title.
function M._show_float(lines, opts)
  opts = opts or {}
  local cfg = config.get()

  -- Close existing float if any
  if M.is_open() then
    M.close()
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer content first
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Set buffer options
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false

  -- Calculate dimensions
  local width, height = M._calculate_dimensions(lines)

  -- Center the window on screen (slightly above center)
  local win_row = math.floor((vim.o.lines - height) / 2.5)
  local win_col = math.floor((vim.o.columns - width) / 2)

  -- Ensure we don't go negative
  win_row = math.max(1, win_row)
  win_col = math.max(1, win_col)

  -- Window config
  local win_opts = {
    relative = "editor",
    row = win_row,
    col = win_col,
    width = width,
    height = height,
    style = "minimal",
    border = cfg.ui.border,
    title = opts.title or cfg.ui.title or " TS Error ",
    title_pos = "center",
  }

  -- Create window
  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, win_opts)

  -- Set window options
  vim.wo[win].winblend = cfg.ui.winblend
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = false
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "n"

  -- Setup keymaps
  M._setup_float_keymaps(buf)

  -- Store references
  M._float_win = win
  M._float_buf = buf

  -- Auto-close on cursor move in main buffer (but not when entering the float)
  local source_win = vim.api.nvim_get_current_win()
  local augroup = vim.api.nvim_create_augroup("TSErrorsFloat", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    group = augroup,
    callback = function()
      local current_win = vim.api.nvim_get_current_win()
      -- Only close if we're back in the source window and moved cursor
      if current_win ~= M._float_win and current_win == source_win then
        M.close()
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
        return true -- remove autocmd
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    callback = function()
      M._float_win = nil
      M._float_buf = nil
      M._current_diagnostic = nil
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      return true
    end,
  })
end

--- Update the float buffer content (for async formatting updates)
-- Update the floating buffer's contents and resize/re-center its window to fit the given lines.
-- If the float buffer or window is invalid, this is a no-op. Otherwise it replaces the buffer text with `lines`,
-- recomputes dimensions, and updates the window position and size.
-- @param lines string[] Lines to write into the floating buffer.
function M._update_float_content(lines)
  if not M._float_buf or not vim.api.nvim_buf_is_valid(M._float_buf) then
    return
  end

  if not M._float_win or not vim.api.nvim_win_is_valid(M._float_win) then
    return
  end

  -- Make buffer modifiable, update content, then lock it again
  vim.bo[M._float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._float_buf, 0, -1, false, lines)
  vim.bo[M._float_buf].modifiable = false

  -- Recalculate and update window size, re-center
  local width, height = M._calculate_dimensions(lines)
  local win_row = math.floor((vim.o.lines - height) / 2.5)
  local win_col = math.floor((vim.o.columns - width) / 2)

  win_row = math.max(1, win_row)
  win_col = math.max(1, win_col)

  vim.api.nvim_win_set_config(M._float_win, {
    relative = "editor",
    row = win_row,
    col = win_col,
    width = width,
    height = height,
  })
end

--- Build severity title
---@param severity number
-- Get a styled title string for a diagnostic severity.
-- @param severity Diagnostic severity constant (one of vim.diagnostic.severity.*).
-- @return `' Error '`, `' Warning '`, `' Info '`, `' Hint '` for known severities, or `' Diagnostic '` for unknown severities.
function M._severity_title(severity)
  local titles = {
    [vim.diagnostic.severity.ERROR] = " Error ",
    [vim.diagnostic.severity.WARN] = " Warning ",
    [vim.diagnostic.severity.INFO] = " Info ",
    [vim.diagnostic.severity.HINT] = " Hint ",
  }
  return titles[severity] or " Diagnostic "
end

--- Show a diagnostic in the floating window
---@param diagnostic table vim.Diagnostic
-- Display a diagnostic in the floating Markdown window.
-- Builds an initial markdown view from the diagnostic message, prepends source/code if present,
-- opens (or replaces) the floating window with that content, and (if enabled) asynchronously formats
-- any code blocks and updates the float as formatted results arrive.
-- @param diagnostic table A diagnostic object; expected fields include `message` (string), and optionally `source`, `code`, and `severity`.
-- @param opts? table Optional settings. `enter` (boolean) — if true, move focus into the floating window after opening.
function M.show(diagnostic, opts)
  opts = opts or {}
  local cfg = config.get()

  if not diagnostic or not diagnostic.message then
    return
  end

  M._current_diagnostic = diagnostic

  -- Parse the diagnostic message
  local parts = parser.parse(diagnostic.message)

  -- Build initial markdown (unformatted)
  local lines = parser.to_markdown(parts)

  -- Add source info if available
  if diagnostic.source then
    table.insert(lines, 1, "**Source:** " .. diagnostic.source)
    table.insert(lines, 2, "")
  end

  -- Add code if available
  if diagnostic.code then
    local code_str = tostring(diagnostic.code)
    table.insert(lines, 1, "**Code:** " .. code_str)
    table.insert(lines, 2, "")
  end

  -- Show float immediately with unformatted content
  local title = M._severity_title(diagnostic.severity)
  M._show_float(lines, { enter = opts.enter, title = title })

  -- If format_on_open is enabled, format code blocks async and update
  if cfg.format_on_open then
    M._format_and_update(parts, diagnostic)
  end
end

--- Format code blocks and update the float
---@param parts TSErrorsPart[]
-- Asynchronously formats any code parts in `parts` and updates the visible diagnostic float with formatted output.
-- Makes a deep copy of `parts`, formats each part whose `type` is `"code"` using the async formatter, and when a result arrives replaces that part's content and refreshes the floating window if the supplied `diagnostic` is still the one being displayed.
-- @param parts array of parsed parts (tables). Code parts must have `type = "code"` and a `content` string; non-code parts are preserved.
-- @param diagnostic table The diagnostic object corresponding to the float being updated; used to ensure updates are applied only if the same diagnostic is still shown.
function M._format_and_update(parts, diagnostic)
  local formatted_parts = {}

  -- Copy parts, we'll replace code blocks as they format
  for i, part in ipairs(parts) do
    formatted_parts[i] = vim.deepcopy(part)
  end

  -- Count code parts
  local code_parts = {}
  for i, part in ipairs(parts) do
    if part.type == "code" then
      table.insert(code_parts, i)
    end
  end

  if #code_parts == 0 then
    return -- nothing to format
  end

  for _, i in ipairs(code_parts) do
    local part = parts[i]

    formatter.format_async(part.content, function(formatted, err)
      formatted_parts[i].content = formatted

      -- Update float if still showing same diagnostic and window is valid
      if M._current_diagnostic == diagnostic and M._float_buf and vim.api.nvim_buf_is_valid(M._float_buf) then
        local lines = parser.to_markdown(formatted_parts)

        -- Re-add source/code info
        if diagnostic.source then
          table.insert(lines, 1, "**Source:** " .. diagnostic.source)
          table.insert(lines, 2, "")
        end
        if diagnostic.code then
          local code_str = tostring(diagnostic.code)
          table.insert(lines, 1, "**Code:** " .. code_str)
          table.insert(lines, 2, "")
        end

        M._update_float_content(lines)
      end
    end)
  end
end

-- Set focus to the floating diagnostic window if one is open.
-- Does nothing if no valid floating window exists.
function M.focus()
  if M._float_win and vim.api.nvim_win_is_valid(M._float_win) then
    vim.api.nvim_set_current_win(M._float_win)
  end
end

--- Toggle the floating window
---@param diagnostic? table
-- Toggles the diagnostic floating window: closes it if open, otherwise shows the provided diagnostic.
-- @param diagnostic The diagnostic to display when opening the float; if nil and the float is closed, no action is taken.
-- @param opts? Table of optional settings. Supported fields:
--   - enter (boolean): whether to focus the float after opening.
function M.toggle(diagnostic, opts)
  if M.is_open() then
    M.close()
  elseif diagnostic then
    M.show(diagnostic, opts)
  end
end

return M