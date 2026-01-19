---@class TSErrorsConfig
---@field auto_open boolean Enable auto-open on CursorHold (like vim.diagnostic.open_float)
---@field auto_open_delay number Delay in ms before auto-opening on CursorHold
---@field format_on_open boolean Open immediately with unformatted content, update when formatted
---@field prettier TSErrorsPrettierConfig Prettier configuration
---@field ui TSErrorsUIConfig UI configuration
---@field cache TSErrorsCacheConfig Cache configuration
---@field keys TSErrorsKeysConfig Keymap configuration

---@class TSErrorsPrettierConfig
---@field cmd string|nil Override prettier command (auto-detected if nil)
---@field args string[] Additional arguments for prettier
---@field print_width number Line width for wrapping (default 60)
---@field timeout_ms number Timeout for prettier job
---@field sync_format boolean Use sync formatting in format() function (blocks but always formatted)

---@class TSErrorsUIConfig
---@field border string Border style for floating window
---@field max_width number Maximum width of floating window
---@field max_height number Maximum height of floating window
---@field min_height number Minimum height of floating window
---@field winblend number Window transparency (0-100)
---@field title string|nil Window title (nil for auto)

---@class TSErrorsCacheConfig
---@field enabled boolean Enable caching of formatted snippets
---@field max_entries number Maximum number of cached entries

---@class TSErrorsKeysConfig
---@field show string Keymap to show prettified diagnostic
---@field next string Keymap to go to next diagnostic and show
---@field prev string Keymap to go to previous diagnostic and show
---@field close string Keymap to close the floating window (inside float)

local M = {}

---@type TSErrorsConfig
M.defaults = {
	auto_open = false,
	auto_open_delay = 300,
	format_on_open = true,
	prettier = {
		cmd = nil, -- auto-detect: prettierd -> prettier
		args = { "--parser", "typescript" },
		print_width = 60, -- force wrapping for long types
		timeout_ms = 3000,
		sync_format = true, -- use sync formatting in format() for vim.diagnostic.config
	},
	ui = {
		border = "rounded",
		max_width = 100,
		max_height = 40,
		min_height = 15,
		winblend = 0,
		title = nil,
	},
	cache = {
		enabled = true,
		max_entries = 100,
	},
	keys = {
		show = "<leader>te",
		next = "]e",
		prev = "[e",
		close = "q",
	},
}

---@type TSErrorsConfig|nil
M.options = nil

---@param opts TSErrorsConfig|nil
-- Merge user-provided configuration with the defaults and set the result as the module's active options.
-- @param opts Optional table with configuration fields to override defaults.
-- @return The merged TSErrorsConfig used as the module's active configuration.
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
	return M.options
end

-- Retrieve the active TSErrors configuration.
-- @return The current TSErrorsConfig: the merged user options if set, otherwise the defaults.
function M.get()
	if not M.options then
		return M.defaults
	end
	return M.options
end

return M