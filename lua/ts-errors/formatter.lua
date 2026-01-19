--- Formatter module for TypeScript diagnostic code blocks
--- Uses prettierd/prettier for async formatting with caching

local config = require("ts-errors.config")

local M = {}

---@type table<string, string>
M._cache = {}

---@type number
M._cache_count = 0

---@type string|nil
M._prettier_cmd = nil

---@type boolean
M._prettier_checked = false

--- Find prettier command (prefer regular prettier for --print-width support)
---@return string|nil
function M._find_prettier()
  if M._prettier_checked then
    return M._prettier_cmd
  end

  local cfg = config.get()

  -- User override
  if cfg.prettier.cmd then
    M._prettier_cmd = cfg.prettier.cmd
    M._prettier_checked = true
    return M._prettier_cmd
  end

  -- Prefer regular prettier over prettierd for --print-width support
  -- Check mason path first
  local mason_prettier = vim.fn.stdpath("data") .. "/mason/bin/prettier"
  if vim.fn.executable(mason_prettier) == 1 then
    M._prettier_cmd = mason_prettier
    M._prettier_checked = true
    return M._prettier_cmd
  end

  -- Check prettier in PATH
  if vim.fn.executable("prettier") == 1 then
    M._prettier_cmd = "prettier"
    M._prettier_checked = true
    return M._prettier_cmd
  end

  -- Fall back to prettierd (won't support --print-width but better than nothing)
  local mason_prettierd = vim.fn.stdpath("data") .. "/mason/bin/prettierd"
  if vim.fn.executable(mason_prettierd) == 1 then
    M._prettier_cmd = mason_prettierd
    M._prettier_checked = true
    return M._prettier_cmd
  end

  if vim.fn.executable("prettierd") == 1 then
    M._prettier_cmd = "prettierd"
    M._prettier_checked = true
    return M._prettier_cmd
  end

  M._prettier_checked = true
  return nil
end

--- Generate cache key for content
---@param content string
---@return string
function M._cache_key(content)
  -- Simple hash using lua string operations
  local hash = 0
  for i = 1, #content do
    hash = (hash * 31 + content:byte(i)) % 2147483647
  end
  return tostring(hash)
end

--- Get from cache
---@param content string
---@return string|nil
function M._cache_get(content)
  local cfg = config.get()
  if not cfg.cache.enabled then
    return nil
  end
  return M._cache[M._cache_key(content)]
end

--- Set in cache
---@param content string
---@param formatted string
function M._cache_set(content, formatted)
  local cfg = config.get()
  if not cfg.cache.enabled then
    return
  end

  local key = M._cache_key(content)

  -- Simple cache eviction: clear if too many entries
  if M._cache_count >= cfg.cache.max_entries then
    M._cache = {}
    M._cache_count = 0
  end

  if not M._cache[key] then
    M._cache_count = M._cache_count + 1
  end
  M._cache[key] = formatted
end

--- Format code asynchronously using prettier
---@param content string The code to format
---@param callback fun(formatted: string, err: string|nil) Callback with result
function M.format_async(content, callback)
  -- Check cache first
  local cached = M._cache_get(content)
  if cached then
    -- Use defer_fn with delay to ensure float and treesitter are fully initialized
    vim.defer_fn(function()
      callback(cached, nil)
    end, 100)
    return
  end

  local prettier_cmd = M._find_prettier()
  if not prettier_cmd then
    -- Ensure only a single callback invocation
    local finished = false
    finished = true
    vim.schedule(function()
      callback(content, "Prettier not found")
    end)
    return
  end

  local cfg = config.get()
  local stdout_data = {}
  local stderr_data = {}

  -- TypeScript error messages use "..." to indicate truncated types
  -- This is not valid TS syntax, so we replace it with a placeholder
  local sanitized_content = content:gsub("%.%.%.;", "__TS_ELLIPSIS__;")
  sanitized_content = sanitized_content:gsub("%.%.%.", "__TS_ELLIPSIS__")

  -- Wrap the type content so prettier can format it as valid TypeScript
  -- We'll unwrap it after formatting
  local wrapped_content = "type __TSErrorsType__ = " .. sanitized_content .. ";"

  -- Build command
  -- Note: prettierd does NOT support CLI options like --print-width
  -- We prefer regular prettier for consistent formatting control
  local cmd

  -- Always try to use regular prettier for --print-width support
  local prettier_bin = nil
  local mason_prettier = vim.fn.stdpath("data") .. "/mason/bin/prettier"
  
  if vim.fn.executable(mason_prettier) == 1 then
    prettier_bin = mason_prettier
  elseif vim.fn.executable("prettier") == 1 then
    prettier_bin = "prettier"
  end

  if prettier_bin then
    -- Use regular prettier with print-width
    cmd = {
      prettier_bin,
      "--print-width",
      tostring(cfg.prettier.print_width),
      "--parser",
      "typescript",
    }
  else
    -- Fall back to prettierd without print-width control
    local is_prettierd = prettier_cmd:match("prettierd$") ~= nil
    if is_prettierd then
      cmd = { prettier_cmd, "stdin.ts" }
    else
      cmd = { prettier_cmd, "--parser", "typescript" }
    end
  end

  local finished = false

  local function once(result, err, cache_ok)
    if finished then
      return
    end
    finished = true
    if not err and result and cache_ok then
      M._cache_set(content, result)
      pcall(callback, result, nil)
    else
      pcall(callback, result, err)
    end
  end

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout_data = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr_data = data
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if finished then
          return
        end

        if exit_code == 0 and #stdout_data > 0 then
          local formatted = table.concat(stdout_data, "\n")
          -- Remove trailing newline that prettier adds
          formatted = formatted:gsub("\n$", "")

          -- Unwrap: remove "type __TSErrorsType__ = " prefix and trailing ";"
          -- Handle multiline: the prefix might be on first line only
          formatted = formatted:gsub("^type __TSErrorsType__ =%s*", "")
          formatted = formatted:gsub(";%s*$", "")

          -- Restore ellipsis placeholders back to "..."
          formatted = formatted:gsub("__TS_ELLIPSIS__", "...")

          once(formatted, nil, true)
        else
          local err = table.concat(stderr_data, "\n")
          local error_msg = string.format(
            "Formatting failed (exit=%d)\ncmd: %s\nstderr: %s\nstdout: %s",
            exit_code,
            table.concat(cmd, " "),
            err ~= "" and err or "(empty)",
            #stdout_data > 0 and table.concat(stdout_data, "\n") or "(empty)"
          )
          once(content, error_msg, false)
        end
      end)
    end,
  })

  if job_id <= 0 then
    if not finished then
      finished = true
      vim.schedule(function()
        callback(content, "Failed to start prettier job")
      end)
    end
    return
  end

  -- Send wrapped content to stdin
  vim.fn.chansend(job_id, wrapped_content)
  vim.fn.chanclose(job_id, "stdin")

  -- Set timeout
  vim.defer_fn(function()
    if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      if not finished then
        finished = true
        vim.fn.jobstop(job_id)
        pcall(callback, content, "Prettier timed out")
      end
    end
  end, cfg.prettier.timeout_ms)
end

--- Format code synchronously using prettier (blocks until done)
---@param content string The code to format
---@return string formatted The formatted code (or original on error)
function M.format_sync(content)
  -- Check cache first
  local cached = M._cache_get(content)
  if cached then
    return cached
  end

  local cfg = config.get()

  -- Find prettier (prefer regular prettier, fall back to prettierd)
  local prettier_bin = nil
  local is_prettierd = false
  local mason_prettier = vim.fn.stdpath("data") .. "/mason/bin/prettier"
  local mason_prettierd = vim.fn.stdpath("data") .. "/mason/bin/prettierd"

  if vim.fn.executable(mason_prettier) == 1 then
    prettier_bin = mason_prettier
  elseif vim.fn.executable("prettier") == 1 then
    prettier_bin = "prettier"
  elseif vim.fn.executable(mason_prettierd) == 1 then
    prettier_bin = mason_prettierd
    is_prettierd = true
  elseif vim.fn.executable("prettierd") == 1 then
    prettier_bin = "prettierd"
    is_prettierd = true
  end

  if not prettier_bin then
    return content
  end

  -- Sanitize content (replace ... with placeholder)
  local sanitized_content = content:gsub("%.%.%.;", "__TS_ELLIPSIS__;")
  sanitized_content = sanitized_content:gsub("%.%.%.", "__TS_ELLIPSIS__")

  -- Wrap the type content
  local wrapped_content = "type __TSErrorsType__ = " .. sanitized_content .. ";"

  -- Run synchronously using vim.fn.system
  local result
  if is_prettierd then
    -- prettierd doesn't support --print-width, just use stdin.ts as filename
    result = vim.fn.system({ prettier_bin, "stdin.ts" }, wrapped_content)
  else
    result = vim.fn.system({
      prettier_bin,
      "--print-width", tostring(cfg.prettier.print_width),
      "--parser", "typescript",
    }, wrapped_content)
  end

  if vim.v.shell_error ~= 0 then
    return content
  end

  -- Unwrap result
  local formatted = result:gsub("\n$", "")
  formatted = formatted:gsub("^type __TSErrorsType__ =%s*", "")
  formatted = formatted:gsub(";%s*$", "")
  formatted = formatted:gsub("__TS_ELLIPSIS__", "...")

  -- Cache the result
  M._cache_set(content, formatted)

  return formatted
end

--- Clear the format cache
function M.clear_cache()
  M._cache = {}
  M._cache_count = 0
end

--- Reset prettier command detection (useful for testing)
function M.reset_prettier_detection()
  M._prettier_cmd = nil
  M._prettier_checked = false
end

return M
