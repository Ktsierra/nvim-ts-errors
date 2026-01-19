--- Parser module for TypeScript diagnostic messages
--- Breaks diagnostic messages into structured parts for formatting

local M = {}

---@class TSErrorsPart
---@field type "text"|"code" Type of content
---@field content string The content
---@field lang string|nil Language hint for code blocks

---@param message string
-- Parse a TypeScript diagnostic message into structured parts for rendering.
-- The result separates plain text from quoted TypeScript type literals.
-- Quoted segments that are recognized as pure type literals become `code` parts with lang `"typescript"`;
-- other quoted segments become `text` parts with inline code formatting (backticks).
-- If `message` is nil or empty, returns an empty table. If a quoted segment has no matching closing quote,
-- the remainder is treated as text.
-- @param message string|nil The diagnostic message to parse.
-- @return TSErrorsPart[] Array of parts where each part is `{ type = "text"|"code", content = string, lang = string|nil }`.
function M.parse(message)
  if not message or message == "" then
    return {}
  end

  local parts = {}

  -- TypeScript error messages typically have patterns like:
  -- "Type '{ ... }' is not assignable to type '{ ... }'"
  -- "Argument of type '...' is not assignable to parameter of type '...'"
  -- We want to extract ONLY the type literals (things inside quotes that are actual types)

  local pos = 1
  local len = #message

  while pos <= len do
    local quote_start = message:find("'", pos, true)

    if not quote_start then
      -- No more quotes, add remaining as text
      local remaining = message:sub(pos)
      if remaining ~= "" then
        table.insert(parts, { type = "text", content = remaining })
      end
      break
    end

    -- Add text before the quote
    if quote_start > pos then
      local text_before = message:sub(pos, quote_start - 1)
      if text_before ~= "" then
        table.insert(parts, { type = "text", content = text_before })
      end
    end

    -- Find matching closing quote, handling nested braces/brackets
    local quote_end = M._find_closing_quote(message, quote_start + 1)

    if not quote_end then
      -- No closing quote found, treat rest as text
      local remaining = message:sub(quote_start)
      if remaining ~= "" then
        table.insert(parts, { type = "text", content = remaining })
      end
      break
    end

    -- Extract content between quotes
    local quoted_content = message:sub(quote_start + 1, quote_end - 1)

    -- Only treat as code if it's a PURE type literal (starts with { or is a complex type)
    if M._is_pure_type_literal(quoted_content) then
      table.insert(parts, {
        type = "code",
        content = quoted_content,
        lang = "typescript",
      })
    else
      -- Not a pure type, keep as inline text with quotes
      table.insert(parts, {
        type = "text",
        content = "`" .. quoted_content .. "`",
      })
    end

    pos = quote_end + 1
  end

  return parts
end

--- Find closing quote, handling nested structures
---@param str string
---@param start number
-- Find the matching closing single quote for a quote starting at `start`, treating quotes inside nested {}, [], (), and <> as not closing.
-- @param str The string to search.
-- @param start The 1-based index where the opening single quote occurs; scanning begins at this position.
-- @return The 1-based index of the matching closing single quote, or `nil` if no match is found.
function M._find_closing_quote(str, start)
  local depth_brace = 0
  local depth_bracket = 0
  local depth_paren = 0
  local depth_angle = 0

  for i = start, #str do
    local c = str:sub(i, i)

    if c == "{" then
      depth_brace = depth_brace + 1
    elseif c == "}" then
      depth_brace = depth_brace - 1
    elseif c == "[" then
      depth_bracket = depth_bracket + 1
    elseif c == "]" then
      depth_bracket = depth_bracket - 1
    elseif c == "(" then
      depth_paren = depth_paren + 1
    elseif c == ")" then
      depth_paren = depth_paren - 1
    elseif c == "<" then
      depth_angle = depth_angle + 1
    elseif c == ">" then
      depth_angle = depth_angle - 1
    elseif c == "'" then
      -- Only close if all nesting is balanced
      if depth_brace == 0 and depth_bracket == 0 and depth_paren == 0 and depth_angle == 0 then
        return i
      end
    end
  end

  return nil
end

--- Check if content is a PURE TypeScript type literal that can be formatted
--- This is stricter than before - we only want things that are valid TS syntax
---@param content string
-- Determines whether a quoted string represents a TypeScript type literal suitable for formatting as a code block.
-- This performs a heuristic check (e.g., minimum length and type-like structure) rather than a full syntax validation.
-- @param content The quoted string to evaluate.
-- @return boolean `true` if the content is considered a pure TypeScript type literal and should be formatted as code, `false` otherwise.
function M._is_pure_type_literal(content)
  -- Must be reasonably long to be worth formatting
  if #content < 30 then
    return false
  end

  -- Must START with a type-like character (object, array, function, generic)
  local first_char = content:sub(1, 1)
  local starts_with_type = first_char == "{"
    or first_char == "["
    or first_char == "("
    or content:match("^[A-Z][A-Za-z0-9_]*<") -- Generic like Array<...>
    or content:match("^[a-z]+%s*=>") -- arrow function
    or content:match("^%(%s*[a-z]") -- function params

  if not starts_with_type then
    return false
  end

  -- Should contain type-like patterns
  local has_type_pattern = content:match(":%s*[A-Za-z]") -- type annotation
    or content:match("[{].-[}]") -- object literal
    or content:match("[|&]") -- union/intersection
    or content:match("=>") -- arrow

  return has_type_pattern
end

--- Build markdown from parsed parts
---@param parts TSErrorsPart[]
-- Render parsed message parts into an array of Markdown lines.
-- Text parts are trimmed and emitted as plain lines; code parts are emitted as fenced code blocks using the part's `lang` (defaults to `"typescript"`).
-- @param parts Array of parsed parts (each with `type`, `content`, and optional `lang`) as produced by M.parse.
-- @return string[] An array of lines suitable for joining into Markdown output.
function M.to_markdown(parts)
  local lines = {}

  for _, part in ipairs(parts) do
    if part.type == "text" then
      -- Add text, handling newlines
      local text = vim.trim(part.content)
      if text ~= "" then
        table.insert(lines, text)
      end
    elseif part.type == "code" then
      -- Add as fenced code block
      table.insert(lines, "")
      table.insert(lines, "```" .. (part.lang or "typescript"))
      -- Split content by newlines
      for line in part.content:gmatch("[^\n]+") do
        table.insert(lines, line)
      end
      table.insert(lines, "```")
      table.insert(lines, "")
    end
  end

  return lines
end

return M