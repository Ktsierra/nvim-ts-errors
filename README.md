# ts-errors.nvim

A Neovim plugin that prettifies TypeScript/JavaScript diagnostic errors with formatted type information in floating windows.

## Features

- Parses TypeScript diagnostic messages and extracts type literals
- Formats type snippets using `prettier` (async, non-blocking)
- Displays errors in a centered floating window with markdown rendering
- Scrollable for long errors with keyboard navigation
- Handles truncated types (`...`) in error messages gracefully
- Configurable keymaps, UI, and behavior

## Requirements

- Neovim >= 0.9.0
- `prettier` installed (via mason or globally)
- TypeScript LSP configured (tsserver, typescript-tools.nvim, etc.)

## Installation

### lazy.nvim

```lua
{
  "ktsierra/ts-errors.nvim",
  ft = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
  opts = {},
}
```

### packer.nvim

```lua
use {
  "ktsierra/ts-errors.nvim",
  config = function()
    require("ts-errors").setup()
  end,
  ft = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
}
```

## Recommended: Show Full Types in Diagnostics

By default, TypeScript truncates deeply nested types in error messages (showing `{ ... }` for nested parts). To see full types in your diagnostics, add this to your `tsconfig.json`:

```json
{
  "compilerOptions": {
    "noErrorTruncation": true
  }
}
```

Then restart your LSP server (`:LspRestart`). This makes TypeScript show complete type information, which this plugin will then format properly.

## Configuration

```lua
require("ts-errors").setup({
  -- Enable auto-open on CursorHold (like vim.diagnostic.open_float)
  auto_open = false,

  -- Delay in ms before auto-opening (only when auto_open = true)
  auto_open_delay = 300,

  -- Open immediately with unformatted content, update when prettier finishes
  format_on_open = true,

  -- Prettier configuration
  prettier = {
    -- Override command (auto-detects prettier/prettierd in mason or PATH)
    cmd = nil,
    -- Arguments for prettier
    args = { "--parser", "typescript" },
    -- Line width for wrapping long types
    print_width = 60,
    -- Timeout for formatting
    timeout_ms = 3000,
    -- Use sync formatting in format() for vim.diagnostic.config (blocks but always formatted)
    sync_format = true,
  },

  -- UI configuration
  ui = {
    border = "rounded",
    max_width = 100,
    max_height = 40,
    min_height = 15,
    winblend = 0,
    title = nil, -- auto-generated based on severity
  },

  -- Cache configuration
  cache = {
    enabled = true,
    max_entries = 100,
  },

  -- Keymaps (set in TS/JS buffers)
  keys = {
    show = "<leader>te",  -- Show prettified diagnostic
    next = "]e",          -- Next diagnostic + show
    prev = "[e",          -- Previous diagnostic + show
    close = "q",          -- Close float (when inside float)
  },
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:TSErrShow` | Show prettified diagnostic at cursor |
| `:TSErrToggle` | Toggle the diagnostic float |
| `:TSErrNext` | Go to next diagnostic and show |
| `:TSErrPrev` | Go to previous diagnostic and show |
| `:TSErrClose` | Close the diagnostic float |
| `:TSErrFocus` | Focus the float for scrolling |

### Default Keymaps

These are set automatically in TypeScript/JavaScript buffers:

| Keymap | Action |
|--------|--------|
| `<leader>te` | Show diagnostic at cursor |
| `]e` | Next diagnostic + show |
| `[e` | Previous diagnostic + show |

Inside the floating window:

| Keymap | Action |
|--------|--------|
| `q` / `<Esc>` | Close float |
| `j` / `k` | Scroll up/down |
| `<C-d>` / `<C-u>` | Half-page scroll |
| `<C-f>` / `<C-b>` | Full-page scroll |
| `gg` / `G` | Jump to top/bottom |

## How it works

1. When you trigger the show command, the plugin gets the diagnostic at cursor
2. It parses the diagnostic message to extract type literals (content inside single quotes that looks like TypeScript types)
3. Opens a floating window immediately with the parsed content as markdown
4. Asynchronously formats type blocks with prettier (wrapping long types across multiple lines)
5. Updates the floating window with the formatted content
6. Results are cached to avoid re-formatting the same errors

## Integration with vim.diagnostic.config

You can use the `format()` function to prettify TypeScript errors in the native diagnostic float:

```lua
vim.diagnostic.config({
  float = {
    format = function(diagnostic)
      -- Only format TypeScript/JavaScript diagnostics
      if diagnostic.source and diagnostic.source:match("typescript") then
        return require("ts-errors").format(diagnostic)
      end
      return diagnostic.message
    end,
  },
})
```

This will format type literals in the diagnostic message. By default, `sync_format = true` which means it blocks briefly to run prettier on first view. Set `sync_format = false` if you prefer async behavior (first view unformatted, second view formatted from cache).

## API

```lua
local ts_errors = require("ts-errors")

ts_errors.setup(opts)      -- Initialize with config
ts_errors.show(opts)       -- Show diagnostic at cursor (opts.enter to focus float)
ts_errors.toggle()         -- Toggle float open/closed
ts_errors.close()          -- Close the float
ts_errors.focus()          -- Focus the float for scrolling
ts_errors.goto_next()      -- Go to next diagnostic and show
ts_errors.goto_prev()      -- Go to previous diagnostic and show
ts_errors.format(diag)     -- Format a diagnostic message (for vim.diagnostic.config)
```
