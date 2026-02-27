---Snacks.nvim terminal provider for Claude Code.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local utils = require("claudecode.utils")
local terminal = nil
local trim_timer = nil

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
end

---Cleanup timer resources
local function cleanup_timer()
  if trim_timer then
    if not trim_timer:is_closing() then
      trim_timer:stop()
      trim_timer:close()
    end
    trim_timer = nil
  end
end

---Strip trailing whitespace from terminal buffer lines
---This runs periodically to clean up padding added by the terminal emulator
local function strip_trailing_whitespace_from_buffer()
  if not terminal or not terminal:buf_valid() or not terminal.buf then
    return
  end

  local bufnr = terminal.buf

  -- Use vim.schedule to safely modify the buffer from the timer callback
  vim.schedule(function()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
    if not ok or not lines then
      return
    end

    local modified = false
    local cleaned_lines = {}
    for _, line in ipairs(lines) do
      local cleaned = line:gsub("%s+$", "")
      table.insert(cleaned_lines, cleaned)
      if cleaned ~= line then
        modified = true
      end
    end

    if modified then
      -- Terminal buffers are normally not modifiable, so we need to temporarily enable it
      local was_modifiable = vim.bo[bufnr].modifiable
      vim.bo[bufnr].modifiable = true

      pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, cleaned_lines)

      vim.bo[bufnr].modifiable = was_modifiable
    end
  end)
end

---Setup periodic timer to strip trailing whitespace from terminal buffer
local function setup_whitespace_trimming()
  -- Clean up existing timer if any
  cleanup_timer()

  -- Create new timer that runs every 100ms
  trim_timer = vim.loop.new_timer()
  if trim_timer then
    trim_timer:start(
      100, -- initial delay in ms
      100, -- repeat interval in ms
      strip_trailing_whitespace_from_buffer
    )
  end
end

---Setup event handlers for terminal instance
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
local function setup_terminal_events(term_instance, config)
  local logger = require("claudecode.logger")

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      if vim.v.event.status ~= 0 then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Clean up
      cleanup_timer()
      terminal = nil
      vim.schedule(function()
        term_instance:close({ buf = true })
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped")
    cleanup_timer()
    terminal = nil
  end, { buf = true })
end

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@return snacks.terminal.Opts opts Snacks terminal options with start_insert/auto_insert controlled by focus parameter
local function build_opts(config, env_table, focus)
  focus = utils.normalize_focus(focus)
  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = focus,
    auto_insert = focus,
    auto_close = false,
    win = vim.tbl_deep_extend("force", {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
      keys = {
        claude_new_line = {
          "<S-CR>",
          function()
            vim.api.nvim_feedkeys("\\", "t", true)
            vim.defer_fn(function()
              vim.api.nvim_feedkeys("\r", "t", true)
            end, 10)
          end,
          mode = "t",
          desc = "New line",
        },
      },
    } --[[@as snacks.win.Config]], config.snacks_win_opts or {}),
  } --[[@as snacks.terminal.Opts]]
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)

  if terminal and terminal:buf_valid() then
    -- Check if terminal exists but is hidden (no window)
    if not terminal.win or not vim.api.nvim_win_is_valid(terminal.win) then
      -- Terminal is hidden, show it using snacks toggle
      terminal:toggle()
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    else
      -- Terminal is already visible
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          -- Check if window is valid before calling nvim_win_call
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    end
    return
  end

  local opts = build_opts(config, env_table, focus)
  local term_instance = Snacks.terminal.open(cmd_string, opts)
  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config)
    terminal = term_instance

    -- Setup periodic whitespace trimming to clean terminal buffer padding
    setup_whitespace_trimming()
  else
    terminal = nil
    local logger = require("claudecode.logger")
    local error_details = {}
    if not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    end

    local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
      table.concat(error_details, ", "),
      context
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    logger.debug("terminal", error_msg)
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  cleanup_timer()
  if terminal and terminal:buf_valid() then
    terminal:close()
  end
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  -- Check if terminal exists and is visible
  if terminal and terminal:buf_valid() and terminal:win_valid() then
    -- Terminal is visible, hide it
    logger.debug("terminal", "Simple toggle: hiding visible terminal")
    terminal:toggle()
  elseif terminal and terminal:buf_valid() and not terminal:win_valid() then
    -- Terminal exists but not visible, show it
    logger.debug("terminal", "Simple toggle: showing hidden terminal")
    terminal:toggle()
  else
    -- No terminal exists, create new one
    logger.debug("terminal", "Simple toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  -- Terminal exists, is valid, but not visible
  if terminal and terminal:buf_valid() and not terminal:win_valid() then
    logger.debug("terminal", "Focus toggle: showing hidden terminal")
    terminal:toggle()
  -- Terminal exists, is valid, and is visible
  elseif terminal and terminal:buf_valid() and terminal:win_valid() then
    local claude_term_neovim_win_id = terminal.win
    local current_neovim_win_id = vim.api.nvim_get_current_win()

    -- you're IN it
    if claude_term_neovim_win_id == current_neovim_win_id then
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused)")
      terminal:toggle()
    -- you're NOT in it
    else
      logger.debug("terminal", "Focus toggle: focusing terminal")
      vim.api.nvim_set_current_win(claude_term_neovim_win_id)
      if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
        if vim.api.nvim_buf_get_option(terminal.buf, "buftype") == "terminal" then
          vim.api.nvim_win_call(claude_term_neovim_win_id, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end
  -- No terminal exists
  else
    logger.debug("terminal", "Focus toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Legacy toggle function for backward compatibility (defaults to simple_toggle)
---@param cmd_string string
---@param env_table table
---@param config table
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number
---@return number?
function M.get_active_bufnr()
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---For testing purposes
---@return table? terminal The terminal instance, or nil
function M._get_terminal_for_test()
  return terminal
end

---@type ClaudeCodeTerminalProvider
return M
