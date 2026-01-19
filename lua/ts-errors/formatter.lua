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
-- Detects and returns the path or command name of a usable Prettier executable, preferring a regular `prettier` (Mason then PATH) and falling back to `prettierd`.
-- Uses a user-configured override if present and caches the detection result for subsequent calls.
-- @return The command or path to the discovered Prettier executable, or `nil` if none was found.
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
-- Compute a stable cache key from the given content.
-- Uses a small rolling hash to produce a compact string key.
-- @param content The input string to hash.
-- @return The resulting hash key as a string.
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
-- Retrieve a cached formatted result for the given content.
-- @param content The original content used to compute the cache key.
-- @return `string` containing the cached formatted content if present, `nil` if caching is disabled or no cache entry exists.
function M._cache_get(content)
  local cfg = config.get()
  if not cfg.cache.enabled then
    return nil
  end
  return M._cache[M._cache_key(content)]
end

--- Set in cache
---@param content string
-- Stores a formatted string in the module cache for the given input content.
-- Respects the user's cache configuration (no-op if caching is disabled) and evicts the entire cache when the configured max_entries is reached.
-- @param content string The original content used to compute the cache key.
-- @param formatted string The formatted result to store in the cache.
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
-- Formats a TypeScript diagnostic code block using Prettier and invokes a callback with the result.
-- If a cached formatted result exists it is returned via the callback after a short defer.
-- If Prettier is unavailable or formatting fails, the callback is invoked with the original `content` and an error message.
-- @param content The TypeScript diagnostic text to format (may contain "..." ellipses which are sanitized before formatting).
-- @param callback fun(formatted: string, err: string|nil) Callback invoked with the formatted string as first argument; the second argument is an error message when formatting failed.
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

          M._cache_set(content, formatted)
          callback(formatted, nil)
        else
          local err = table.concat(stderr_data, "\n")
          local error_msg = string.format(
            "Formatting failed (exit=%d)\ncmd: %s\nstderr: %s\nstdout: %s",
            exit_code,
            table.concat(cmd, " "),
            err ~= "" and err or "(empty)",
            #stdout_data > 0 and table.concat(stdout_data, "\n") or "(empty)"
          )
          callback(content, error_msg)
        end
      end)
    end,
  })

  if job_id <= 0 then
    vim.schedule(function()
      callback(content, "Failed to start prettier job")
    end)
    return
  end

  -- Send wrapped content to stdin
  vim.fn.chansend(job_id, wrapped_content)
  vim.fn.chanclose(job_id, "stdin")

  -- Set timeout
  vim.defer_fn(function()
    if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      vim.fn.jobstop(job_id)
      callback(content, "Prettier timed out")
    end
  end, cfg.prettier.timeout_ms)
end

--- Format code synchronously using prettier (blocks until done)
---@param content string The code to format
-- Format a TypeScript diagnostic code block using Prettier and return the formatted result.
-- @param content The TypeScript code block to format.
-- @return string formatted The formatted code; returns the original input if Prettier is not found or if formatting fails.
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

-- Reset the in-memory formatted-results cache and its entry count.
-- Clears all cached formatted outputs so subsequent formatting will re-run Prettier.
function M.clear_cache()
  M._cache = {}
  M._cache_count = 0
end

-- Clears the cached Prettier command and marks detection as not performed so discovery will run again.
-- Use to force re-detection (for example in tests or after changing environment).
function M.reset_prettier_detection()
  M._prettier_cmd = nil
  M._prettier_checked = false
end

return M