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
---@return boolean
function M.is_open()
  return M._float_win ~= nil and vim.api.nvim_win_is_valid(M._float_win)
end

--- Close the floating window
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
---@return number width, number height
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
---@param bufnr number
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
---@param opts? {enter?: boolean, title?: string}
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
---@param lines string[]
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
---@return string
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
---@param opts? {enter?: boolean}
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
---@param diagnostic table
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

--- Focus the floating window (for scrolling)
function M.focus()
  if M._float_win and vim.api.nvim_win_is_valid(M._float_win) then
    vim.api.nvim_set_current_win(M._float_win)
  end
end

--- Toggle the floating window
---@param diagnostic? table
---@param opts? {enter?: boolean}
function M.toggle(diagnostic, opts)
  if M.is_open() then
    M.close()
  elseif diagnostic then
    M.show(diagnostic, opts)
  end
end

return M
