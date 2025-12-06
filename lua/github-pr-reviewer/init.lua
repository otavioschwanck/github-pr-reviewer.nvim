local M = {}

local github = require("github-pr-reviewer.github")
local git = require("github-pr-reviewer.git")
local ui = require("github-pr-reviewer.ui")

M.config = {
  branch_prefix = "reviewing_",
  picker = "native",              -- "native", "fzf-lua", "telescope"
  open_files_on_review = true,    -- open modified files after starting review
  show_comments = true,           -- show PR comments in buffers during review
  show_icons = true,              -- show icons in UI elements
  show_inline_diff = true,        -- show inline diff in buffers (old lines as virtual text)
  show_floats = true,             -- show floating windows with info, stats and keymaps
  debug = false,                  -- show debug messages
  mark_as_viewed_key = "<CR>",    -- key to mark file as viewed and go to next file
  next_hunk_key = "<C-j>",        -- key to jump to next hunk
  prev_hunk_key = "<C-k>",        -- key to jump to previous hunk
  next_file_key = "<C-l>",        -- key to go to next modified file
  prev_file_key = "<C-h>",        -- key to go to previous modified file
  diff_view_toggle_key = "<C-v>", -- toggle between unified and split diff view
  toggle_floats_key = "<C-r>",    -- toggle floating windows visibility

  -- Review buffer settings
  review_buffer = {
    position = "left",            -- "left", "right", "top", "bottom"
    width = 50,                   -- width for left/right
    height = 20,                  -- height for top/bottom
    group_by_directory = true,    -- group files by directory
    sort_by = "path",             -- "path", "status", "changes"
    filter_viewed_key = "fv",     -- filter: show only viewed
    filter_not_viewed_key = "fn", -- filter: show only not viewed
    filter_all_key = "fa",        -- filter: show all
    open_split_key = "s",         -- open file in horizontal split
    open_vsplit_key = "v",        -- open file in vertical split
    toggle_key = "<C-e>",         -- toggle review buffer open/close
  },
}

local ns_id = vim.api.nvim_create_namespace("pr_review_comments")
local changes_ns_id = vim.api.nvim_create_namespace("pr_review_changes")
local diff_ns_id = vim.api.nvim_create_namespace("pr_review_diff")

-- Debug logging helper
local function debug_log(msg)
  if M.config.debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

M._buffer_comments = {}
M._buffer_changes = {}
M._buffer_hunks = {}
M._diff_view_mode = "unified" -- "unified" or "split"
M._split_view_state = {}      -- tracks split view buffers and windows
M._buffer_stats = {}
M._viewed_files = {}
M._collapsed_dirs = {}         -- tracks which directories are collapsed in review buffer
M._local_pending_comments = {} -- Local storage for pending comments (not synced to GitHub yet)
M._drafts = {}                 -- Draft comments being edited (auto-saved)
M._float_win_general = nil     -- General info float (file x/total)
M._float_win_buffer = nil      -- Buffer info float (hunks, stats, comments)
M._float_win_keymaps = nil     -- Keymaps float
M._buffer_jumped = {}          -- Track if we've already jumped to first change in buffer
M._buffer_keymaps_saved = {}   -- Track if we've saved keymaps for this buffer
M._opening_file = false        -- Prevent concurrent file opening operations

-- Review buffer state
M._review_buffer = nil       -- Review buffer number
M._review_window = nil       -- Review window ID
M._review_files = {}         -- List of files with metadata
M._review_files_ordered = {} -- Ordered list matching ReviewBuffer display order
M._review_filter = "all"     -- Current filter: "all", "viewed", "not_viewed"
M._review_sort = nil         -- Current sort (uses config default)

local function get_session_dir()
  local data_path = vim.fn.stdpath("data")
  return data_path .. "/github-pr-reviewer-sessions"
end

local function get_session_file()
  local cwd = vim.fn.getcwd()
  -- Convert path to safe filename: /home/otavio/Projetos/api -> review_home_otavio_Projetos_api
  local safe_name = cwd:gsub("^/", ""):gsub("/", "_")
  return get_session_dir() .. "/review_" .. safe_name .. ".json"
end

local function save_session()
  if not vim.g.pr_review_number then
    return
  end

  local session_dir = get_session_dir()
  vim.fn.mkdir(session_dir, "p")

  local session_data = {
    pr_number = vim.g.pr_review_number,
    base_branch = vim.g.pr_review_base_branch,
    previous_branch = vim.g.pr_review_previous_branch,
    modified_files = vim.g.pr_review_modified_files,
    viewed_files = M._viewed_files,
    pending_comments = M._local_pending_comments,
    drafts = M._drafts,
    cwd = vim.fn.getcwd(),
  }

  local session_file = get_session_file()
  local json_str = vim.fn.json_encode(session_data)
  local file = io.open(session_file, "w")
  if file then
    file:write(json_str)
    file:close()
  end
end

local function load_session()
  local session_file = get_session_file()
  local file = io.open(session_file, "r")
  if not file then
    return nil
  end

  local content = file:read("*all")
  file:close()

  local ok, session_data = pcall(vim.fn.json_decode, content)
  if not ok or not session_data then
    return nil
  end

  return session_data
end

local function delete_session()
  local session_file = get_session_file()
  vim.fn.delete(session_file)
end

-- Forward declarations
local get_inline_diff

-- Local pending comments management (stored locally, not on GitHub)
local function generate_local_comment_id()
  return "local_" .. os.time() .. "_" .. math.random(10000, 99999)
end

local function get_local_pending_comments_for_pr(pr_number)
  return M._local_pending_comments[pr_number] or {}
end

local function add_local_pending_comment(pr_number, path, line, body, user, start_line)
  if not M._local_pending_comments[pr_number] then
    M._local_pending_comments[pr_number] = {}
  end

  local comment = {
    id = generate_local_comment_id(),
    path = path,
    line = line,
    body = body,
    user = user,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    is_pending = true,
    is_local = true,
  }

  -- Add start_line for multi-line suggestions
  if start_line and start_line ~= line then
    comment.start_line = start_line
  end

  table.insert(M._local_pending_comments[pr_number], comment)
  return comment
end

local function remove_local_pending_comment(pr_number, comment_id)
  if not M._local_pending_comments[pr_number] then
    return false
  end

  for i, comment in ipairs(M._local_pending_comments[pr_number]) do
    if comment.id == comment_id then
      table.remove(M._local_pending_comments[pr_number], i)
      return true
    end
  end

  return false
end

local function get_local_pending_comments_for_file(pr_number, file_path)
  local all_comments = get_local_pending_comments_for_pr(pr_number)
  local file_comments = {}

  for _, comment in ipairs(all_comments) do
    if comment.path == file_path then
      table.insert(file_comments, comment)
    end
  end

  return file_comments
end

-- Collect all files from PR with their metadata
local function collect_pr_files(callback)
  -- First get tracked changes (M, A, D)
  local cmd = "git diff --name-status HEAD"
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then
        vim.schedule(function()
          callback({})
        end)
        return
      end

      local files = {}
      for _, line in ipairs(data) do
        -- Format: M\tfile/path.txt or A\tfile/path.txt or D\tfile/path.txt
        local status, path = line:match("^([AMD])%s+(.+)$")
        if status and path then
          table.insert(files, {
            path = path,
            status = status, -- M=modified, A=added, D=deleted
            viewed = M._viewed_files[path] or false,
            stats = { additions = 0, modifications = 0, deletions = 0 },
          })
        end
      end

      -- Now get untracked files
      local untracked_cmd = "git ls-files --others --exclude-standard"
      vim.fn.jobstart(untracked_cmd, {
        stdout_buffered = true,
        on_stdout = function(_, untracked_data)
          if untracked_data then
            for _, line in ipairs(untracked_data) do
              if line and line ~= "" then
                table.insert(files, {
                  path = line,
                  status = "N", -- new/untracked
                  viewed = M._viewed_files[line] or false,
                  stats = { additions = 0, modifications = 0, deletions = 0 },
                })
              end
            end
          end

          -- Now get stats for each file
          local pending = #files
          if pending == 0 then
            vim.schedule(function()
              callback(files)
            end)
            return
          end

          for _, file in ipairs(files) do
            get_inline_diff(file.path, file.status, function(hunks)
              if hunks and #hunks > 0 then
                local additions = 0
                local deletions = 0
                local modifications = 0

                for _, hunk in ipairs(hunks) do
                  local added = #hunk.added_lines
                  local removed = #hunk.removed_lines

                  if added > 0 and removed > 0 then
                    modifications = modifications + math.min(added, removed)
                    additions = additions + math.max(0, added - removed)
                    deletions = deletions + math.max(0, removed - added)
                  elseif added > 0 then
                    additions = additions + added
                  elseif removed > 0 then
                    deletions = deletions + removed
                  end
                end

                file.stats = {
                  additions = additions,
                  modifications = modifications,
                  deletions = deletions,
                }
              end

              pending = pending - 1
              if pending == 0 then
                vim.schedule(function()
                  callback(files)
                end)
              end
            end)
          end
        end,
      })
    end,
  })
end

local function get_relative_path(bufnr)
  local full_path = vim.api.nvim_buf_get_name(bufnr)

  -- Remove [DELETED] suffix if present
  full_path = full_path:gsub(" %[DELETED%]$", "")

  local cwd = vim.fn.getcwd()
  if full_path:sub(1, #cwd) == cwd then
    return full_path:sub(#cwd + 2)
  end
  return full_path
end

local function get_changed_lines_for_file(file_path, status, callback)
  local cmd
  if status == "N" then
    -- For new/untracked files, compare with /dev/null
    cmd = string.format("git diff --unified=0 --no-index /dev/null -- %s", vim.fn.shellescape(file_path))
  else
    cmd = string.format("git diff --unified=0 HEAD -- %s", vim.fn.shellescape(file_path))
  end
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local all_lines = {}
      if data then
        for _, line in ipairs(data) do
          local start_line, count = line:match("^@@%s+%-%d+[,%d]*%s+%+(%d+),?(%d*)%s+@@")
          if start_line then
            start_line = tonumber(start_line)
            count = tonumber(count) or 1
            if count == 0 then count = 1 end
            for i = 0, count - 1 do
              table.insert(all_lines, start_line + i)
            end
          end
        end
      end

      table.sort(all_lines)

      local unique_lines = {}
      local seen = {}
      for _, l in ipairs(all_lines) do
        if not seen[l] then
          seen[l] = true
          table.insert(unique_lines, l)
        end
      end

      local hunks = {}
      if #unique_lines > 0 then
        local current_hunk = { start_line = unique_lines[1], end_line = unique_lines[1] }
        for i = 2, #unique_lines do
          if unique_lines[i] == current_hunk.end_line + 1 then
            current_hunk.end_line = unique_lines[i]
          else
            table.insert(hunks, current_hunk)
            current_hunk = { start_line = unique_lines[i], end_line = unique_lines[i] }
          end
        end
        table.insert(hunks, current_hunk)
      end

      vim.schedule(function()
        callback(unique_lines, hunks)
      end)
    end,
  })
end

-- Forward declaration
local update_changes_float

get_inline_diff = function(file_path, status, callback)
  -- For new/untracked files, use a different command to get all lines
  local cmd
  if status == "A" or status == "N" then
    cmd = string.format("git diff --unified=0 --no-index /dev/null -- %s", vim.fn.shellescape(file_path))
  else
    cmd = string.format("git diff --unified=0 HEAD -- %s", vim.fn.shellescape(file_path))
  end

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then
        vim.schedule(function()
          callback({})
        end)
        return
      end

      local hunks = {}
      local current_hunk = nil
      local in_hunk = false

      for _, line in ipairs(data) do
        -- Parse hunk header: @@ -old_start,old_count +new_start,new_count @@
        local old_start, old_count, new_start, new_count = line:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")
        if old_start then
          old_start = tonumber(old_start)
          old_count = tonumber(old_count) or 1
          new_start = tonumber(new_start)
          new_count = tonumber(new_count) or 1

          current_hunk = {
            old_start = old_start,
            old_count = old_count,
            new_start = new_start,
            new_count = new_count,
            removed_lines = {},
            added_lines = {},
          }
          table.insert(hunks, current_hunk)
          in_hunk = true
        elseif in_hunk and current_hunk then
          if line:match("^%-") and not line:match("^%-%-%- ") then
            -- Removed line
            table.insert(current_hunk.removed_lines, line:sub(2))
          elseif line:match("^%+") and not line:match("^%+%+%+ ") then
            -- Added line (current content)
            table.insert(current_hunk.added_lines, line:sub(2))
          end
        end
      end

      vim.schedule(function()
        callback(hunks)
      end)
    end,
  })
end

-- Helper to get syntax-highlighted chunks for a line
local function get_syntax_highlights(text, filetype)
  -- Simply return text with DiffDelete highlight, preserving indentation
  -- Note: Syntax highlighting for deleted lines was removed due to severe performance issues
  -- (vim.inspect_pos() for every character was extremely slow)
  -- Return text without prefix, preserving original indentation
  return { { text, "DiffDelete" } }
end

local function display_inline_diff(bufnr, hunks)
  if not M.config.show_inline_diff then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, diff_ns_id, 0, -1)

  -- Get the filetype for syntax highlighting
  local filetype = vim.bo[bufnr].filetype or ""

  for _, hunk in ipairs(hunks) do
    local new_line = hunk.new_start

    -- Show removed lines as virtual text above the first added line
    if #hunk.removed_lines > 0 then
      -- When new_count is 0 (only deletions), new_start points to the line after the deletion
      -- So we use new_line directly. When there are additions, we use new_line - 1 to place
      -- the deletions above the first addition.
      local line_idx = hunk.new_count == 0 and new_line or (new_line - 1)

      local virt_lines = {}
      for _, removed in ipairs(hunk.removed_lines) do
        -- Get syntax-highlighted chunks for the removed line
        local chunks = get_syntax_highlights(removed, filetype)
        table.insert(virt_lines, chunks)
      end

      -- Place virtual lines above the first new line
      if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
        vim.api.nvim_buf_set_extmark(bufnr, diff_ns_id, line_idx, 0, {
          virt_lines_above = true,
          virt_lines = virt_lines,
        })
      end
    end

    -- Highlight added/modified lines
    for i = 0, hunk.new_count - 1 do
      local line_idx = new_line + i - 1
      if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
        vim.api.nvim_buf_set_extmark(bufnr, diff_ns_id, line_idx, 0, {
          line_hl_group = "DiffAdd",
          sign_text = "+",
          sign_hl_group = "DiffAdd",
        })
      end
    end
  end
end

local function load_inline_diff_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.g.pr_review_number or not M.config.show_inline_diff then
    return
  end

  -- Don't load inline diff when in split view mode
  if M._diff_view_mode == "split" then
    return
  end

  local file_path = get_relative_path(bufnr)

  -- Find status from review files
  local status = "M" -- default to modified
  for _, file in ipairs(M._review_files) do
    if file.path == file_path then
      status = file.status
      break
    end
  end

  -- Don't show inline diff for new files (entire file would be green)
  if status == "A" or status == "N" then
    return
  end

  get_inline_diff(file_path, status, function(hunks)
    if hunks and #hunks > 0 then
      -- Calculate stats
      local additions = 0
      local deletions = 0
      local modifications = 0

      for _, hunk in ipairs(hunks) do
        local added = #hunk.added_lines
        local removed = #hunk.removed_lines

        if added > 0 and removed > 0 then
          -- Lines were modified
          modifications = modifications + math.min(added, removed)
          additions = additions + math.max(0, added - removed)
          deletions = deletions + math.max(0, removed - added)
        elseif added > 0 then
          -- Only additions
          additions = additions + added
        elseif removed > 0 then
          -- Only deletions
          deletions = deletions + removed
        end
      end

      M._buffer_stats[bufnr] = {
        additions = additions,
        deletions = deletions,
        modifications = modifications,
      }

      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          display_inline_diff(bufnr, hunks)
          -- Update the floating indicator immediately
          if bufnr == vim.api.nvim_get_current_buf() then
            vim.defer_fn(update_changes_float, 10)
          end
        end
      end)
    end
  end)
end

-- Create split diff view (side by side)
local function create_split_view(current_bufnr, file_path)

  -- Make sure we're in the file window, not the review window
  local current_win = vim.api.nvim_get_current_win()

  -- If we're in the review window, find the file window
  if M._review_window and current_win == M._review_window then
    -- Find a window with the current buffer
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == current_bufnr and win ~= M._review_window then
        vim.api.nvim_set_current_win(win)
        current_win = win
        break
      end
    end
  end

  -- Try to get base version of the file
  -- Build list of attempts to find the base version
  local base_branch = vim.g.pr_review_base_branch
  local attempts = {}

  -- If we have base_branch, try it first
  if base_branch then
    table.insert(attempts, string.format("origin/%s:%s", base_branch, file_path))
    table.insert(attempts, string.format("%s:%s", base_branch, file_path))
  end

  -- Fallback attempts
  table.insert(attempts, string.format("origin/main:%s", file_path))
  table.insert(attempts, string.format("origin/master:%s", file_path))
  table.insert(attempts, string.format("main:%s", file_path))
  table.insert(attempts, string.format("master:%s", file_path))
  table.insert(attempts, string.format("HEAD~1:%s", file_path))

  local base_content
  local success = false

  for _, attempt in ipairs(attempts) do
    local cmd = "git show " .. attempt
    base_content = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 then
      success = true
      debug_log("Split view: Using base from " .. attempt)
      break
    end
  end

  -- If all attempts failed, file might be new
  if not success then
    base_content = {}
    debug_log("Split view: File appears to be new, using empty base")
  end

  -- Create a new buffer for base version
  local base_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, base_content)
  vim.bo[base_buf].filetype = vim.bo[current_bufnr].filetype
  vim.bo[base_buf].buftype = "nofile"
  vim.bo[base_buf].modifiable = false

  -- Set buffer name - delete any existing buffer with this name first
  local buf_name = string.format("[BEFORE] %s", file_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == buf_name then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.api.nvim_buf_set_name(base_buf, buf_name)

  -- Create vertical split to the left
  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()

  -- Show base version (BEFORE) in left window
  vim.api.nvim_win_set_buf(left_win, base_buf)

  -- Go to right window and show current version (AFTER)
  vim.cmd("wincmd l")
  local right_win = vim.api.nvim_get_current_win()

  -- Make sure current buffer is shown (should already be, but ensure it)
  if vim.api.nvim_win_get_buf(right_win) ~= current_bufnr then
    vim.api.nvim_win_set_buf(right_win, current_bufnr)
  end

  -- Don't reload the file - it already has the PR changes (unstaged modifications)
  -- Reloading with edit! would reset it to the committed version

  -- Clear inline diff and change indicators from the current buffer (we don't need them in split view)
  vim.api.nvim_buf_clear_namespace(current_bufnr, diff_ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(current_bufnr, changes_ns_id, 0, -1)

  -- Enable diff mode in both windows
  vim.api.nvim_win_call(left_win, function()
    vim.cmd("diffthis")
    vim.wo.foldenable = false -- Disable folding
  end)

  vim.api.nvim_win_call(right_win, function()
    vim.cmd("diffthis")
    vim.wo.foldenable = false -- Disable folding
  end)

  -- Force diff update
  vim.cmd("diffupdate")

  -- Store split view state
  M._split_view_state = {
    base_buf = base_buf,
    current_buf = current_bufnr,
    left_win = left_win,
    right_win = right_win,
    original_win = current_win,
    file_path = file_path,
  }
end

local function restore_unified_view()
  if not M._split_view_state or not M._split_view_state.base_buf then
    return
  end

  local state = M._split_view_state

  -- Disable diff mode
  if vim.api.nvim_win_is_valid(state.left_win) then
    vim.api.nvim_win_call(state.left_win, function()
      vim.cmd("diffoff")
    end)
  end
  if vim.api.nvim_win_is_valid(state.right_win) then
    vim.api.nvim_win_call(state.right_win, function()
      vim.cmd("diffoff")
    end)
  end

  -- Close left window (base version)
  -- Only close if it's not the last window
  if vim.api.nvim_win_is_valid(state.left_win) then
    local win_count = #vim.api.nvim_list_wins()
    if win_count > 1 then
      pcall(vim.api.nvim_win_close, state.left_win, true)
    end
  end

  -- Delete base buffer
  if vim.api.nvim_buf_is_valid(state.base_buf) then
    vim.api.nvim_buf_delete(state.base_buf, { force = true })
  end

  -- Make sure we're in the current version window
  if vim.api.nvim_win_is_valid(state.right_win) then
    vim.api.nvim_set_current_win(state.right_win)
  end

  -- Reload inline diff for the buffer
  if state.current_buf and vim.api.nvim_buf_is_valid(state.current_buf) then
    load_inline_diff_for_buffer(state.current_buf)
  end

  -- Clear state
  M._split_view_state = {}

  -- Reset mode to unified (this is critical!)
  M._diff_view_mode = "unified"
end

-- Toggle between unified and split diff view
function M.toggle_diff_view()
  if not vim.g.pr_review_number then
    vim.notify("Not in PR review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = get_relative_path(bufnr)

  if not file_path then
    vim.notify("Not a tracked file in PR review", vim.log.levels.WARN)
    return
  end

  if M._diff_view_mode == "unified" then
    -- Switch to split view
    M._diff_view_mode = "split"
    create_split_view(bufnr, file_path)
  else
    -- Switch back to unified view
    M._diff_view_mode = "unified"
    restore_unified_view(bufnr)
  end
end

function M.fix_vsplit()
  if not vim.g.pr_review_number then
    vim.notify("Not in PR review mode", vim.log.levels.WARN)
    return
  end

  if M._diff_view_mode ~= "split" then
    vim.notify("Not in split view mode", vim.log.levels.WARN)
    return
  end

  local current_bufnr = vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(current_bufnr)

  -- If we're in the base buffer ([BEFORE]), we need to find the actual file buffer
  if buf_name:match("^%[BEFORE%]") then
    if M._split_view_state and M._split_view_state.current_buf then
      current_bufnr = M._split_view_state.current_buf
    else
      vim.notify("ERROR: In [BEFORE] buffer but no split state found", vim.log.levels.ERROR)
      return
    end
  end

  -- Restore to unified view (this closes the split and cleans up)
  restore_unified_view()

  -- Clean up diff state and reload the file
  local file_path = vim.api.nvim_buf_get_name(current_bufnr)
  if file_path and file_path ~= "" then
    -- Turn off diff mode completely to clear any stale diff state
    vim.cmd("diffoff!")

    -- Clear all possible namespaces that might have stale highlights
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)  -- -1 = all namespaces

    -- Reload the file to clear internal Vim state
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
  end

  -- Use defer_fn with 50ms delay (same as C-h/C-l navigation)
  -- This gives Vim time to fully process the file reload before creating the split
  vim.defer_fn(function()
    M._diff_view_mode = "unified"
    M.toggle_diff_view()
  end, 50)
end

local function close_float_wins()
  if M._float_win_general and vim.api.nvim_win_is_valid(M._float_win_general) then
    vim.api.nvim_win_close(M._float_win_general, true)
  end
  if M._float_win_buffer and vim.api.nvim_win_is_valid(M._float_win_buffer) then
    vim.api.nvim_win_close(M._float_win_buffer, true)
  end
  if M._float_win_keymaps and vim.api.nvim_win_is_valid(M._float_win_keymaps) then
    vim.api.nvim_win_close(M._float_win_keymaps, true)
  end
  M._float_win_general = nil
  M._float_win_buffer = nil
  M._float_win_keymaps = nil
end

-- Toggle floating windows visibility
function M.toggle_floats()
  if not vim.g.pr_review_number then
    return
  end

  M.config.show_floats = not M.config.show_floats

  if M.config.show_floats then
    -- Show floats
    update_changes_float()
    vim.notify("Floating windows enabled", vim.log.levels.INFO)
  else
    -- Hide floats
    close_float_wins()
    vim.notify("Floating windows disabled", vim.log.levels.INFO)
  end
end

-- Group files by directory
local function group_files_by_directory(files)
  local grouped = {}
  for _, file in ipairs(files) do
    local dir = file.path:match("(.+)/[^/]+$") or "."
    if not grouped[dir] then
      grouped[dir] = {}
    end
    table.insert(grouped[dir], file)
  end
  return grouped
end

-- Render the review buffer
local function render_review_buffer()
  if not M._review_buffer or not vim.api.nvim_buf_is_valid(M._review_buffer) then
    return
  end

  -- Get current file to highlight it
  local current_file_path = nil
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
    current_file_path = get_relative_path(current_buf)
  end

  local lines = {}
  local highlights = {}
  local file_map = {}          -- Maps line number to file
  M._review_files_ordered = {} -- Reset ordered list

  -- Header
  local cfg = M.config.review_buffer
  table.insert(lines, "═══ PR Review ═══")
  table.insert(lines, "")
  table.insert(lines, string.format("[%s] Toggle | [q] Close", cfg.toggle_key))
  table.insert(lines,
    string.format("Filters: [%s] All  [%s] Viewed  [%s] Not Viewed", cfg.filter_all_key, cfg.filter_viewed_key,
      cfg.filter_not_viewed_key))
  table.insert(lines,
    string.format("Open: [<CR>] Current  [%s] Split  [%s] VSplit", cfg.open_split_key, cfg.open_vsplit_key))
  table.insert(lines, string.format("Sort: %s | Filter: %s", M._review_sort or cfg.sort_by, M._review_filter))
  table.insert(lines, "")

  -- Filter files based on current filter
  local filtered_files = {}
  for _, file in ipairs(M._review_files) do
    if M._review_filter == "all" then
      table.insert(filtered_files, file)
    elseif M._review_filter == "viewed" and file.viewed then
      table.insert(filtered_files, file)
    elseif M._review_filter == "not_viewed" and not file.viewed then
      table.insert(filtered_files, file)
    end
  end

  -- Group and sort
  if cfg.group_by_directory then
    local grouped = group_files_by_directory(filtered_files)
    local dirs = vim.tbl_keys(grouped)
    table.sort(dirs)

    for _, dir in ipairs(dirs) do
      local is_collapsed = M._collapsed_dirs[dir]
      local icon = is_collapsed and (M.config.show_icons and "▶" or "+") or (M.config.show_icons and "▼" or "-")
      local dir_line = string.format("%s 📁 %s/", icon, dir)
      local dir_line_idx = #lines + 1
      table.insert(lines, dir_line)
      table.insert(highlights, { line = #lines - 1, hl_group = "Directory" })

      -- Store directory reference in file_map so we can toggle it
      file_map[dir_line_idx] = { is_directory = true, path = dir }

      -- Only show files if directory is not collapsed
      if not is_collapsed then
        for _, file in ipairs(grouped[dir]) do
          -- Add to ordered list
          table.insert(M._review_files_ordered, file)

          local filename = file.path:match("[^/]+$")
          local status_icon = file.status == "M" and "M" or
              (file.status == "A" and "A" or (file.status == "D" and "D" or "N"))
          local viewed_icon = file.viewed and (M.config.show_icons and "✓" or "[V]") or
              (M.config.show_icons and "○" or "[ ]")
          local stats_str = string.format("+%d ~%d -%d", file.stats.additions, file.stats.modifications,
            file.stats.deletions)

          -- Add indicator for current file
          local current_indicator = ""
          if current_file_path and file.path == current_file_path then
            current_indicator = M.config.show_icons and " ➤" or " >"
          end

          local line = string.format("  %s %s %s  %s%s", viewed_icon, status_icon, filename, stats_str, current_indicator)
          local line_idx = #lines + 1
          table.insert(lines, line)
          file_map[line_idx] = file

          -- Calculate filename position in the line for highlighting
          local filename_start = string.len("  " .. viewed_icon .. " " .. status_icon .. " ")
          local filename_end = filename_start + string.len(filename)

          -- Highlight based on status or if current file
          if current_file_path and file.path == current_file_path then
            -- Highlight entire line for current file
            table.insert(highlights, { line = line_idx - 1, hl_group = "CursorLine" })
            -- Highlight filename with special color
            table.insert(highlights,
              { line = line_idx - 1, hl_group = "Search", start_col = filename_start, end_col = filename_end })
          else
            -- Apply viewed dimming
            if file.viewed then
              table.insert(highlights, { line = line_idx - 1, hl_group = "Comment" })
            elseif file.status == "A" or file.status == "N" then
              table.insert(highlights, { line = line_idx - 1, hl_group = "DiffAdd" })
            elseif file.status == "D" then
              table.insert(highlights, { line = line_idx - 1, hl_group = "DiffDelete" })
            elseif file.status == "M" then
              table.insert(highlights, { line = line_idx - 1, hl_group = "DiffChange" })
            end
          end
        end
      end -- end of if not is_collapsed
      table.insert(lines, "")
    end
  else
    -- Flat list
    for _, file in ipairs(filtered_files) do
      -- Add to ordered list
      table.insert(M._review_files_ordered, file)

      local status_icon = file.status == "M" and "M" or
          (file.status == "A" and "A" or (file.status == "D" and "D" or "N"))
      local viewed_icon = file.viewed and (M.config.show_icons and "✓" or "[V]") or
          (M.config.show_icons and "○" or "[ ]")
      local stats_str = string.format("+%d ~%d -%d", file.stats.additions, file.stats.modifications, file.stats
        .deletions)

      -- Add indicator for current file
      local current_indicator = ""
      if current_file_path and file.path == current_file_path then
        current_indicator = M.config.show_icons and " ➤" or " >"
      end

      local line = string.format("%s %s %s  %s%s", viewed_icon, status_icon, file.path, stats_str, current_indicator)
      local line_idx = #lines + 1
      table.insert(lines, line)
      file_map[line_idx] = file

      -- Calculate file path position in the line for highlighting
      local filepath_start = string.len(viewed_icon .. " " .. status_icon .. " ")
      local filepath_end = filepath_start + string.len(file.path)

      -- Highlight based on status or if current file
      if current_file_path and file.path == current_file_path then
        -- Highlight entire line for current file
        table.insert(highlights, { line = line_idx - 1, hl_group = "CursorLine" })
        -- Highlight filepath with special color
        table.insert(highlights,
          { line = line_idx - 1, hl_group = "Search", start_col = filepath_start, end_col = filepath_end })
      else
        -- Apply viewed dimming
        if file.viewed then
          table.insert(highlights, { line = line_idx - 1, hl_group = "Comment" })
        elseif file.status == "A" or file.status == "N" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffAdd" })
        elseif file.status == "D" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffDelete" })
        elseif file.status == "M" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffChange" })
        end
      end
    end
  end

  -- Set lines
  vim.bo[M._review_buffer].modifiable = true
  vim.api.nvim_buf_set_lines(M._review_buffer, 0, -1, false, lines)
  vim.bo[M._review_buffer].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("pr_review_buffer")
  vim.api.nvim_buf_clear_namespace(M._review_buffer, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.start_col and hl.end_col then
      -- Highlight specific range (for file name)
      vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, hl.start_col, hl.end_col)
    else
      -- Highlight entire line
      vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, 0, -1)
    end
  end

  -- Store file map in buffer variable
  vim.b[M._review_buffer].pr_file_map = file_map
end

-- Helper to open a file (including deleted files)
local function open_file_safe(file, split_cmd)
  -- Check if we're in the review buffer - if so, move to another window first
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf == M._review_buffer then
    -- Find a non-review window to use
    local found_window = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if buf ~= M._review_buffer and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        found_window = true
        break
      end
    end

    -- If we didn't find another window, create a new split to the right
    if not found_window then
      -- Make sure we're in the review buffer window
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == M._review_buffer then
          vim.api.nvim_set_current_win(win)
          break
        end
      end
      -- Create a new window to the right with an empty buffer
      vim.cmd("rightbelow vnew")
    elseif split_cmd then
      -- Create split in the found window
      if split_cmd == "split" then
        vim.cmd("split")
      elseif split_cmd == "vsplit" then
        vim.cmd("vsplit")
      end
    end
  elseif split_cmd then
    -- Not in review buffer, just create the split
    if split_cmd == "split" then
      vim.cmd("split")
    elseif split_cmd == "vsplit" then
      vim.cmd("vsplit")
    end
  end

  if file.status == "D" then
    -- Check if buffer already exists
    local deleted_buf_name = file.path .. " [DELETED]"
    local existing_buf = vim.fn.bufnr(deleted_buf_name)

    if existing_buf ~= -1 then
      -- Buffer already exists, just switch to it
      vim.api.nvim_set_current_buf(existing_buf)
      -- Don't auto-mark as viewed - user should explicitly mark with mark_as_viewed_key
    else
      -- Open deleted file from HEAD
      local cmd = string.format("git show HEAD:%s", vim.fn.shellescape(file.path))
      vim.fn.jobstart(cmd, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          vim.schedule(function()
            if not data or #data == 0 then
              vim.notify("Could not load deleted file content", vim.log.levels.ERROR)
              return
            end

            -- Filter empty last line if present
            if data[#data] == "" then
              table.remove(data, #data)
            end

            -- Create scratch buffer with old content
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, data)
            vim.bo[buf].filetype = vim.filetype.match({ filename = file.path }) or ""
            vim.bo[buf].buftype = "nofile"
            vim.bo[buf].modifiable = false
            vim.api.nvim_buf_set_name(buf, deleted_buf_name)

            -- Highlight all lines in red (deleted)
            local deleted_ns = vim.api.nvim_create_namespace("pr_review_deleted_file")
            local line_count = vim.api.nvim_buf_line_count(buf)
            for i = 0, line_count - 1 do
              vim.api.nvim_buf_set_extmark(buf, deleted_ns, i, 0, {
                line_hl_group = "DiffDelete",
                sign_text = "-",
                sign_hl_group = "DiffDelete",
              })
            end

            vim.api.nvim_set_current_buf(buf)
            -- Don't auto-mark as viewed - user should explicitly mark with mark_as_viewed_key
          end)
        end,
      })
    end
  else
    -- Open normal file
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/" .. file.path))
  end
end

-- Open file from review buffer (handles deleted files and directory toggling)
local function open_file_from_review(split_type)
  -- Prevent concurrent file opening operations
  if M._opening_file then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file_map = vim.b[bufnr].pr_file_map
  if not file_map or type(file_map) ~= "table" then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local item = file_map[line]

  if not item or type(item) ~= "table" then
    return
  end

  -- Check if it's a directory - toggle collapse/expand
  if item.is_directory then
    local dir = item.path
    M._collapsed_dirs[dir] = not M._collapsed_dirs[dir]
    render_review_buffer()
    return
  end

  -- It's a file
  local file = item
  if not file.path then
    return
  end

  M._opening_file = true

  -- If in split mode, restore unified before opening new file
  local was_split = M._diff_view_mode == "split"
  if was_split then
    restore_unified_view()
  end

  -- Use the safe open function with split command
  open_file_safe(file, split_type)

  -- If was in split mode, recreate split for new file
  if was_split and not split_type then -- Only if not opening in split/vsplit
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(vim.api.nvim_get_current_buf()) then
        local new_bufnr = vim.api.nvim_get_current_buf()
        local file_path = get_relative_path(new_bufnr)
        if file_path then
          M._diff_view_mode = "unified" -- Reset to unified first
          M.toggle_diff_view()          -- Then toggle to split
        end
      end
      M._opening_file = false
    end, 50)
  else
    M._opening_file = false
  end
end

-- Toggle filter
local function set_review_filter(filter)
  M._review_filter = filter
  render_review_buffer()
end

-- Setup keymaps for review buffer
local function setup_review_buffer_keymaps(bufnr)
  local cfg = M.config.review_buffer

  -- Store the callback in a global table so it can be called
  _G._pr_reviewer_open_file = function()
    open_file_from_review(nil)
  end

  -- Open file - using nvim_buf_set_keymap for compatibility
  vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", [[<Cmd>lua _G._pr_reviewer_open_file()<CR>]],
    { noremap = true, silent = true, nowait = true })

  vim.keymap.set("n", cfg.open_split_key, function()
    open_file_from_review("split")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open file in split" })
  vim.keymap.set("n", cfg.open_vsplit_key, function()
    open_file_from_review("vsplit")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open file in vsplit" })

  -- Filters
  vim.keymap.set("n", cfg.filter_all_key, function() set_review_filter("all") end,
    { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: all files" })
  vim.keymap.set("n", cfg.filter_viewed_key, function() set_review_filter("viewed") end,
    { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: viewed files" })
  vim.keymap.set("n", cfg.filter_not_viewed_key, function() set_review_filter("not_viewed") end,
    { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: not viewed files" })

  -- Note: We DON'T register mark_as_viewed_key here because:
  -- 1. In ReviewBuffer, <CR> should open files, not mark them as viewed
  -- 2. mark_as_viewed is for file buffers, not the ReviewBuffer itself
  -- 3. If user wants to mark as viewed from ReviewBuffer, they can use a different key (e.g., 'm')

  -- Optional: Add a different key for marking files as viewed from ReviewBuffer
  vim.keymap.set("n", "m", function()
    local buf = vim.api.nvim_get_current_buf()
    local file_map = vim.b[buf].pr_file_map
    if not file_map or type(file_map) ~= "table" then return end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local file = file_map[line]

    if file and type(file) == "table" and file.path then
      file.viewed = true
      M._viewed_files[file.path] = true
      save_session()
      render_review_buffer()
      -- Move to next file
      vim.cmd("normal! j")
    end
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Mark file as viewed" })

  -- Close buffer
  vim.keymap.set("n", "q", function()
    if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
      vim.api.nvim_win_close(M._review_window, true)
    end
    M._review_window = nil
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Close review buffer" })
end

-- Open or refresh review buffer
function M.open_review_buffer(callback)
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Collect files if not already collected
  if #M._review_files == 0 then
    collect_pr_files(function(files)
      M._review_files = files
      M.open_review_buffer(callback) -- Recursive call after files are loaded
    end)
    return
  end

  -- Create buffer if it doesn't exist
  if not M._review_buffer or not vim.api.nvim_buf_is_valid(M._review_buffer) then
    M._review_buffer = vim.api.nvim_create_buf(false, true)

    -- Try to set name, if it fails (buffer already exists), wipe the old one
    local success, err = pcall(vim.api.nvim_buf_set_name, M._review_buffer, "PR Review")
    if not success then
      -- Find and delete the existing buffer with this name
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match("PR Review$") then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      -- Try again
      vim.api.nvim_buf_set_name(M._review_buffer, "PR Review")
    end

    vim.bo[M._review_buffer].buftype = "nofile"
    vim.bo[M._review_buffer].bufhidden = "hide"
    vim.bo[M._review_buffer].swapfile = false
    -- Don't set filetype yet - it might trigger ftplugins that override keymaps
    -- vim.bo[M._review_buffer].filetype = "pr-review"

    setup_review_buffer_keymaps(M._review_buffer)
    debug_log("Review buffer keymaps set up for buffer " .. M._review_buffer)
  end

  -- Render content
  render_review_buffer()

  -- Re-apply keymaps after rendering (in case buffer was recreated)
  setup_review_buffer_keymaps(M._review_buffer)

  -- Set modifiable to false after everything is set up
  vim.bo[M._review_buffer].modifiable = false

  -- Open window if not already open
  if not M._review_window or not vim.api.nvim_win_is_valid(M._review_window) then
    local cfg = M.config.review_buffer
    local win_cmd

    if cfg.position == "left" then
      win_cmd = string.format("topleft vertical %d split", cfg.width)
    elseif cfg.position == "right" then
      win_cmd = string.format("botright vertical %d split", cfg.width)
    elseif cfg.position == "top" then
      win_cmd = string.format("topleft %d split", cfg.height)
    else -- bottom
      win_cmd = string.format("botright %d split", cfg.height)
    end

    vim.cmd(win_cmd)
    M._review_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M._review_window, M._review_buffer)
    vim.api.nvim_win_set_option(M._review_window, "number", false)
    vim.api.nvim_win_set_option(M._review_window, "relativenumber", false)
    vim.api.nvim_win_set_option(M._review_window, "signcolumn", "no")
    vim.api.nvim_win_set_option(M._review_window, "wrap", false)

    -- Fix window size (width for left/right, height for top/bottom)
    if cfg.position == "left" or cfg.position == "right" then
      vim.api.nvim_win_set_option(M._review_window, "winfixwidth", true)
    else
      vim.api.nvim_win_set_option(M._review_window, "winfixheight", true)
    end

    -- Return to previous window
    vim.cmd("wincmd p")
  end

  -- Call callback if provided
  if callback then
    callback()
  end
end

-- Refresh review buffer (call when files are marked as viewed)
function M.refresh_review_buffer()
  if M._review_buffer and vim.api.nvim_buf_is_valid(M._review_buffer) then
    -- Update viewed status in files list
    for _, file in ipairs(M._review_files) do
      file.viewed = M._viewed_files[file.path] or false
    end
    render_review_buffer()
  end
end

-- Toggle review buffer (open/close)
function M.toggle_review_buffer()
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Check if window is open
  if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
    -- Close it
    vim.api.nvim_win_close(M._review_window, true)
    M._review_window = nil
  else
    -- Open it
    M.open_review_buffer()
  end
end

-- Setup global navigation keymaps (work during review mode only)
local function setup_global_review_keymaps()
  -- File navigation keymaps (global, but only work in review mode)
  vim.keymap.set("n", M.config.next_file_key, function()
    if vim.g.pr_review_number then
      M.next_file()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.next_file_key, true, false, true), "n", false)
    end
  end, { desc = "Go to next file (PR review mode)" })

  vim.keymap.set("n", M.config.prev_file_key, function()
    if vim.g.pr_review_number then
      M.prev_file()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.prev_file_key, true, false, true), "n", false)
    end
  end, { desc = "Go to previous file (PR review mode)" })

  -- Toggle review buffer
  vim.keymap.set("n", M.config.review_buffer.toggle_key, function()
    if vim.g.pr_review_number then
      M.toggle_review_buffer()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.review_buffer.toggle_key, true, false, true), "n",
        false)
    end
  end, { desc = "Toggle review buffer (PR review mode)" })
end

update_changes_float = function()
  if not vim.g.pr_review_number then
    close_float_wins()
    return
  end

  -- Don't show floats if disabled in config
  if not M.config.show_floats then
    close_float_wins()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M._buffer_hunks[bufnr]

  if not hunks or #hunks == 0 then
    close_float_wins()
    return
  end

  -- Get file position from review files (use ordered list if available)
  local file_path = get_relative_path(bufnr)
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files
  local file_idx = 1
  local total_files = #file_list
  local file_status = "M" -- default

  for i, file in ipairs(file_list) do
    if file.path == file_path then
      file_idx = i
      file_status = file.status
      break
    end
  end

  -- Get cursor position for current hunk
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local current_idx = 0
  for i, hunk in ipairs(hunks) do
    if cursor_line >= hunk.start_line then
      current_idx = i
    end
  end
  if current_idx == 0 then
    current_idx = 1
  end

  local comments = M._buffer_comments[bufnr]
  local comment_count = comments and #comments or 0
  local stats = M._buffer_stats[bufnr]
  local is_viewed = M._viewed_files[file_path] or false

  -- FLOAT 1: General info (file x/total)
  local general_lines = {}
  if M.config.show_icons then
    table.insert(general_lines, string.format(" 📁 File %d/%d ", file_idx, total_files))
  else
    table.insert(general_lines, string.format(" File %d/%d ", file_idx, total_files))
  end

  -- FLOAT 2: Buffer info (viewed, hunks, stats, comments)
  local buffer_lines = {}
  if M.config.show_icons then
    local viewed_icon = is_viewed and "✓" or "○"
    table.insert(buffer_lines, string.format(" %s %s ", viewed_icon, is_viewed and "Viewed" or "Not viewed"))
  else
    table.insert(buffer_lines, string.format(" [%s] ", is_viewed and "Viewed" or "Not viewed"))
  end
  table.insert(buffer_lines, string.format(" %d/%d changes ", current_idx, #hunks))
  if stats then
    table.insert(buffer_lines, string.format(" +%d ~%d -%d ", stats.additions, stats.modifications, stats.deletions))
  end
  if comment_count > 0 then
    if M.config.show_icons then
      table.insert(buffer_lines, string.format(" 💬 %d comments ", comment_count))
    else
      table.insert(buffer_lines, string.format(" %d comments ", comment_count))
    end
  end

  -- FLOAT 3: Keymaps
  local keymap_lines = {}
  table.insert(keymap_lines, string.format(" %s: Next hunk ", M.config.next_hunk_key))
  table.insert(keymap_lines, string.format(" %s: Prev hunk ", M.config.prev_hunk_key))
  table.insert(keymap_lines, string.format(" %s: Next file ", M.config.next_file_key))
  table.insert(keymap_lines, string.format(" %s: Prev file ", M.config.prev_file_key))
  table.insert(keymap_lines, string.format(" %s: Mark viewed ", M.config.mark_as_viewed_key))
  table.insert(keymap_lines, string.format(" %s: Toggle split ", M.config.diff_view_toggle_key))
  table.insert(keymap_lines, string.format(" %s: Toggle floats ", M.config.toggle_floats_key))

  -- Helper to create/update float
  local function create_or_update_float(win_var, lines, row_offset, highlight)
    local max_width = 0
    for _, line in ipairs(lines) do
      if #line > max_width then
        max_width = #line
      end
    end

    local buf
    if win_var and vim.api.nvim_win_is_valid(win_var) then
      buf = vim.api.nvim_win_get_buf(win_var)
    else
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    if not win_var or not vim.api.nvim_win_is_valid(win_var) then
      local new_win = vim.api.nvim_open_win(buf, false, {
        relative = "win",
        anchor = "NE",
        width = max_width,
        height = #lines,
        row = row_offset,
        col = vim.api.nvim_win_get_width(0),
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 50,
      })
      vim.api.nvim_set_option_value("winhl", highlight, { win = new_win })
      return new_win
    else
      vim.api.nvim_win_set_config(win_var, {
        relative = "win",
        anchor = "NE",
        width = max_width,
        height = #lines,
        row = row_offset,
        col = vim.api.nvim_win_get_width(0),
      })
      return win_var
    end
  end

  -- Create the 3 floats stacked vertically
  -- Use red border for deleted files
  local border_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or
      "Normal:DiagnosticInfo,FloatBorder:DiagnosticInfo"
  M._float_win_general = create_or_update_float(M._float_win_general, general_lines, 0, border_hl)

  local general_height = #general_lines + 2 -- +2 for border
  local buffer_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or
      "Normal:DiagnosticHint,FloatBorder:DiagnosticHint"
  M._float_win_buffer = create_or_update_float(M._float_win_buffer, buffer_lines, general_height, buffer_hl)

  local buffer_height = #buffer_lines + 2
  local keymap_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or
      "Normal:DiagnosticWarn,FloatBorder:DiagnosticWarn"
  M._float_win_keymaps = create_or_update_float(M._float_win_keymaps, keymap_lines, general_height + buffer_height,
    keymap_hl)
end

function M.mark_file_as_viewed_and_next()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = get_relative_path(bufnr)

  -- Toggle viewed status
  if M._viewed_files[file_path] then
    -- If already viewed, unmark it
    M._viewed_files[file_path] = false
  else
    -- If not viewed, mark as viewed and go to next file
    M._viewed_files[file_path] = true
  end

  -- Save session
  save_session()

  -- Update the float to show new status
  update_changes_float()

  -- Update review buffer
  M.refresh_review_buffer()

  -- Only go to next file if we just marked it as viewed (not when unmarking)
  if M._viewed_files[file_path] then
    M.next_file()
  end
end

function M.next_hunk()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M._buffer_hunks[bufnr]

  if not hunks or #hunks == 0 then
    vim.notify("No hunks in this buffer", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Find the next hunk after the current cursor position
  for _, hunk in ipairs(hunks) do
    if hunk.start_line > current_line and hunk.start_line <= line_count then
      vim.api.nvim_win_set_cursor(0, { hunk.start_line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end

  -- If no hunk found after cursor, wrap to first hunk
  if hunks[1].start_line > 0 and hunks[1].start_line <= line_count then
    vim.api.nvim_win_set_cursor(0, { hunks[1].start_line, 0 })
    vim.cmd("normal! zz")
  end
end

function M.prev_hunk()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M._buffer_hunks[bufnr]

  if not hunks or #hunks == 0 then
    vim.notify("No hunks in this buffer", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Find the previous hunk before the current cursor position
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    if hunk.start_line < current_line and hunk.start_line > 0 and hunk.start_line <= line_count then
      vim.api.nvim_win_set_cursor(0, { hunk.start_line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end

  -- If no hunk found before cursor, wrap to last hunk
  if hunks[#hunks].start_line > 0 and hunks[#hunks].start_line <= line_count then
    vim.api.nvim_win_set_cursor(0, { hunks[#hunks].start_line, 0 })
    vim.cmd("normal! zz")
  end
end

function M.next_file()
  -- Prevent concurrent file navigation operations
  if M._opening_file then
    return
  end

  -- Use ordered list from ReviewBuffer
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files

  if not vim.g.pr_review_number or #file_list == 0 then
    return
  end

  local current_file = get_relative_path(vim.api.nvim_get_current_buf())
  local current_idx = nil

  for i, file in ipairs(file_list) do
    if file.path == current_file then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Open first file
    if file_list[1] then
      open_file_safe(file_list[1], nil)
    end
    return
  end

  if current_idx >= #file_list then
    vim.notify("Already at the last file", vim.log.levels.INFO)
    return
  end

  M._opening_file = true
  local next_file = file_list[current_idx + 1]

  -- If in split mode, restore unified before opening next file
  local was_split = M._diff_view_mode == "split"
  if was_split then
    restore_unified_view()
  end

  open_file_safe(next_file, nil)

  -- If was in split mode, recreate split for new file
  if was_split then
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(vim.api.nvim_get_current_buf()) then
        local bufnr = vim.api.nvim_get_current_buf()
        local file_path = get_relative_path(bufnr)
        if file_path then
          M._diff_view_mode = "unified" -- Reset to unified first
          M.toggle_diff_view()          -- Then toggle to split
        end
      end
      M._opening_file = false
    end, 50)
  else
    M._opening_file = false
  end
end

function M.prev_file()
  -- Prevent concurrent file navigation operations
  if M._opening_file then
    return
  end

  -- Use ordered list from ReviewBuffer
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files

  if not vim.g.pr_review_number or #file_list == 0 then
    return
  end

  local current_file = get_relative_path(vim.api.nvim_get_current_buf())
  local current_idx = nil

  for i, file in ipairs(file_list) do
    if file.path == current_file then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Open first file
    if file_list[1] then
      open_file_safe(file_list[1], nil)
    end
    return
  end

  if current_idx <= 1 then
    vim.notify("Already at the first file", vim.log.levels.INFO)
    return
  end

  M._opening_file = true
  local prev_file = file_list[current_idx - 1]

  -- If in split mode, restore unified before opening prev file
  local was_split = M._diff_view_mode == "split"
  if was_split then
    restore_unified_view()
  end

  open_file_safe(prev_file, nil)

  -- If was in split mode, recreate split for new file
  if was_split then
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(vim.api.nvim_get_current_buf()) then
        local bufnr = vim.api.nvim_get_current_buf()
        local file_path = get_relative_path(bufnr)
        if file_path then
          M._diff_view_mode = "unified" -- Reset to unified first
          M.toggle_diff_view()          -- Then toggle to split
        end
      end
      M._opening_file = false
    end, 50)
  else
    M._opening_file = false
  end
end

-- Add navigation hints as virtual text for current hunk
local hunk_hints_ns_id = vim.api.nvim_create_namespace("pr_review_hunk_hints")

local function update_hunk_navigation_hints()
  local bufnr = vim.api.nvim_get_current_buf()

  if not vim.g.pr_review_number then
    return
  end

  local hunks = M._buffer_hunks[bufnr]
  if not hunks or #hunks == 0 then
    return
  end

  -- Clear previous hints
  vim.api.nvim_buf_clear_namespace(bufnr, hunk_hints_ns_id, 0, -1)

  -- Get cursor position to find current hunk
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local current_hunk_idx = nil

  for i, hunk in ipairs(hunks) do
    if cursor_line >= hunk.start_line and cursor_line <= hunk.end_line then
      current_hunk_idx = i
      break
    end
  end

  -- If cursor is before first hunk, use first hunk
  if not current_hunk_idx and cursor_line < hunks[1].start_line then
    current_hunk_idx = 1
  end

  -- If cursor is after last hunk, use last hunk
  if not current_hunk_idx and cursor_line > hunks[#hunks].end_line then
    current_hunk_idx = #hunks
  end

  if not current_hunk_idx then
    return
  end

  -- Show hint only if cursor is inside a hunk and there are multiple hunks
  local hint_text = ""

  -- Check if cursor is actually inside the current hunk
  local cursor_in_hunk = cursor_line >= hunks[current_hunk_idx].start_line and
                         cursor_line <= hunks[current_hunk_idx].end_line

  if cursor_in_hunk and #hunks > 1 then
    hint_text = string.format("  (%d/%d)", current_hunk_idx, #hunks)
  end

  if hint_text ~= "" then
    local line_idx = cursor_line - 1
    if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
      local line_bg = nil

      -- In split mode, use vim's diff highlight groups
      if M._diff_view_mode == "split" then
        -- Get the diff highlight from vim's native diff mode
        local diff_hl = vim.fn.diff_hlID(cursor_line, 1)
        if diff_hl > 0 then
          local hl_name = vim.fn.synIDattr(diff_hl, "name")
          if hl_name and hl_name ~= "" then
            local hl = vim.api.nvim_get_hl(0, { name = hl_name, link = false })
            line_bg = hl.bg
          end
        end
      else
        -- In unified mode, check extmarks for line highlight
        local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, diff_ns_id, { line_idx, 0 }, { line_idx, -1 }, { details = true })

        for _, mark in ipairs(extmarks) do
          local details = mark[4]
          if details and details.line_hl_group then
            -- Get the background from the line highlight group
            local hl = vim.api.nvim_get_hl(0, { name = details.line_hl_group, link = false })
            if hl.bg then
              line_bg = hl.bg
            end
            break
          end
        end
      end

      -- Create custom highlight group for hints
      -- Use a bright color (from DiagnosticWarn or Number) with bold
      local warn_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
      local hint_fg = warn_hl.fg or vim.api.nvim_get_hl(0, { name = "Number", link = false }).fg

      vim.api.nvim_set_hl(0, "PRHint", {
        fg = hint_fg,
        bg = line_bg, -- Use the line's background (or nil for transparent)
        bold = true,
      })

      vim.api.nvim_buf_set_extmark(bufnr, hunk_hints_ns_id, line_idx, 0, {
        virt_text = { { hint_text, "PRHint" } },
        virt_text_pos = "eol",
      })
    end
  end
end

local function load_changes_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.g.pr_review_number then
    return
  end

  local file_path = get_relative_path(bufnr)

  -- Find status from review files
  local status = "M" -- default to modified
  for _, file in ipairs(M._review_files) do
    if file.path == file_path then
      status = file.status
      break
    end
  end

  get_changed_lines_for_file(file_path, status, function(lines, hunks)
    if lines and #lines > 0 then
      M._buffer_changes[bufnr] = lines
      M._buffer_hunks[bufnr] = hunks

      vim.api.nvim_buf_clear_namespace(bufnr, changes_ns_id, 0, -1)

      -- Only show visual change indicators (│) when NOT in split mode
      -- In split mode, the diff view handles all visual highlighting
      if M._diff_view_mode ~= "split" then
        -- Don't show change indicators for completely new files (status "A" or "N")
        -- Since everything is new, showing all lines as changed is not helpful
        if status ~= "A" and status ~= "N" then
          for _, line in ipairs(lines) do
            local line_idx = line - 1
            if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
              vim.api.nvim_buf_set_extmark(bufnr, changes_ns_id, line_idx, 0, {
                sign_text = "│",
                sign_hl_group = "DiffAdd",
              })
            end
          end
        end
      end

      -- Setup buffer-local keymaps for files with changes (only once per buffer)
      if not M._buffer_keymaps_saved[bufnr] then
        vim.keymap.set("n", M.config.next_hunk_key, M.next_hunk, { buffer = bufnr, desc = "Jump to next hunk" })
        vim.keymap.set("n", M.config.prev_hunk_key, M.prev_hunk, { buffer = bufnr, desc = "Jump to previous hunk" })
        vim.keymap.set("n", M.config.mark_as_viewed_key, M.mark_file_as_viewed_and_next,
          { buffer = bufnr, desc = "Mark as viewed and next" })
        vim.keymap.set("n", M.config.diff_view_toggle_key, M.toggle_diff_view,
          { buffer = bufnr, desc = "Toggle unified/split diff view" })
        vim.keymap.set("n", M.config.toggle_floats_key, M.toggle_floats,
          { buffer = bufnr, desc = "Toggle floating windows" })
        M._buffer_keymaps_saved[bufnr] = true
      end

      -- Add navigation hints (will be updated on cursor move)
      if bufnr == vim.api.nvim_get_current_buf() then
        update_hunk_navigation_hints()
        update_changes_float()
      end
    else
      M._buffer_changes[bufnr] = nil
      M._buffer_hunks[bufnr] = nil
      close_float_wins()
    end
  end)
end

local function count_comments_at_line(comments, line)
  local count = 0
  for _, comment in ipairs(comments) do
    if comment.line == line then
      count = count + 1
    end
  end
  return count
end

local function display_comments(bufnr, comments)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines_with_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line and type(comment.line) == "number" and comment.line > 0 then
      lines_with_comments[comment.line] = true
    end
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for line, _ in pairs(lines_with_comments) do
    local line_idx = line - 1
    if line_idx < line_count then
      local count = count_comments_at_line(comments, line)

      -- Check if any comment on this line is pending
      local has_pending = false
      for _, c in ipairs(comments) do
        if c.line == line and c.is_pending then
          has_pending = true
          break
        end
      end

      local text
      if M.config.show_icons then
        if has_pending then
          text = count > 1 and string.format(" ⏳ %d comments (pending)", count) or " ⏳ 1 comment (pending)"
        else
          text = count > 1 and string.format(" 💬 %d comments", count) or " 💬 1 comment"
        end
      else
        if has_pending then
          text = count > 1 and string.format(" [%d comments (pending)]", count) or " [1 comment (pending)]"
        else
          text = count > 1 and string.format(" [%d comments]", count) or " [1 comment]"
        end
      end

      -- Get background color from the current line's highlight
      local line_bg = nil

      -- In split mode, use vim's diff highlight groups
      if M._diff_view_mode == "split" then
        -- Get the diff highlight from vim's native diff mode
        local diff_hl = vim.fn.diff_hlID(line, 1)
        if diff_hl > 0 then
          local hl_name = vim.fn.synIDattr(diff_hl, "name")
          if hl_name and hl_name ~= "" then
            local hl = vim.api.nvim_get_hl(0, { name = hl_name, link = false })
            line_bg = hl.bg
          end
        end
      else
        -- In unified mode, check extmarks for line highlight
        local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, diff_ns_id, { line_idx, 0 }, { line_idx, -1 }, { details = true })

        for _, mark in ipairs(extmarks) do
          local details = mark[4]
          if details and details.line_hl_group then
            -- Get the background from the line highlight group
            local hl = vim.api.nvim_get_hl(0, { name = details.line_hl_group, link = false })
            if hl.bg then
              line_bg = hl.bg
            end
            break
          end
        end
      end

      -- Create custom highlight group for comment indicator
      local base_hl_name = has_pending and "DiagnosticWarn" or "DiagnosticInfo"
      local custom_hl_name = has_pending and "PRCommentPending" or "PRCommentInfo"
      local base_hl = vim.api.nvim_get_hl(0, { name = base_hl_name, link = false })

      -- Use line background, or fallback to Normal background if no diff
      local comment_bg = line_bg
      if not comment_bg then
        local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
        comment_bg = normal_hl.bg
      end

      vim.api.nvim_set_hl(0, custom_hl_name, {
        fg = base_hl.fg,
        bg = comment_bg,
      })

      vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
        virt_text = { { text, custom_hl_name } },
        virt_text_pos = "eol",
      })
    end
  end
end

function M.show_comments_at_cursor()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    return
  end

  local lines = {}
  for i, comment in ipairs(line_comments) do
    if i > 1 then
      table.insert(lines, string.rep("─", 40))
    end
    if M.config.show_icons then
      table.insert(lines, string.format("👤 %s", comment.user))
    else
      table.insert(lines, string.format("@%s", comment.user))
    end
    table.insert(lines, "")
    for body_line in comment.body:gmatch("[^\r\n]+") do
      table.insert(lines, body_line)
    end
  end

  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focus_id = "pr_review_comment",
    max_width = 80,
    max_height = 20,
  })
end

function M.load_comments_for_buffer(bufnr, force_reload)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M.config.show_comments then
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    return
  end

  if force_reload then
    github.clear_cache()
  end

  local file_path = get_relative_path(bufnr)

  -- Get regular comments
  github.get_comments_for_file(pr_number, file_path, function(comments, err)
    if err then
      return
    end

    -- Initialize comments if nil
    if not comments then
      comments = {}
    end

    -- Also get pending comments and merge them
    github.get_pending_review_comments(pr_number, function(pending_comments, pending_err)
      debug_log(string.format("Debug load: Got %d pending comments, err=%s", #(pending_comments or {}),
        pending_err or "nil"))

      if not pending_err and pending_comments then
        -- Filter pending comments for this file and mark them as pending
        local added_count = 0
        for _, pc in ipairs(pending_comments) do
          debug_log(string.format("Debug load: Pending comment path=%s, file_path=%s, line=%s", pc.path or "nil",
            file_path, tostring(pc.line)))
          if pc.path == file_path then
            pc.is_pending = true
            pc.body = pc.body .. " (pending)"
            table.insert(comments, pc)
            added_count = added_count + 1
          end
        end
        debug_log(string.format("Debug load: Added %d pending comments to buffer", added_count))
      end

      -- Also merge local pending comments
      local local_pending = get_local_pending_comments_for_file(pr_number, file_path)
      debug_log(string.format("Debug load: Got %d local pending comments for file", #local_pending))
      for _, lpc in ipairs(local_pending) do
        -- Local pending comments already have is_pending and is_local set
        table.insert(comments, lpc)
      end

      if comments and #comments > 0 then
        M._buffer_comments[bufnr] = comments
        -- Use defer_fn with a delay to ensure diff highlights are applied first
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            display_comments(bufnr, comments)
          end
        end, 50)
      else
        M._buffer_comments[bufnr] = nil
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
          end
        end)
      end
    end)
  end)
end

-- Draft management functions
local function get_draft_key(pr_number, file_path, line, action, comment_id)
  -- Create unique key for draft: pr_number:file:line:action[:comment_id]
  local key = string.format("%d:%s:%d:%s", pr_number, file_path or "", line or 0, action)
  if comment_id then
    key = key .. ":" .. tostring(comment_id)
  end
  return key
end

local function save_draft(pr_number, file_path, line, action, comment_id, text)
  if not text or text == "" then
    return
  end
  local key = get_draft_key(pr_number, file_path, line, action, comment_id)
  if not M._drafts[pr_number] then
    M._drafts[pr_number] = {}
  end
  M._drafts[pr_number][key] = {
    text = text,
    timestamp = os.time(),
    file_path = file_path,
    line = line,
    action = action,
    comment_id = comment_id,
  }
  save_session()
end

local function get_draft(pr_number, file_path, line, action, comment_id)
  local key = get_draft_key(pr_number, file_path, line, action, comment_id)
  if M._drafts[pr_number] and M._drafts[pr_number][key] then
    return M._drafts[pr_number][key].text
  end
  return nil
end

local function clear_draft(pr_number, file_path, line, action, comment_id)
  local key = get_draft_key(pr_number, file_path, line, action, comment_id)
  if M._drafts[pr_number] then
    M._drafts[pr_number][key] = nil
  end
  save_session()
end

local function input_multiline(prompt, callback, initial_text, draft_info)
  -- draft_info: { pr_number, file_path, line, action, comment_id }
  local pr_number = vim.g.pr_review_number

  -- Check if there's a saved draft
  if draft_info and pr_number then
    local draft_text = get_draft(
      pr_number,
      draft_info.file_path,
      draft_info.line,
      draft_info.action,
      draft_info.comment_id
    )
    if draft_text and (not initial_text or initial_text == "") then
      initial_text = draft_text
      prompt = prompt .. " [DRAFT RESTORED]"
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Set initial text if provided
  local has_initial_text = false
  if initial_text then
    local lines = vim.split(initial_text, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- Move cursor to the end
    local last_line = #lines
    vim.api.nvim_win_set_cursor(win, { last_line, 0 })
    has_initial_text = true
  end

  -- Save draft function
  local function save_current_draft()
    if draft_info and pr_number then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      if text and text ~= "" then
        save_draft(
          pr_number,
          draft_info.file_path,
          draft_info.line,
          draft_info.action,
          draft_info.comment_id,
          text
        )
      end
    end
  end

  vim.keymap.set("n", "<Esc>", function()
    save_current_draft()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")

    -- Clear draft on successful submit
    if draft_info and pr_number and text ~= "" then
      clear_draft(
        pr_number,
        draft_info.file_path,
        draft_info.line,
        draft_info.action,
        draft_info.comment_id
      )
    end

    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    if text ~= "" then
      callback(text)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Auto-save draft when window is closed unexpectedly
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- Only save if buffer still exists and window was closed
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_win_is_valid(win) then
          save_current_draft()
        end
      end, 10)
    end,
  })

  -- Enter insert mode automatically
  if has_initial_text then
    vim.cmd("startinsert!")  -- Append at end of line
  else
    vim.cmd("startinsert")
  end
end

-- Show pending comments in a preview buffer
local function show_pending_comments_preview(pending_comments, callback)
  if not pending_comments or #pending_comments == 0 then
    callback(true) -- No comments, proceed
    return
  end

  -- Build content first to calculate height
  local lines = {}
  table.insert(lines, "These pending comments will be submitted with your review:")
  table.insert(lines, "")

  for i, comment in ipairs(pending_comments) do
    table.insert(lines, string.format("━━━ Comment %d (PENDING) ━━━", i))
    table.insert(lines, string.format("📄 %s:%d", comment.path, comment.line))
    table.insert(lines, "")

    -- Add comment body with wrapping
    for line in comment.body:gmatch("[^\r\n]+") do
      table.insert(lines, "  " .. line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  table.insert(lines, "")
  table.insert(lines, "Press 'y' to proceed, 'n' to cancel, 'q' to cancel")

  -- Calculate window dimensions
  local width = math.floor(vim.o.columns * 0.8)
  local content_height = #lines
  local max_height = math.min(math.floor(vim.o.lines * 0.7), 25) -- Max 70% of screen or 25 lines
  local height = math.min(content_height, max_height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format(" %d Pending Comment%s - y: proceed | n/q: cancel ", #pending_comments,
      #pending_comments > 1 and "s" or ""),
    title_pos = "center",
  })

  -- Position cursor at the bottom to show the prompt
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })

  -- Set up keymaps
  local function close_and_respond(proceed)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    callback(proceed)
  end

  vim.keymap.set("n", "y", function() close_and_respond(true) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "n", function() close_and_respond(false) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", function() close_and_respond(false) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function() close_and_respond(false) end, { buffer = buf, nowait = true })
end

function M.approve_pr()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Get local pending comments
  local pending_comments = get_local_pending_comments_for_pr(pr_number)

  -- Show preview if there are pending comments
  show_pending_comments_preview(pending_comments, function(proceed)
    if not proceed then
      vim.notify("Approval cancelled", vim.log.levels.INFO)
      return
    end

    input_multiline("Approval comment (optional)", function(body)
      vim.notify("Approving PR #" .. pr_number .. "...", vim.log.levels.INFO)

      -- If there are pending comments, submit review with comments using API
      if pending_comments and #pending_comments > 0 then
        github.submit_review_with_comments(pr_number, "APPROVE", body, pending_comments, function(ok, err)
          if ok then
            -- Clear local pending comments after successful submission
            M._local_pending_comments[pr_number] = nil
            save_session()

            -- Reload all open buffers to remove PENDING markers
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(buf) and M._buffer_comments[buf] then
                M.load_comments_for_buffer(buf, true)
              end
            end

            vim.notify(string.format("✅ PR #%d approved with %d comments!", pr_number, #pending_comments),
              vim.log.levels.INFO)
          else
            vim.notify("❌ Failed to approve: " .. (err or "unknown"), vim.log.levels.ERROR)
          end
        end)
      else
        -- No pending comments, use simple approve
        github.approve_pr(pr_number, body, function(ok, err)
          if ok then
            vim.notify("✅ PR #" .. pr_number .. " approved!", vim.log.levels.INFO)
          else
            vim.notify("❌ Failed to approve: " .. (err or "unknown"), vim.log.levels.ERROR)
          end
        end)
      end
    end, nil, {
      pr_number = pr_number,
      file_path = nil,
      line = nil,
      action = "approve_pr",
    })
  end)
end

function M.request_changes()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Get local pending comments
  local pending_comments = get_local_pending_comments_for_pr(pr_number)

  -- Show preview if there are pending comments
  show_pending_comments_preview(pending_comments, function(proceed)
    if not proceed then
      vim.notify("Request changes cancelled", vim.log.levels.INFO)
      return
    end

    input_multiline("Reason for requesting changes (required by GitHub)", function(body)
      if not body or body:match("^%s*$") then
        vim.notify("❌ Reason is required when requesting changes (GitHub requirement)", vim.log.levels.ERROR)
        return
      end
      vim.notify("Requesting changes on PR #" .. pr_number .. "...", vim.log.levels.INFO)

      -- If there are pending comments, submit review with comments using API
      if pending_comments and #pending_comments > 0 then
        github.submit_review_with_comments(pr_number, "REQUEST_CHANGES", body, pending_comments, function(ok, err)
          if ok then
            -- Clear local pending comments after successful submission
            M._local_pending_comments[pr_number] = nil
            save_session()

            -- Reload all open buffers to remove PENDING markers
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(buf) and M._buffer_comments[buf] then
                M.load_comments_for_buffer(buf, true)
              end
            end

            vim.notify(string.format("✅ Requested changes on PR #%d with %d comments", pr_number, #pending_comments),
              vim.log.levels.INFO)
          else
            vim.notify("❌ Failed to request changes: " .. (err or "unknown"), vim.log.levels.ERROR)
          end
        end)
      else
        -- No pending comments, use simple request changes
        github.request_changes(pr_number, body, function(ok, err)
          if ok then
            vim.notify("✅ Requested changes on PR #" .. pr_number, vim.log.levels.INFO)
          else
            vim.notify("❌ Failed to request changes: " .. (err or "unknown"), vim.log.levels.ERROR)
          end
        end)
      end
    end, nil, {
      pr_number = pr_number,
      file_path = nil,
      line = nil,
      action = "request_changes",
    })
  end)
end

function M.submit_pending_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Get local pending comments
  local pending_comments = get_local_pending_comments_for_pr(pr_number)

  if not pending_comments or #pending_comments == 0 then
    vim.notify("No pending comments to submit", vim.log.levels.INFO)
    return
  end

  -- Show preview of pending comments
  show_pending_comments_preview(pending_comments, function(proceed)
    if not proceed then
      vim.notify("Submission cancelled", vim.log.levels.INFO)
      return
    end

    input_multiline("Optional comment for review (can be empty)", function(body)
      vim.notify(string.format("Submitting %d pending comment(s)...", #pending_comments), vim.log.levels.INFO)

      -- Submit review with COMMENT event (not APPROVE or REQUEST_CHANGES)
      github.submit_review_with_comments(pr_number, "COMMENT", body or "", pending_comments, function(ok, err)
        if ok then
          -- Clear local pending comments after successful submission
          M._local_pending_comments[pr_number] = nil
          save_session()

          -- Reload all open buffers to remove PENDING markers
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) and M._buffer_comments[buf] then
              M.load_comments_for_buffer(buf, true)
            end
          end

          vim.notify(string.format("✅ Submitted %d comment(s) successfully!", #pending_comments),
            vim.log.levels.INFO)
        else
          vim.notify("❌ Failed to submit comments: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end)
    end, nil, {
      pr_number = pr_number,
      file_path = nil,
      line = nil,
      action = "submit_pending",
    })
  end)
end

function M.add_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  input_multiline("PR Comment", function(body)
    if not body then
      return
    end
    vim.notify("Adding comment...", vim.log.levels.INFO)
    github.add_pr_comment(pr_number, body, function(ok, err)
      if ok then
        vim.notify("✅ Comment added to PR #" .. pr_number, vim.log.levels.INFO)
      else
        vim.notify("❌ Failed to add comment: " .. (err or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end, nil, {
    pr_number = pr_number,
    file_path = nil,
    line = nil,
    action = "add_pr_comment",
  })
end

-- Build a comment thread by following in_reply_to_id
local function build_comment_thread(target_comment, all_comments)
  local thread = {}
  local comment_map = {}

  -- Build a map of comment_id -> comment
  for _, c in ipairs(all_comments) do
    comment_map[c.id] = c
  end

  -- Find the root of the thread
  local root = target_comment
  while root.in_reply_to_id and comment_map[root.in_reply_to_id] do
    root = comment_map[root.in_reply_to_id]
  end

  -- Build the thread from root to current
  local function collect_thread(comment, depth)
    depth = depth or 0
    table.insert(thread, { comment = comment, depth = depth })

    -- Find all replies to this comment
    for _, c in ipairs(all_comments) do
      if c.in_reply_to_id == comment.id then
        collect_thread(c, depth + 1)
      end
    end
  end

  collect_thread(root, 0)
  return thread
end

-- Wrap text to fit within a given width
local function wrap_text(text, max_width, indent)
  indent = indent or ""
  local indent_len = #indent
  local available_width = max_width - indent_len

  if available_width <= 0 then
    available_width = 40 -- fallback minimum
  end

  local wrapped_lines = {}

  -- Split by existing line breaks first
  for paragraph in text:gmatch("[^\r\n]+") do
    local current_line = ""

    -- Split paragraph into words
    for word in paragraph:gmatch("%S+") do
      local test_line = current_line == "" and word or (current_line .. " " .. word)

      if #test_line <= available_width then
        current_line = test_line
      else
        -- Current line is full, save it and start new line
        if current_line ~= "" then
          table.insert(wrapped_lines, indent .. current_line)
        end
        current_line = word
      end
    end

    -- Add remaining text
    if current_line ~= "" then
      table.insert(wrapped_lines, indent .. current_line)
    end
  end

  return wrapped_lines
end

-- Input reply with conversation context
-- Input new comment with conversation context (like reply but for new comments)
local function input_comment_with_context(target_comment, all_comments, prompt_title, callback, draft_info)
  -- draft_info: { pr_number, file_path, line, action, comment_id }
  local pr_number = vim.g.pr_review_number

  -- Check if there's a saved draft
  local draft_text = nil
  if draft_info and pr_number then
    draft_text = get_draft(
      pr_number,
      draft_info.file_path,
      draft_info.line,
      draft_info.action,
      draft_info.comment_id
    )
    if draft_text then
      prompt_title = prompt_title .. " [DRAFT RESTORED]"
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt_title .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Build the thread
  local thread = build_comment_thread(target_comment, all_comments)

  -- Format the thread
  local lines = {}
  table.insert(lines, "--- Conversation Thread ---")
  table.insert(lines, "")

  for _, item in ipairs(thread) do
    local indent = string.rep("  ", item.depth)
    local prefix = item.depth > 0 and "↳ " or ""

    -- Add author and date
    local date = item.comment.created_at or ""
    if date ~= "" then
      date = " (" .. date:sub(1, 10) .. ")"
    end

    -- Add pending indicator if it's a local pending comment
    local pending_mark = (item.comment.is_pending and item.comment.is_local) and " [PENDING]" or ""

    table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. pending_mark .. ":")

    -- Add comment body with word wrap and indent
    local wrapped = wrap_text(item.comment.body, width - 4, indent)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(lines, wrapped_line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "--- Answer here: ---")
  table.insert(lines, "")

  -- Add draft text if exists
  if draft_text then
    for draft_line in draft_text:gmatch("[^\r\n]+") do
      table.insert(lines, draft_line)
    end
  end

  local separator_line = #lines - (draft_text and vim.tbl_count(vim.split(draft_text, "\n")) or 1)

  -- Set the content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Make everything above separator read-only by setting it as not modifiable initially
  vim.bo[buf].modifiable = true

  -- Create namespace for highlighting
  local ns_id = vim.api.nvim_create_namespace("comment_context")

  -- Highlight the separator
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", separator_line - 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)

  -- Save draft function
  local function save_current_draft()
    if draft_info and pr_number then
      local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Extract only the lines after the separator
      local comment_lines = {}
      local found_separator = false
      for i, line in ipairs(all_lines) do
        if line:match("^%-%-%-+ Answer here:") then
          found_separator = true
        elseif found_separator and line ~= "" then
          table.insert(comment_lines, line)
        end
      end

      local text = table.concat(comment_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if text and text ~= "" then
        save_draft(
          pr_number,
          draft_info.file_path,
          draft_info.line,
          draft_info.action,
          draft_info.comment_id,
          text
        )
      end
    end
  end

  vim.keymap.set("n", "<Esc>", function()
    save_current_draft()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Extract only the lines after the separator
    local comment_lines = {}
    local found_separator = false
    for i, line in ipairs(all_lines) do
      if line:match("^%-%-%-+ Answer here:") then
        found_separator = true
      elseif found_separator and line ~= "" then
        table.insert(comment_lines, line)
      end
    end

    local text = table.concat(comment_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

    -- Clear draft on successful submit
    if draft_info and pr_number and text ~= "" then
      clear_draft(
        pr_number,
        draft_info.file_path,
        draft_info.line,
        draft_info.action,
        draft_info.comment_id
      )
    end

    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")

    if text ~= "" then
      callback(text)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Auto-save draft when window is closed unexpectedly
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- Only save if buffer still exists and window was closed
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_win_is_valid(win) then
          save_current_draft()
        end
      end, 10)
    end,
  })

  -- Position cursor at the answer section
  if draft_text then
    -- If draft exists, position cursor at the end of the text
    local last_line = #lines
    vim.api.nvim_win_set_cursor(win, { last_line, 0 })
  else
    -- No draft, position at the start of answer section
    vim.api.nvim_win_set_cursor(win, { separator_line + 1, 0 })
  end

  -- Enter insert mode automatically
  if draft_text then
    vim.cmd("startinsert!")  -- Append at end of line
  else
    vim.cmd("startinsert")
  end
end

-- Show thread before adding/editing comment (deprecated - use input_comment_with_context instead)
local function show_reply_thread(target_comment, all_comments, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Conversation Thread (press Enter to continue, Esc to cancel) ",
    title_pos = "center",
  })

  -- Build the thread
  local thread = build_comment_thread(target_comment, all_comments)

  -- Format the thread
  local lines = {}
  table.insert(lines, "--- Conversation Thread ---")
  table.insert(lines, "")

  for _, item in ipairs(thread) do
    local indent = string.rep("  ", item.depth)
    local prefix = item.depth > 0 and "↳ " or ""

    -- Add author and date
    local date = item.comment.created_at or ""
    if date ~= "" then
      date = " (" .. date:sub(1, 10) .. ")"
    end

    -- Add pending indicator if it's a local pending comment
    local pending_mark = (item.comment.is_pending and item.comment.is_local) and " [PENDING]" or ""

    table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. pending_mark .. ":")

    -- Add comment body with word wrap and indent
    local wrapped = wrap_text(item.comment.body, width - 4, indent)
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(lines, wrapped_line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "")
  table.insert(lines, "Press Enter to continue or Esc to cancel")

  -- Set the content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Set buffer options AFTER setting content
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  -- Create namespace for highlighting
  local ns_id = vim.api.nvim_create_namespace("thread_preview")
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)

  local function close_and_continue()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if callback then
      callback()
    end
  end

  local function close_and_cancel()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  vim.keymap.set("n", "<CR>", close_and_continue, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_and_cancel, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", close_and_cancel, { buffer = buf, nowait = true })
end

local function input_reply_with_context(target_comment, all_comments, callback, draft_info)
  -- draft_info: { pr_number, file_path, line, action, comment_id }
  local pr_number = vim.g.pr_review_number
  local prompt_title = "Reply to " .. target_comment.user

  -- Check if there's a saved draft
  local draft_text = nil
  if draft_info and pr_number then
    draft_text = get_draft(
      pr_number,
      draft_info.file_path,
      draft_info.line,
      draft_info.action,
      draft_info.comment_id
    )
    if draft_text then
      prompt_title = prompt_title .. " [DRAFT RESTORED]"
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt_title .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Build the thread
  local thread = build_comment_thread(target_comment, all_comments)

  -- Format the thread
  local lines = {}
  table.insert(lines, "--- Conversation Thread ---")
  table.insert(lines, "")

  for _, item in ipairs(thread) do
    local indent = string.rep("  ", item.depth)
    local prefix = item.depth > 0 and "↳ " or ""

    -- Add author and date
    local date = item.comment.created_at or ""
    if date ~= "" then
      date = " (" .. date:sub(1, 10) .. ")"
    end
    table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. ":")

    -- Add comment body with word wrap and indent
    local wrapped = wrap_text(item.comment.body, width - 4, indent) -- -4 for border
    for _, wrapped_line in ipairs(wrapped) do
      table.insert(lines, wrapped_line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, "--- Answer here: ---")
  table.insert(lines, "")

  -- Add draft text if exists
  if draft_text then
    for draft_line in draft_text:gmatch("[^\r\n]+") do
      table.insert(lines, draft_line)
    end
  end

  local separator_line = #lines - (draft_text and vim.tbl_count(vim.split(draft_text, "\n")) or 1)

  -- Set the content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Make everything above separator read-only by setting it as not modifiable initially
  vim.bo[buf].modifiable = true

  -- Create namespace for highlighting
  local ns_id = vim.api.nvim_create_namespace("reply_context")

  -- Highlight the separator
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", separator_line - 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)

  -- Save draft function
  local function save_current_draft()
    if draft_info and pr_number then
      local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Extract only the lines after the separator
      local reply_lines = {}
      local found_separator = false
      for i, line in ipairs(all_lines) do
        if line:match("^%-%-%-+ Answer here:") then
          found_separator = true
        elseif found_separator and line ~= "" then
          table.insert(reply_lines, line)
        end
      end

      local text = table.concat(reply_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if text and text ~= "" then
        save_draft(
          pr_number,
          draft_info.file_path,
          draft_info.line,
          draft_info.action,
          draft_info.comment_id,
          text
        )
      end
    end
  end

  vim.keymap.set("n", "<Esc>", function()
    save_current_draft()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Extract only the lines after the separator
    local reply_lines = {}
    local found_separator = false
    for i, line in ipairs(all_lines) do
      if line:match("^%-%-%-+ Answer here:") then
        found_separator = true
      elseif found_separator and line ~= "" then
        table.insert(reply_lines, line)
      end
    end

    local text = table.concat(reply_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

    -- Clear draft on successful submit
    if draft_info and pr_number and text ~= "" then
      clear_draft(
        pr_number,
        draft_info.file_path,
        draft_info.line,
        draft_info.action,
        draft_info.comment_id
      )
    end

    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")

    if text ~= "" then
      callback(text)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Auto-save draft when window is closed unexpectedly
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.defer_fn(function()
        -- Only save if buffer still exists and window was closed
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_win_is_valid(win) then
          save_current_draft()
        end
      end, 10)
    end,
  })

  -- Position cursor at the answer section
  if draft_text then
    -- If draft exists, position cursor at the end of the text
    local last_line = #lines
    vim.api.nvim_win_set_cursor(win, { last_line, 0 })
  else
    -- No draft, position at the start of answer section
    vim.api.nvim_win_set_cursor(win, { separator_line + 1, 0 })
  end

  -- Enter insert mode automatically
  if draft_text then
    vim.cmd("startinsert!")  -- Append at end of line
  else
    vim.cmd("startinsert")
  end
end

function M.add_review_comment_with_selection()
  if not M._visual_selection then
    vim.notify("No visual selection captured", vim.log.levels.WARN)
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = M._visual_selection.start_line
  local end_line = M._visual_selection.end_line
  local file_path = get_relative_path(bufnr)
  local selected_text = M._visual_selection.text

  -- Format as GitHub suggested change
  -- https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request#adding-line-comments-to-a-pull-request
  local suggestion_text = "```suggestion\n" .. selected_text .. "\n```\n\n"

  -- Clear the selection after use
  local temp_selection = M._visual_selection
  M._visual_selection = nil

  -- Prompt for comment
  input_multiline(
    "Suggested change (edit the code above, line " .. temp_selection.start_line .. "-" .. temp_selection.end_line .. ")",
    function(body)
      if not body then
        return
      end

      vim.notify("Adding code suggestion...", vim.log.levels.INFO)
      github.add_review_comment(pr_number, file_path, end_line, body, function(ok, err)
        if ok then
          vim.notify("✅ Code suggestion added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to add suggestion: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end, start_line)
    end, suggestion_text, {
      pr_number = pr_number,
      file_path = file_path,
      line = end_line,
      action = "add_review_suggestion",
    })
end

function M.add_pending_comment_with_selection()
  if not M._visual_selection then
    vim.notify("No visual selection captured", vim.log.levels.WARN)
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = M._visual_selection.start_line
  local end_line = M._visual_selection.end_line
  local file_path = get_relative_path(bufnr)
  local selected_text = M._visual_selection.text

  -- Format as GitHub suggested change
  local suggestion_text = "```suggestion\n" .. selected_text .. "\n```\n\n"

  -- Clear the selection after use
  local temp_selection = M._visual_selection
  M._visual_selection = nil

  -- Prompt for comment
  input_multiline(
    "Pending suggested change (edit the code above, line " ..
    temp_selection.start_line .. "-" .. temp_selection.end_line .. ")", function(body)
      if not body then
        return
      end

      -- Get current user
      github.get_current_user(function(user, err)
        local username = user or "me"

        -- Store the range info in the comment body for later use
        local comment_with_range = body .. "\n<!-- PR_RANGE:" .. start_line .. "-" .. end_line .. " -->"

        -- Add comment to local storage
        add_local_pending_comment(pr_number, file_path, end_line, comment_with_range, username, start_line)

        -- Save session to persist pending comments
        save_session()

        vim.notify("✅ Pending suggestion added locally (will be posted with approval/rejection)", vim.log.levels.INFO)

        -- Reload comments to show the new pending comment
        M.load_comments_for_buffer(bufnr, false)
      end)
    end, suggestion_text, {
      pr_number = pr_number,
      file_path = file_path,
      line = end_line,
      action = "add_pending_suggestion",
    })
end

function M.add_review_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file_path = get_relative_path(bufnr)

  -- Check if there are existing comments on this line
  local comments = M._buffer_comments[bufnr] or {}
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  -- Show thread if there are existing comments
  if #line_comments > 0 then
    input_comment_with_context(line_comments[1], comments, "Add review comment", function(body)
      if not body then
        return
      end
      vim.notify("Adding review comment...", vim.log.levels.INFO)
      github.add_review_comment(pr_number, file_path, cursor_line, body, function(ok, err)
        if ok then
          vim.notify("✅ Review comment added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to add review comment: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end)
    end, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_review_comment",
      comment_id = line_comments[1].id,
    })
  else
    -- No existing comments, just prompt for input
    input_multiline("Review comment for line " .. cursor_line, function(body)
      if not body then
        return
      end
      vim.notify("Adding review comment...", vim.log.levels.INFO)
      github.add_review_comment(pr_number, file_path, cursor_line, body, function(ok, err)
        if ok then
          vim.notify("✅ Review comment added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to add review comment: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end)
    end, nil, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_review_comment",
    })
  end
end

function M.add_pending_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file_path = get_relative_path(bufnr)

  -- Check if there are existing comments on this line
  local comments = M._buffer_comments[bufnr] or {}
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  -- Show thread if there are existing comments
  if #line_comments > 0 then
    input_comment_with_context(line_comments[1], comments, "Add pending comment", function(body)
      if not body then
        return
      end
      -- Get current user
      github.get_current_user(function(user, err)
        local username = user or "me"

        -- Add comment to local storage
        local comment = add_local_pending_comment(pr_number, file_path, cursor_line, body, username)

        -- Save session to persist pending comments
        save_session()

        vim.notify("✅ Pending comment added locally (will be posted with approval/rejection)", vim.log.levels.INFO)

        -- Reload comments to show the new pending comment
        M.load_comments_for_buffer(bufnr, false)
      end)
    end, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_pending_thread",
      comment_id = line_comments[1].id,
    })
  else
    -- No existing comments, just prompt for input
    input_multiline("Pending comment for line " .. cursor_line .. " (will be posted with review)", function(body)
      if not body then
        return
      end
      -- Get current user
      github.get_current_user(function(user, err)
        local username = user or "me"

        -- Add comment to local storage
        local comment = add_local_pending_comment(pr_number, file_path, cursor_line, body, username)

        -- Save session to persist pending comments
        save_session()

        vim.notify("✅ Pending comment added locally (will be posted with approval/rejection)", vim.log.levels.INFO)

        -- Reload comments to show the new pending comment
        M.load_comments_for_buffer(bufnr, false)
      end)
    end, nil, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "add_pending",
      comment_id = nil,
    })
  end
end

function M.list_pending_comments()
  -- Collect all pending comments from all PRs
  local all_comments = {}
  for pr_number, comments in pairs(M._local_pending_comments) do
    for _, comment in ipairs(comments) do
      table.insert(all_comments, comment)
    end
  end

  if #all_comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  -- Use the UI picker to select a comment
  ui.select_pending_comment(all_comments, M.config.picker, function(selected_comment)
    if not selected_comment then
      return
    end

    -- Navigate to the file and line
    local file_path = selected_comment.path

    -- Try to find buffer with this file
    local found_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match(file_path .. "$") then
        found_buf = buf
        break
      end
    end

    -- Open the file
    if found_buf then
      -- File is already open in a buffer, find or create a window for it
      local wins = vim.fn.win_findbuf(found_buf)
      if #wins > 0 then
        vim.api.nvim_set_current_win(wins[1])
      else
        vim.cmd("buffer " .. found_buf)
      end
    else
      -- Open the file
      vim.cmd("edit " .. file_path)
    end

    -- Navigate to the line
    vim.api.nvim_win_set_cursor(0, { selected_comment.line, 0 })
    vim.cmd("normal! zz")
    vim.notify(string.format("Navigated to %s:%d", file_path, selected_comment.line), vim.log.levels.INFO)
  end)
end

function M.list_all_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Fetch ALL comments from GitHub API (not just cached ones)
  github.fetch_pr_comments(pr_number, function(github_comments, err)
    if err then
      vim.notify("Failed to fetch PR comments: " .. err, vim.log.levels.ERROR)
      return
    end

    local all_comments = {}

    -- Add all GitHub comments
    for _, comment in ipairs(github_comments or {}) do
      -- Skip comments without line number (those are review-level comments)
      if comment.line then
        table.insert(all_comments, {
          id = comment.id,
          path = comment.path,
          line = comment.line,
          user = comment.user,
          body = comment.body,
          created_at = comment.created_at,
          is_local = false,
          bufnr = nil,
        })
      end
    end

    -- Add local pending comments (but check for duplicates)
    local pending_comments = get_local_pending_comments_for_pr(pr_number)
    for _, pending in ipairs(pending_comments) do
      -- Check if this comment already exists in GitHub comments
      local is_duplicate = false
      for _, posted in ipairs(all_comments) do
        if posted.path == pending.path and
            posted.line == pending.line and
            posted.body == pending.body and
            not posted.is_local then
          is_duplicate = true
          break
        end
      end

      -- Only add if not a duplicate
      if not is_duplicate then
        table.insert(all_comments, {
          id = pending.id,
          path = pending.path,
          line = pending.line,
          user = "You (PENDING)",
          body = pending.body,
          created_at = pending.created_at,
          is_local = true,
          bufnr = nil,
        })
      end
    end

    if #all_comments == 0 then
      vim.notify("No comments in this PR", vim.log.levels.INFO)
      return
    end

    -- Sort by file path, then line number
    table.sort(all_comments, function(a, b)
      if a.path ~= b.path then
        return a.path < b.path
      end
      return a.line < b.line
    end)

    -- Use the UI picker to select a comment
    ui.select_all_comments(all_comments, M.config.picker, function(selected_comment)
      if not selected_comment then
        return
      end

      -- Navigate to the file and line
      local file_path = selected_comment.path

      -- Try to find buffer with this file
      local found_buf = nil
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local buf_name = vim.api.nvim_buf_get_name(buf)
          -- Make path relative to cwd
          local cwd = vim.fn.getcwd()
          if buf_name:sub(1, #cwd) == cwd then
            buf_name = buf_name:sub(#cwd + 2)
          end
          if buf_name == file_path then
            found_buf = buf
            break
          end
        end
      end

      -- Open the file
      if found_buf then
        -- File is already open in a buffer, find or create a window for it
        local wins = vim.fn.win_findbuf(found_buf)
        if #wins > 0 then
          vim.api.nvim_set_current_win(wins[1])
        else
          vim.cmd("buffer " .. found_buf)
        end
      else
        -- Open the file
        vim.cmd("edit " .. file_path)
      end

      -- Navigate to the line
      vim.api.nvim_win_set_cursor(0, { selected_comment.line, 0 })
      vim.cmd("normal! zz")

      -- Show notification with comment info
      local status = selected_comment.is_local and "PENDING" or "Posted"
      vim.notify(
        string.format("[%s] %s:%d - %s", status, file_path, selected_comment.line, selected_comment.user),
        vim.log.levels.INFO
      )
    end)
  end)
end

-- List and view global PR comments (issue comments, not line-specific)
function M.list_global_comments()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.fetch_pr_global_comments(pr_number, function(comments, err)
    if err then
      vim.notify("Failed to fetch global comments: " .. err, vim.log.levels.ERROR)
      return
    end

    if #comments == 0 then
      vim.notify("No global comments in this PR", vim.log.levels.INFO)
      return
    end

    -- Use the UI picker to select a comment
    ui.select_global_comments(comments, M.config.picker, function(comment, index)
      if not comment then
        return
      end

      -- Show full comment in a floating window
      local lines = vim.split(comment.body, "\n")

      -- Add header
      table.insert(lines, 1, "")
      table.insert(lines, 1, string.format("By: %s", comment.user))
      table.insert(lines, 1, string.format("Comment #%d", index or 1))
      table.insert(lines, 2, string.format("Date: %s", comment.created_at))
      table.insert(lines, 3, "")
      table.insert(lines, 4, "───────────────────────────────")
      table.insert(lines, 5, "")

      -- Add footer with actions
      table.insert(lines, "")
      table.insert(lines, "───────────────────────────────")
      table.insert(lines, "")
      table.insert(lines, "Press 'r' to reply | 'q' or <Esc> to close")

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "markdown"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].modifiable = false

      local width = math.min(80, math.floor(vim.o.columns * 0.8))
      local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " Global Comment ",
        title_pos = "center",
      })

      -- Keymaps for the comment window
      local function close_window()
        -- Delete buffer first (will auto-close window due to bufhidden=wipe)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        -- Also try to close window if still valid
        pcall(vim.api.nvim_win_close, win, true)
      end

      vim.keymap.set("n", "q", close_window, { buffer = buf, nowait = true })
      vim.keymap.set("n", "<Esc>", close_window, { buffer = buf, nowait = true })

      vim.keymap.set("n", "r", function()
        close_window()
        -- Build conversation context to show while replying
        local context_lines = {
          string.format("# Replying to comment by %s (%s)", comment.user, comment.created_at:sub(1, 10)),
          "",
          "## Original Comment:",
          ""
        }

        -- Add the original comment body with quote markers
        for _, line in ipairs(vim.split(comment.body, "\n")) do
          table.insert(context_lines, "> " .. line)
        end

        table.insert(context_lines, "")
        table.insert(context_lines, "## Your Reply:")
        table.insert(context_lines, "")
        table.insert(context_lines, "")

        local initial_text = table.concat(context_lines, "\n")

        -- Reply to the comment using multiline input with context
        input_multiline("Reply to global comment", function(full_text)
          if not full_text or full_text == "" then
            return
          end

          -- Extract only the reply part (everything after "## Your Reply:")
          local reply_start = full_text:find("## Your Reply:")
          if not reply_start then
            -- Fallback: use the entire text if marker not found
            reply_text = full_text
          else
            -- Find the end of the "## Your Reply:" line
            local reply_line_end = full_text:find("\n", reply_start)
            if reply_line_end then
              reply_text = full_text:sub(reply_line_end + 1):match("^%s*(.-)%s*$") -- trim whitespace
            else
              reply_text = ""
            end
          end

          if reply_text and reply_text ~= "" then
            github.add_pr_comment(pr_number, reply_text, function(ok, add_err)
              if ok then
                vim.notify("✅ Reply added successfully", vim.log.levels.INFO)
              else
                vim.notify("❌ Failed to add reply: " .. (add_err or "unknown"), vim.log.levels.ERROR)
              end
            end)
          end
        end, initial_text, {
          pr_number = pr_number,
          file_path = nil,
          line = nil,
          action = "reply_global",
          comment_id = comment.id,
        })
      end, { buffer = buf })

      -- Auto-close if user leaves the buffer (e.g., switches windows)
      vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
          vim.defer_fn(close_window, 10)
        end,
      })
    end)
  end)
end

function M.reply_to_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    vim.notify("No comments on this line", vim.log.levels.WARN)
    return
  end

  local function do_reply(comment)
    -- Check if it's a pending comment
    if comment.is_local then
      vim.notify("❌ Cannot reply to pending comments. Submit the review first.", vim.log.levels.WARN)
      return
    end

    local file_path = get_relative_path(bufnr)
    input_reply_with_context(comment, comments, function(body)
      if not body then
        return
      end
      vim.notify("Sending reply...", vim.log.levels.INFO)
      github.reply_to_comment(pr_number, comment.id, body, function(ok, err)
        if ok then
          vim.notify("✅ Reply added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to reply: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end)
    end, {
      pr_number = pr_number,
      file_path = file_path,
      line = cursor_line,
      action = "reply",
      comment_id = comment.id,
    })
  end

  if #line_comments == 1 then
    do_reply(line_comments[1])
  else
    local items = {}
    for _, c in ipairs(line_comments) do
      table.insert(items, string.format("[%s]: %s", c.user, c.body:sub(1, 50)))
    end
    vim.ui.select(items, { prompt = "Select comment to reply:" }, function(_, idx)
      if idx then
        do_reply(line_comments[idx])
      end
    end)
  end
end

function M.edit_my_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user", vim.log.levels.ERROR)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local my_comments = {}
    for _, comment in ipairs(comments) do
      if comment.line == cursor_line and comment.user == current_user then
        table.insert(my_comments, comment)
      end
    end

    if #my_comments == 0 then
      vim.notify("No comments from you on this line", vim.log.levels.WARN)
      return
    end

    local function do_edit(comment)
      -- Show thread first if there are other comments on this line
      local line_comments = {}
      for _, c in ipairs(comments) do
        if c.line == cursor_line then
          table.insert(line_comments, c)
        end
      end

      local function open_edit_buffer()
        local buf = vim.api.nvim_create_buf(false, true)
        local width = math.floor(vim.o.columns * 0.7)
        local height = math.floor(vim.o.lines * 0.6)

        -- Check for existing draft
        local file_path = get_relative_path(bufnr)
        local draft_key = get_draft_key(pr_number, file_path, cursor_line, "edit", comment.id)
        local has_draft = M._drafts[pr_number] and M._drafts[pr_number][draft_key]

        -- Set title based on comment type
        local title = comment.is_local
            and " Edit PENDING comment (save: <C-s>, cancel: <Esc>) "
            or " Edit comment (save: <C-s>, cancel: <Esc>) "

        if has_draft then
          title = " [DRAFT RESTORED] Edit comment (save: <C-s>, cancel: <Esc>) "
        end

        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = width,
          height = height,
          col = math.floor((vim.o.columns - width) / 2),
          row = math.floor((vim.o.lines - height) / 2),
          style = "minimal",
          border = "rounded",
          title = title,
          title_pos = "center",
        })

        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].bufhidden = "wipe"

        -- Build the thread if there are other comments
        local lines = {}
        if #line_comments > 1 then
          -- Build and show thread
          local thread = build_comment_thread(comment, comments)
          table.insert(lines, "--- Conversation Thread ---")
          table.insert(lines, "")

          for _, item in ipairs(thread) do
            local indent = string.rep("  ", item.depth)
            local prefix = item.depth > 0 and "↳ " or ""

            local date = item.comment.created_at or ""
            if date ~= "" then
              date = " (" .. date:sub(1, 10) .. ")"
            end

            local pending_mark = (item.comment.is_pending and item.comment.is_local) and " [PENDING]" or ""
            table.insert(lines, indent .. prefix .. "**" .. item.comment.user .. "**" .. date .. pending_mark .. ":")

            local wrapped = wrap_text(item.comment.body, width - 4, indent)
            for _, wrapped_line in ipairs(wrapped) do
              table.insert(lines, wrapped_line)
            end
            table.insert(lines, "")
          end

          table.insert(lines, "--- Edit your comment below: ---")
          table.insert(lines, "")
        end

        local separator_line = #lines > 0 and (#lines - 1) or 0

        -- Add current comment text (or draft if it exists)
        local text_to_edit = has_draft and has_draft.text or comment.body
        for line in text_to_edit:gmatch("[^\r\n]+") do
          table.insert(lines, line)
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

        -- Highlight separator if thread was shown
        if separator_line > 0 then
          local ns_id = vim.api.nvim_create_namespace("edit_context")
          vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", separator_line - 1, 0, -1)
          vim.api.nvim_buf_add_highlight(buf, ns_id, "Title", 0, 0, -1)
        end

        -- Position cursor at the end of the text
        local last_line = #lines
        vim.api.nvim_win_set_cursor(win, { last_line, 0 })

        vim.keymap.set("n", "<Esc>", function()
          -- Save draft before closing
          local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local text
          if separator_line > 0 then
            local edit_lines = {}
            local found_separator = false
            for i, line in ipairs(new_lines) do
              if line:match("^%-%-%-+ Edit your comment below:") then
                found_separator = true
              elseif found_separator and line ~= "" then
                table.insert(edit_lines, line)
              end
            end
            text = table.concat(edit_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          else
            text = table.concat(new_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          end

          if text ~= "" then
            save_draft(pr_number, file_path, cursor_line, "edit", comment.id, text)
          end

          vim.api.nvim_win_close(win, true)
          vim.cmd("stopinsert")
        end, { buffer = buf })

        vim.keymap.set({ "n", "i" }, "<C-s>", function()
          local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

          -- Extract only the edited text (skip thread if shown)
          local text
          if separator_line > 0 then
            -- Thread was shown, extract only lines after separator
            local edit_lines = {}
            local found_separator = false
            for i, line in ipairs(new_lines) do
              if line:match("^%-%-%-+ Edit your comment below:") then
                found_separator = true
              elseif found_separator and line ~= "" then
                table.insert(edit_lines, line)
              end
            end
            text = table.concat(edit_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          else
            -- No thread, all lines are the comment
            text = table.concat(new_lines, "\n")
          end

          vim.api.nvim_win_close(win, true)
          vim.cmd("stopinsert")
          if text ~= "" then
            -- Check if it's a local pending comment
            if comment.is_local then
              vim.notify("Updating local pending comment...", vim.log.levels.INFO)

              -- Find and update the comment in local storage
              local pending_comments = M._local_pending_comments[pr_number]
              if pending_comments then
                for _, pc in ipairs(pending_comments) do
                  if pc.id == comment.id then
                    pc.body = text
                    pc.created_at = os.date("!%Y-%m-%dT%H:%M:%SZ") -- Update timestamp
                    break
                  end
                end
              end

              -- Save session to persist changes
              save_session()

              -- Clear draft after successful save
              clear_draft(pr_number, file_path, cursor_line, "edit", comment.id)

              vim.notify("✅ Local pending comment updated", vim.log.levels.INFO)
              M.load_comments_for_buffer(bufnr, false)
            else
              -- It's a GitHub comment, use API
              vim.notify("Updating comment...", vim.log.levels.INFO)
              github.edit_comment(pr_number, comment.id, text, function(ok, edit_err)
                if ok then
                  -- Clear draft after successful save
                  clear_draft(pr_number, file_path, cursor_line, "edit", comment.id)

                  vim.notify("✅ Comment updated", vim.log.levels.INFO)
                  M.load_comments_for_buffer(bufnr, true)
                else
                  vim.notify("❌ Failed to edit: " .. (edit_err or "unknown"), vim.log.levels.ERROR)
                end
              end)
            end
          end
        end, { buffer = buf })

        -- Enter insert mode automatically
        vim.cmd("startinsert!")  -- Append at end of line
      end

      -- Thread is now shown inline in the edit buffer
      open_edit_buffer()
    end

    if #my_comments == 1 then
      do_edit(my_comments[1])
    else
      local items = {}
      for _, c in ipairs(my_comments) do
        table.insert(items, c.body:sub(1, 50))
      end
      vim.ui.select(items, { prompt = "Select comment to edit:" }, function(_, idx)
        if idx then
          do_edit(my_comments[idx])
        end
      end)
    end
  end)
end

function M.delete_my_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user", vim.log.levels.ERROR)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local my_comments = {}
    for _, comment in ipairs(comments) do
      if comment.line == cursor_line and comment.user == current_user then
        table.insert(my_comments, comment)
      end
    end

    if #my_comments == 0 then
      vim.notify("No comments from you on this line", vim.log.levels.WARN)
      return
    end

    local function do_delete(comment)
      vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
        if choice == "Yes" then
          vim.notify("Deleting comment...", vim.log.levels.INFO)

          -- Check if it's a local pending comment
          if comment.is_local then
            local removed = remove_local_pending_comment(pr_number, comment.id)
            if removed then
              -- Save session to persist changes
              save_session()
              vim.notify("✅ Local pending comment deleted", vim.log.levels.INFO)
              M.load_comments_for_buffer(bufnr, true)
            else
              vim.notify("❌ Failed to delete local comment", vim.log.levels.ERROR)
            end
          else
            -- It's a GitHub comment, use API
            github.delete_comment(pr_number, comment.id, function(ok, del_err)
              if ok then
                vim.notify("✅ Comment deleted", vim.log.levels.INFO)
                M.load_comments_for_buffer(bufnr, true)
              else
                vim.notify("❌ Failed to delete: " .. (del_err or "unknown"), vim.log.levels.ERROR)
              end
            end)
          end
        end
      end)
    end

    if #my_comments == 1 then
      do_delete(my_comments[1])
    else
      local items = {}
      for _, c in ipairs(my_comments) do
        table.insert(items, c.body:sub(1, 50))
      end
      vim.ui.select(items, { prompt = "Select comment to delete:" }, function(_, idx)
        if idx then
          do_delete(my_comments[idx])
        end
      end)
    end
  end)
end

function M.load_last_session()
  if vim.g.pr_review_number then
    vim.notify("Already in review mode. Use :PRReviewCleanup first.", vim.log.levels.WARN)
    return
  end

  local session_data = load_session()
  if not session_data then
    vim.notify("No saved session found for this project", vim.log.levels.INFO)
    return
  end

  -- Verify we're in the same directory
  if session_data.cwd ~= vim.fn.getcwd() then
    vim.notify("Session is for a different directory: " .. session_data.cwd, vim.log.levels.WARN)
    return
  end

  vim.notify("Loading review session for PR #" .. session_data.pr_number .. "...", vim.log.levels.INFO)

  -- Restore global state
  vim.g.pr_review_number = session_data.pr_number
  vim.g.pr_review_base_branch = session_data.base_branch
  vim.g.pr_review_previous_branch = session_data.previous_branch
  vim.g.pr_review_modified_files = session_data.modified_files
  M._viewed_files = session_data.viewed_files or {}
  M._local_pending_comments = session_data.pending_comments or {}
  M._drafts = session_data.drafts or {}

  -- Open review buffer and first file
  M.open_review_buffer(function()
    -- Use the ordered list (same order as ReviewBuffer)
    local first_file = #M._review_files_ordered > 0 and M._review_files_ordered[1] or M._review_files[1]
    if first_file then
      open_file_safe(first_file, nil)
    end
  end)

  vim.notify("✅ Session restored for PR #" .. session_data.pr_number, vim.log.levels.INFO)
end

function M.show_pr_info()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.get_pr_info(pr_number, function(info, err)
    if err then
      vim.notify("Failed to get PR info: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Fetch CI checks in parallel
    github.get_pr_checks(pr_number, function(checks, checks_err)
      -- Continue even if checks fail
      local ci_checks = checks or {}

      local review_status = info.review_decision or "PENDING"
      local review_icon, approved_icon, changes_icon, comment_icon, mergeable_icon
      local author_prefix, branch_prefix, files_prefix, add_prefix, del_prefix
      local check_pass_icon, check_fail_icon, check_pending_icon

      if M.config.show_icons then
        check_pass_icon = "✅"
        check_fail_icon = "❌"
        check_pending_icon = "🔄"
        review_icon = "⏳"
        if review_status == "APPROVED" then
          review_icon = "✅"
        elseif review_status == "CHANGES_REQUESTED" then
          review_icon = "❌"
        elseif review_status == "REVIEW_REQUIRED" then
          review_icon = "👀"
        end

        mergeable_icon = "❓"
        if info.mergeable == "MERGEABLE" then
          mergeable_icon = "✅"
        elseif info.mergeable == "CONFLICTING" then
          mergeable_icon = "⚠️"
        end

        approved_icon = "✅"
        changes_icon = "❌"
        comment_icon = "💬"
        author_prefix = "👤 Author:"
        branch_prefix = "🌿"
        files_prefix = "📁 Files changed:"
        add_prefix = "➕ Additions:"
        del_prefix = "➖ Deletions:"
      else
        check_pass_icon = "[PASS]"
        check_fail_icon = "[FAIL]"
        check_pending_icon = "[...]"
        review_icon = "[PENDING]"
        if review_status == "APPROVED" then
          review_icon = "[APPROVED]"
        elseif review_status == "CHANGES_REQUESTED" then
          review_icon = "[CHANGES]"
        elseif review_status == "REVIEW_REQUIRED" then
          review_icon = "[REVIEW]"
        end

        mergeable_icon = "[?]"
        if info.mergeable == "MERGEABLE" then
          mergeable_icon = "[OK]"
        elseif info.mergeable == "CONFLICTING" then
          mergeable_icon = "[CONFLICT]"
        end

        approved_icon = "[+]"
        changes_icon = "[-]"
        comment_icon = ""
        author_prefix = "Author:"
        branch_prefix = ""
        files_prefix = "Files changed:"
        add_prefix = "Additions:"
        del_prefix = "Deletions:"
      end

      local approved_by = ""
      if info.reviewers and #info.reviewers.approved > 0 then
        approved_by = " (" .. table.concat(info.reviewers.approved, ", ") .. ")"
      end

      local changes_by = ""
      if info.reviewers and #info.reviewers.changes_requested > 0 then
        changes_by = " (" .. table.concat(info.reviewers.changes_requested, ", ") .. ")"
      end

      local lines = {
        string.format("# PR #%d", info.number),
        "",
        string.format("**%s**", info.title),
        "",
        string.format("%s %s", author_prefix, info.author),
        string.format("%s %s → %s", branch_prefix, info.head_branch, info.base_branch),
        "",
      }

      -- Add description if present
      if info.body and info.body ~= "" then
        table.insert(lines, "## Description")
        table.insert(lines, "")
        for body_line in info.body:gmatch("[^\r\n]+") do
          table.insert(lines, body_line)
        end
        table.insert(lines, "")
      end

      -- Add stats
      vim.list_extend(lines, {
        "## Stats",
        string.format("%s %d", files_prefix, info.changed_files),
        string.format("%s %d", add_prefix, info.additions),
        string.format("%s %d", del_prefix, info.deletions),
        "",
        "## Reviews",
        string.format("%s Status: %s", review_icon, review_status:gsub("_", " ")),
        string.format("%s Approved: %d%s", approved_icon, info.reviews.approved, approved_by),
        string.format("%s Changes requested: %d%s", changes_icon, info.reviews.changes_requested, changes_by),
        string.format("%s Commented: %d", comment_icon, info.reviews.commented),
        "",
      })

      -- Add CI checks
      if #ci_checks > 0 then
        table.insert(lines, "## CI Checks")
        local passed = 0
        local failed = 0
        local pending = 0
        local failed_jobs = {}
        local pending_jobs = {}

        for _, check in ipairs(ci_checks) do
          local icon
          local status = check.conclusion or check.state

          if status == "success" or status == "SUCCESS" then
            icon = check_pass_icon
            passed = passed + 1
          elseif status == "failure" or status == "FAILURE" then
            icon = check_fail_icon
            failed = failed + 1
            table.insert(failed_jobs, check.name)
          else
            icon = check_pending_icon
            pending = pending + 1
            table.insert(pending_jobs, check.name)
          end

          table.insert(lines, string.format("%s %s", icon, check.name))
        end

        table.insert(lines, "")
        local total_jobs = passed + failed + pending
        table.insert(lines, string.format("**Summary:** %d/%d jobs passed", passed, total_jobs))

        if failed > 0 then
          table.insert(lines, string.format("%s **Failed jobs:** %s", check_fail_icon, table.concat(failed_jobs, ", ")))
        end

        if pending > 0 then
          table.insert(lines,
            string.format("%s **Pending jobs:** %s", check_pending_icon, table.concat(pending_jobs, ", ")))
        end

        table.insert(lines, "")
      end

      vim.list_extend(lines, {
        "## Status",
        string.format("%s Mergeable: %s", mergeable_icon, info.mergeable or "UNKNOWN"),
        string.format("%s Comments: %d", comment_icon, info.comments_count),
      })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "markdown"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].modifiable = false

      local width = math.min(100, math.floor(vim.o.columns * 0.8))
      local height = math.min(#lines, math.floor(vim.o.lines * 0.8))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " PR Info ",
        title_pos = "center",
      })

      local function close_window()
        -- Delete buffer first (will auto-close window due to bufhidden=wipe)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        -- Also try to close window if still valid
        pcall(vim.api.nvim_win_close, win, true)
      end

      vim.keymap.set("n", "q", close_window, { buffer = buf, nowait = true })
      vim.keymap.set("n", "<Esc>", close_window, { buffer = buf, nowait = true })

      -- Auto-close if user leaves the buffer (e.g., switches windows)
      vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
          vim.defer_fn(close_window, 10)
        end,
      })
    end) -- End of get_pr_checks callback
  end)   -- End of get_pr_info callback
end

function M.open_pr()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local cmd = string.format("gh pr view %d --web", pr_number)
  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("Failed to open PR in browser", vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

-- Helper function to check if we should cleanup before starting a new review
local function check_and_cleanup_if_needed(callback)
  if vim.g.pr_review_number then
    -- Already in review mode, ask user if they want to cleanup
    vim.ui.select(
      { "Yes, cleanup first", "No, continue without cleanup" },
      {
        prompt = "You are already reviewing PR #" ..
            vim.g.pr_review_number .. ". Do you want to cleanup the current review before starting a new one?",
      },
      function(choice)
        if not choice then
          -- User cancelled
          return
        end

        if choice == "Yes, cleanup first" then
          -- Cleanup and then call the callback
          M.cleanup_review_branch()
          -- Wait a bit for cleanup to complete before starting new review
          vim.defer_fn(callback, 500)
        else
          -- Continue without cleanup
          callback()
        end
      end
    )
  else
    -- Not in review mode, proceed directly
    callback()
  end
end

function M.list_review_requests()
  if git.has_uncommitted_changes() then
    vim.notify("Cannot start review: you have uncommitted changes. Please commit or stash them first.",
      vim.log.levels.ERROR)
    return
  end

  check_and_cleanup_if_needed(function()
    vim.notify("Fetching review requests...", vim.log.levels.INFO)

    github.list_review_requests(function(prs, err)
      if err then
        vim.notify("Error fetching review requests: " .. err, vim.log.levels.ERROR)
        return
      end

      if not prs or #prs == 0 then
        vim.notify("No review requests found", vim.log.levels.INFO)
        return
      end

      vim.notify("Found " .. #prs .. " review request(s)", vim.log.levels.INFO)

      local function on_select(pr)
        if not pr then
          return
        end
        M._start_review_for_pr(pr)
      end

      ui.select_review_request(prs, M.config.picker, M.config.show_icons, on_select)
    end)
  end)
end

function M._start_review_for_pr(pr)
  -- Check if already in review mode for a different PR
  if vim.g.pr_review_number and vim.g.pr_review_number ~= pr.number then
    vim.notify(string.format("Cleaning up current review (PR #%d) to start PR #%d...",
      vim.g.pr_review_number, pr.number), vim.log.levels.INFO)
    M.cleanup_review_branch()
    -- Wait a bit for cleanup to complete
    vim.defer_fn(function()
      M._start_review_for_pr(pr)
    end, 500)
    return
  end

  local current_branch = git.get_current_branch()
  if current_branch then
    vim.g.pr_review_previous_branch = current_branch
  end

  vim.notify("Starting review for PR #" .. pr.number .. "...", vim.log.levels.INFO)

  -- For fork PRs, get the correct branch name using gh pr view
  if pr.head_repo_owner then
    debug_log(string.format("Debug: Detected fork PR, owner=%s, getting details...", pr.head_repo_owner))
    github.get_pr_details(pr.number, function(details, err)
      if err or not details then
        vim.notify("Error getting PR details: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
      end

      debug_log(string.format("Debug: Got branch %s, was %s", details.head_branch, pr.head_branch))

      -- Update PR with correct branch from details
      pr.head_branch = details.head_branch
      pr.head_label = details.head_label

      M._do_start_review(pr)
    end)
  else
    debug_log("Debug: Not a fork PR, using branch as-is")
    M._do_start_review(pr)
  end
end

function M._do_start_review(pr)
  -- Use head_label for fork PRs (includes owner:branch), replace : with -
  local head_ref = (pr.head_label or pr.head_branch):gsub(":", "-")
  local review_branch = string.format(
    "%s%s_to_%s",
    M.config.branch_prefix,
    head_ref,
    pr.base_branch
  )

  git.fetch_all(function(fetch_ok, fetch_err)
    if not fetch_ok then
      vim.notify("Error fetching: " .. (fetch_err or "unknown"), vim.log.levels.ERROR)
      return
    end

    git.create_review_branch(review_branch, pr.base_branch, function(ok, create_err)
      if not ok then
        vim.notify("Error creating branch: " .. (create_err or "unknown"), vim.log.levels.ERROR)
        return
      end

      debug_log(string.format("Debug: About to merge - branch=%s, owner=%s, url=%s",
        pr.head_branch or "nil",
        pr.head_repo_owner or "nil",
        pr.head_repo_url or "nil"))
      git.soft_merge(pr.head_branch, pr.head_repo_owner, pr.head_repo_url, function(merge_ok, merge_err, has_conflicts)
        if not merge_ok then
          vim.notify("Error during soft merge: " .. (merge_err or "unknown"), vim.log.levels.ERROR)
          return
        end

        vim.g.pr_review_number = pr.number
        vim.g.pr_review_base_branch = pr.base_branch

        if has_conflicts then
          vim.notify(
            string.format("⚠️  PR #%s has merge conflicts. Review will show conflicted state.", pr.number),
            vim.log.levels.WARN
          )
        else
          vim.notify(
            string.format("✅ Ready to review PR #%s: %s", pr.number, pr.title),
            vim.log.levels.INFO
          )
        end

        git.get_modified_files_with_lines(function(files, hunks)
          if files and #files > 0 then
            vim.g.pr_review_modified_files = vim.tbl_map(function(f)
              return { path = f.path, status = f.status }
            end, files)

            -- Save initial session
            save_session()

            -- Open review buffer and first file
            M.open_review_buffer(function()
              if M.config.open_files_on_review then
                -- Use the ordered list (same order as ReviewBuffer)
                local first_file = #M._review_files_ordered > 0 and M._review_files_ordered[1] or M._review_files[1]
                if first_file then
                  open_file_safe(first_file, nil)
                end
              end
            end)
          end
        end)
      end)
    end)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("PRReview", function()
    M.review_pr()
  end, { desc = "Select and review a GitHub PR" })

  vim.api.nvim_create_user_command("PRReviewCleanup", function()
    M.cleanup_review_branch()
  end, { desc = "Cleanup review branch and return to previous branch" })

  vim.api.nvim_create_user_command("PRInfo", function()
    M.show_pr_info()
  end, { desc = "Show PR information" })

  vim.api.nvim_create_user_command("PRReviewComment", function()
    M.show_comments_at_cursor()
  end, { desc = "Show PR comments at cursor line" })

  vim.api.nvim_create_user_command("PRApprove", function()
    M.approve_pr()
  end, { desc = "Approve the current PR" })

  vim.api.nvim_create_user_command("PRRequestChanges", function()
    M.request_changes()
  end, { desc = "Request changes on the current PR" })

  vim.api.nvim_create_user_command("PRComment", function()
    M.add_comment()
  end, { desc = "Add a general comment to the PR" })

  vim.api.nvim_create_user_command("PRLineComment", function()
    M.add_review_comment()
  end, { desc = "Add a review comment on the current line" })

  vim.api.nvim_create_user_command("PRPendingComment", function()
    M.add_pending_comment()
  end, { desc = "Add a pending review comment (posted with approval/rejection)" })

  vim.api.nvim_create_user_command("PRSubmitPendingComments", function()
    M.submit_pending_comments()
  end, { desc = "Submit all pending comments as a review (without approving/rejecting)" })

  vim.api.nvim_create_user_command("PRListPendingComments", function()
    M.list_pending_comments()
  end, { desc = "List all pending comments and navigate to selected one" })

  vim.api.nvim_create_user_command("PRListAllComments", function()
    M.list_all_comments()
  end, { desc = "List all comments (pending + posted) with preview" })

  vim.api.nvim_create_user_command("PRGlobalComments", function()
    M.list_global_comments()
  end, { desc = "List and view global PR comments" })

  vim.api.nvim_create_user_command("PRReply", function()
    M.reply_to_comment()
  end, { desc = "Reply to a comment on the current line" })

  vim.api.nvim_create_user_command("PREditComment", function()
    M.edit_my_comment()
  end, { desc = "Edit your comment on the current line" })

  vim.api.nvim_create_user_command("PRDeleteComment", function()
    M.delete_my_comment()
  end, { desc = "Delete your comment on the current line" })

  vim.api.nvim_create_user_command("PRReviewMenu", function()
    M.show_review_menu()
  end, { desc = "Show PR Reviewer command menu" })

  vim.api.nvim_create_user_command("PR", function()
    M.show_review_menu()
  end, { desc = "Show PR Reviewer command menu (alias for PRReviewMenu)" })

  -- Visual mode suggestion command
  -- Recommended keybind: vim.keymap.set('v', '<leader>gs', ':<C-u>\'<,\'>PRSuggestChange<CR>', { desc = 'Suggest change' })
  -- This ensures the range is always passed correctly
  vim.api.nvim_create_user_command("PRSuggestChange", function(args)
    local start_line, end_line

    -- Get visual selection from range if provided (when called with ':<,'>PRSuggestChange')
    if args.range > 0 then
      start_line = args.line1
      end_line = args.line2
    else
      -- Fallback to marks (when called with '<cmd>PRSuggestChange<CR>')
      local start_pos = vim.fn.getpos("'<")
      local end_pos = vim.fn.getpos("'>")

      if start_pos[2] == 0 or end_pos[2] == 0 then
        vim.notify("No visual selection. Select code first with V or v", vim.log.levels.WARN)
        return
      end

      start_line = start_pos[2]
      end_line = end_pos[2]
    end

    -- Get the full lines
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

    if #lines == 0 then
      vim.notify("No lines selected", vim.log.levels.WARN)
      return
    end

    local visual_sel = {
      text = table.concat(lines, "\n"),
      full_lines = lines,
      start_line = start_line,
      end_line = end_line,
    }

    M._visual_selection = visual_sel

    -- Ask which type
    vim.ui.select(
      { "Immediate (post now)", "Pending (post with review)" },
      { prompt = "Suggest code change:" },
      function(choice, idx)
        if not choice then
          M._visual_selection = nil
          return
        end

        if idx == 1 then
          M.add_review_comment_with_selection()
        else
          M.add_pending_comment_with_selection()
        end
      end
    )
  end, { desc = "Suggest code change from visual selection", range = true })

  vim.api.nvim_create_user_command("PRListReviewRequests", function()
    M.list_review_requests()
  end, { desc = "List PRs where you are requested as reviewer" })

  vim.api.nvim_create_user_command("PROpen", function()
    M.open_pr()
  end, { desc = "Open PR in browser" })

  vim.api.nvim_create_user_command("PRLoadLastSession", function()
    M.load_last_session()
  end, { desc = "Load last PR review session" })

  vim.api.nvim_create_user_command("PRReviewBuffer", function()
    M.open_review_buffer()
  end, { desc = "Open PR review buffer" })

  -- Setup global navigation keymaps
  setup_global_review_keymaps()

  local augroup = vim.api.nvim_create_augroup("PRReviewComments", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      if vim.g.pr_review_number then

        M.load_comments_for_buffer(args.buf)

        -- Always load changes (for hunks data needed by floats)
        -- Visual indicators (│) are only added when not in split mode (handled in load_changes_for_buffer)
        load_changes_for_buffer(args.buf)

        -- Only load inline diff when NOT in split mode
        if M._diff_view_mode ~= "split" then
          load_inline_diff_for_buffer(args.buf)
        else
          -- Auto-fix split when buffer is changed manually (not from our navigation)
          -- This fixes the issue when user switches buffers with :b or fzf
          if not M._opening_file then  -- Don't interfere with our own navigation
            local buf_name = vim.api.nvim_buf_get_name(args.buf)
            local buftype = vim.bo[args.buf].buftype

            -- Only auto-fix for regular files (not [BEFORE] buffers, not special buffers)
            -- Skip buffers used by menus, pickers, prompts, terminals, etc.
            if not buf_name:match("^%[BEFORE%]") and
               buftype ~= "prompt" and
               buftype ~= "nofile" and
               buftype ~= "terminal" and
               buftype ~= "quickfix" then
              -- Check if we have a split state that doesn't match current buffer
              if M._split_view_state and M._split_view_state.current_buf then
                -- Only auto-fix if the split state is for a different buffer
                if M._split_view_state.current_buf ~= args.buf then
                  -- Check if this file is part of the PR changes
                  local file_path = get_relative_path(args.buf)
                  if file_path then
                    -- Schedule the fix to avoid interfering with BufEnter processing
                    vim.defer_fn(function()
                      -- Double-check we're still in split mode and on the same buffer
                      if M._diff_view_mode == "split" and vim.api.nvim_get_current_buf() == args.buf then
                        M.fix_vsplit()
                      end
                    end, 100)
                  end
                end
              end
            end
          end
        end

        -- Update review buffer to highlight current file
        M.refresh_review_buffer()

        -- Jump to first change if we haven't already for this buffer
        -- Note: keymaps are now set in load_changes_for_buffer callback, only for files with changes
        if not M._buffer_jumped[args.buf] then
          vim.defer_fn(function()
            local hunks = M._buffer_hunks[args.buf]
            if hunks and #hunks > 0 and vim.api.nvim_get_current_buf() == args.buf then
              -- Check if the line exists in the buffer before setting cursor
              local line_count = vim.api.nvim_buf_line_count(args.buf)
              if hunks[1].start_line > 0 and hunks[1].start_line <= line_count then
                vim.api.nvim_win_set_cursor(0, { hunks[1].start_line, 0 })
                vim.cmd("normal! zz")
              end
              M._buffer_jumped[args.buf] = true
            end
          end, 100)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorHold", {
    group = augroup,
    callback = function()
      if vim.g.pr_review_number then
        M.show_comments_at_cursor()
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = function()
      if vim.g.pr_review_number then
        update_hunk_navigation_hints()
        update_changes_float()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    callback = function()
      close_float_wins()
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      -- Clean up tracking when buffer is deleted
      M._buffer_keymaps_saved[args.buf] = nil
      M._buffer_jumped[args.buf] = nil
      M._buffer_comments[args.buf] = nil
      M._buffer_changes[args.buf] = nil
      M._buffer_hunks[args.buf] = nil
      M._buffer_stats[args.buf] = nil
    end,
  })

  -- Note: Keymaps are now set as buffer-local in the BufEnter autocmd
  -- This ensures they only work during review mode and don't conflict with existing keymaps
end

function M.review_pr()
  if git.has_uncommitted_changes() then
    vim.notify("Cannot start review: you have uncommitted changes. Please commit or stash them first.",
      vim.log.levels.ERROR)
    return
  end

  check_and_cleanup_if_needed(function()
    local prs, err = github.list_open_prs()
    if err then
      vim.notify("Error fetching PRs: " .. err, vim.log.levels.ERROR)
      return
    end

    if #prs == 0 then
      vim.notify("No open PRs found", vim.log.levels.INFO)
      return
    end

    ui.select_pr(prs, M.config.picker, function(pr)
      if not pr then
        return
      end

      local current_branch = git.get_current_branch()
      if current_branch then
        vim.g.pr_review_previous_branch = current_branch
      end

      -- For fork PRs, get the correct branch name using gh pr view
      if pr.head_repo_owner then
        debug_log(string.format("Debug: Detected fork PR, owner=%s, getting details...", pr.head_repo_owner))
        github.get_pr_details(pr.number, function(details, err)
          if err or not details then
            vim.notify("Error getting PR details: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
          end

          debug_log(string.format("Debug: Got branch %s, was %s", details.head_branch, pr.head_branch))

          -- Update PR with correct branch from details
          pr.head_branch = details.head_branch
          pr.head_label = details.head_label

          debug_log("Debug: About to call _do_review_pr_with_branch")
          M._do_review_pr_with_branch(pr)
        end)
      else
        debug_log("Debug: Not a fork PR, using branch as-is")
        M._do_review_pr_with_branch(pr)
      end
    end)
  end)
end

function M._do_review_pr_with_branch(pr)
  -- Use head_label for fork PRs (includes owner:branch), replace : with -
  local head_ref = (pr.head_label or pr.head_branch):gsub(":", "-")
  local review_branch = string.format(
    "%s%s_to_%s",
    M.config.branch_prefix,
    head_ref,
    pr.base_branch
  )

  git.fetch_all(function(fetch_ok, fetch_err)
    if not fetch_ok then
      vim.notify("Error fetching: " .. (fetch_err or "unknown"), vim.log.levels.ERROR)
      return
    end

    git.create_review_branch(review_branch, pr.base_branch, function(ok, create_err)
      if not ok then
        vim.notify("Error creating branch: " .. (create_err or "unknown"), vim.log.levels.ERROR)
        return
      end

      debug_log(string.format("Debug: About to merge - branch=%s, owner=%s, url=%s",
        pr.head_branch or "nil",
        pr.head_repo_owner or "nil",
        pr.head_repo_url or "nil"))
      git.soft_merge(pr.head_branch, pr.head_repo_owner, pr.head_repo_url, function(merge_ok, merge_err, has_conflicts)
        if not merge_ok then
          vim.notify("Error during soft merge: " .. (merge_err or "unknown"), vim.log.levels.ERROR)
          return
        end

        vim.g.pr_review_number = pr.number
        vim.g.pr_review_base_branch = pr.base_branch

        if has_conflicts then
          vim.notify(
            string.format("⚠️  PR #%s has merge conflicts. Review will show conflicted state.", pr.number),
            vim.log.levels.WARN
          )
        else
          vim.notify(
            string.format("✅ Ready to review PR #%s: %s", pr.number, pr.title),
            vim.log.levels.INFO
          )
        end

        git.get_modified_files_with_lines(function(files)
          if files and #files > 0 then
            vim.g.pr_review_modified_files = vim.tbl_map(function(f)
              return { path = f.path, status = f.status }
            end, files)

            -- Save initial session
            save_session()

            -- Open review buffer and first file
            M.open_review_buffer(function()
              if M.config.open_files_on_review then
                -- Use the ordered list (same order as ReviewBuffer)
                local first_file = #M._review_files_ordered > 0 and M._review_files_ordered[1] or M._review_files[1]
                if first_file then
                  open_file_safe(first_file, nil)
                end
              end
            end)
          end
        end)
      end)
    end)
  end)
end

function M.cleanup_review_branch()
  local current = git.get_current_branch()
  if not current or not current:match("^" .. M.config.branch_prefix) then
    vim.notify("Not on a review branch", vim.log.levels.WARN)
    return
  end

  local target = vim.g.pr_review_previous_branch or "master"

  git.cleanup_review(current, target, function(ok, err)
    if ok then
      delete_session()
      vim.g.pr_review_number = nil
      vim.g.pr_review_base_branch = nil
      github.clear_cache()
      M._buffer_comments = {}
      M._buffer_changes = {}
      M._buffer_hunks = {}
      M._buffer_stats = {}
      M._viewed_files = {}
      M._buffer_jumped = {}
      M._buffer_keymaps_saved = {}
      M._review_files = {}
      M._review_files_ordered = {}
      M._review_filter = "all"
      M._local_pending_comments = {}
      if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
        vim.api.nvim_win_close(M._review_window, true)
      end
      M._review_window = nil
      M._review_buffer = nil
      close_float_wins()

      -- Restore unified view if in split mode
      if M._diff_view_mode == "split" then
        restore_unified_view()
      end
      M._diff_view_mode = "unified"
      M._split_view_state = {}

      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
          vim.api.nvim_buf_clear_namespace(buf, changes_ns_id, 0, -1)
          vim.api.nvim_buf_clear_namespace(buf, diff_ns_id, 0, -1)
          vim.api.nvim_buf_clear_namespace(buf, hunk_hints_ns_id, 0, -1)
          -- Delete buffer-local keymaps
          pcall(vim.keymap.del, "n", M.config.next_hunk_key, { buffer = buf })
          pcall(vim.keymap.del, "n", M.config.prev_hunk_key, { buffer = buf })
          pcall(vim.keymap.del, "n", M.config.mark_as_viewed_key, { buffer = buf })
          pcall(vim.keymap.del, "n", M.config.diff_view_toggle_key, { buffer = buf })
          pcall(vim.keymap.del, "n", M.config.toggle_floats_key, { buffer = buf })
        end
      end

      vim.notify("Cleaned up review branch, back on: " .. target, vim.log.levels.INFO)
    else
      vim.notify("Error cleaning up: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

-- Menu buffer state
M._menu_buffer = nil
M._menu_window = nil
M._visual_selection = nil -- Store visual selection for comments

-- Helper function to get visual selection
local function get_visual_selection()
  -- Use marks to get the last visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end

  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local start_col = start_pos[3]
  local end_col = end_pos[3]

  -- Get the full lines (for suggestion feature, we want complete lines)
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  if #lines == 0 then
    return nil
  end

  return {
    text = table.concat(lines, "\n"),
    full_lines = lines,
    start_line = start_line,
    end_line = end_line,
  }
end

-- Helper function to show menu window
local function show_menu_window(sections)
  -- Create new buffer every time to refresh content
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "pr-review-menu"
  vim.bo[bufnr].modifiable = false

  -- Build menu content
  local lines = {}
  local highlights = {}
  local width = 40

  -- Add sections
  for _, section in ipairs(sections) do
    -- Section title (centered)
    local title_idx = #lines
    local padding = math.floor((width - #section.title) / 2)
    local centered_title = string.rep(" ", padding) .. section.title
    table.insert(lines, centered_title)
    table.insert(highlights, { line = title_idx, col_start = 0, col_end = -1, hl_group = "Title" })

    -- Section items
    for _, item in ipairs(section.items) do
      local line_idx = #lines
      local line = "  " .. item.key .. " - " .. item.desc
      table.insert(lines, line)

      -- Highlight the key (single letter)
      table.insert(highlights, { line = line_idx, col_start = 2, col_end = 3, hl_group = "Keyword" })
    end

    table.insert(lines, "")
  end

  -- Set buffer content (temporarily enable modifiable)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights
  local menu_ns = vim.api.nvim_create_namespace("pr_review_menu")
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, menu_ns, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end

  -- Create floating window
  local height = #lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win_id = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  -- Disable cursor line and modifications
  vim.wo[win_id].cursorline = false
  vim.wo[win_id].number = false
  vim.wo[win_id].relativenumber = false
  vim.wo[win_id].signcolumn = "no"

  -- Save original cursor highlights and make cursor invisible
  local original_cursor = vim.api.nvim_get_hl(0, { name = "Cursor" })
  local original_lcursor = vim.api.nvim_get_hl(0, { name = "lCursor" })
  local original_termcursor = vim.api.nvim_get_hl(0, { name = "TermCursor" })

  -- Preserve original colors and add blend=100 to make cursor invisible
  local cursor_invisible = vim.tbl_extend("force", original_cursor, { blend = 100 })
  local lcursor_invisible = vim.tbl_extend("force", original_lcursor, { blend = 100 })
  local termcursor_invisible = vim.tbl_extend("force", original_termcursor, { blend = 100 })

  vim.api.nvim_set_hl(0, "Cursor", cursor_invisible)
  vim.api.nvim_set_hl(0, "lCursor", lcursor_invisible)
  vim.api.nvim_set_hl(0, "TermCursor", termcursor_invisible)

  -- Function to restore cursor highlights
  local function restore_cursor()
    vim.api.nvim_set_hl(0, "Cursor", original_cursor)
    vim.api.nvim_set_hl(0, "lCursor", original_lcursor)
    vim.api.nvim_set_hl(0, "TermCursor", original_termcursor)
  end

  -- Setup keymaps for the menu buffer
  local function close_menu()
    restore_cursor()
    if vim.api.nvim_win_is_valid(win_id) then
      vim.api.nvim_win_close(win_id, true)
    end
  end

  -- Add autocmds to restore cursor when leaving the menu
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = bufnr,
    once = false,
    callback = restore_cursor,
  })

  -- Close with q and Esc
  vim.keymap.set("n", "q", close_menu, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close_menu, { buffer = bufnr, silent = true, nowait = true })

  -- Setup keymaps for all menu items
  for _, section in ipairs(sections) do
    for _, item in ipairs(section.items) do
      vim.keymap.set("n", item.key, function()
        close_menu()
        -- Execute command after a small delay to allow menu to close
        vim.defer_fn(item.cmd, 50)
      end, { buffer = bufnr, silent = true, nowait = true })
    end
  end
end

function M.show_review_menu()
  -- Check if in review mode
  local in_review_mode = vim.g.pr_review_number ~= nil

  -- Check if there's a saved session
  local has_session = false
  local session_file = get_session_file()
  local file = io.open(session_file, "r")
  if file then
    file:close()
    has_session = true
  end

  -- Define menu sections based on mode
  local sections = {}

  if not in_review_mode then
    -- Not in review mode - show PR selection options
    sections = {
      {
        title = "Pull Request",
        items = {
          { key = "l", desc = "List Pull Requests",               cmd = function() M.review_pr() end },
          { key = "r", desc = "List Pull Requests with Assignee", cmd = function() M.list_review_requests() end },
        }
      },
    }

    if has_session then
      table.insert(sections[1].items,
        { key = "s", desc = "Load Last Session", cmd = function() M.load_last_session() end })
    end
  else
    -- In review mode - show review actions
    sections = {
      {
        title = "Pull Request",
        items = {
          { key = "i", desc = "PR Info",            cmd = function() M.show_pr_info() end },
          { key = "o", desc = "Open PR in Browser", cmd = function() M.open_pr() end },
          { key = "c", desc = "Comment on PR",      cmd = function() M.add_comment() end },
          { key = "a", desc = "Approve PR",         cmd = function() M.approve_pr() end },
          { key = "x", desc = "Request Changes",    cmd = function() M.request_changes() end },
          { key = "e", desc = "Exit Review",        cmd = function() M.cleanup_review_branch() end },
        }
      },
      {
        title = "General",
        items = {
          { key = "b", desc = "Toggle Review Buffer", cmd = function() M.toggle_review_buffer() end },
        }
      },
      {
        title = "Line Comment",
        items = {
          { key = "l", desc = "Add Line Comment",    cmd = function() M.add_review_comment() end },
          { key = "p", desc = "Add Pending Comment", cmd = function() M.add_pending_comment() end },
          { key = "r", desc = "Reply to Comment",    cmd = function() M.reply_to_comment() end },
          { key = "m", desc = "Edit My Comment",     cmd = function() M.edit_my_comment() end },
          { key = "d", desc = "Delete Comment",      cmd = function() M.delete_my_comment() end },
        }
      },
      {
        title = "Comments",
        items = {
          { key = "s", desc = "Submit Pending Comments", cmd = function() M.submit_pending_comments() end },
          { key = "v", desc = "List All Comments",       cmd = function() M.list_all_comments() end },
          { key = "g", desc = "Global PR Comments",      cmd = function() M.list_global_comments() end },
        }
      },
    }
  end

  show_menu_window(sections)
end

return M
