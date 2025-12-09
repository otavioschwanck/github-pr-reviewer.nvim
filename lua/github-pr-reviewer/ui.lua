local M = {}

local function format_pr(pr)
  return string.format(
    "#%d [%s] %s (%s -> %s)",
    pr.number,
    pr.author,
    pr.title,
    pr.head_branch,
    pr.base_branch
  )
end

local function build_pr_list(prs)
  local items = {}
  local pr_map = {}

  for _, pr in ipairs(prs) do
    local display = format_pr(pr)
    table.insert(items, display)
    pr_map[display] = pr
  end

  return items, pr_map
end

local function select_native(prs, callback)
  local items, pr_map = build_pr_list(prs)

  vim.ui.select(items, {
    prompt = "Select PR to review:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      callback(pr_map[choice])
    else
      callback(nil)
    end
  end)
end

local function select_fzf_lua(prs, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_native(prs, callback)
  end

  local items, pr_map = build_pr_list(prs)

  fzf.fzf_exec(items, {
    prompt = "Select PR to review> ",
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          callback(pr_map[selected[1]])
        else
          callback(nil)
        end
      end,
    },
  })
end

local function select_telescope(prs, callback)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_native(prs, callback)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Select PR to review",
      finder = finders.new_table({
        results = prs,
        entry_maker = function(pr)
          local display = format_pr(pr)
          return {
            value = pr,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            callback(selection.value)
          else
            callback(nil)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.select_pr(prs, picker, callback)
  if picker == "fzf-lua" then
    select_fzf_lua(prs, callback)
  elseif picker == "telescope" then
    select_telescope(prs, callback)
  else
    select_native(prs, callback)
  end
end

local function format_review_request(pr, show_icons)
  local stats = string.format("+%d/-%d", pr.additions, pr.deletions)
  if show_icons then
    local viewed_icon = pr.viewed and "✓" or "○"
    return string.format(
      "%s #%d [%s] %s (%s) %s",
      viewed_icon,
      pr.number,
      pr.author,
      pr.title,
      pr.head_branch,
      stats
    )
  else
    local viewed_text = pr.viewed and "[viewed]" or "[new]"
    return string.format(
      "%s #%d [%s] %s (%s) %s",
      viewed_text,
      pr.number,
      pr.author,
      pr.title,
      pr.head_branch,
      stats
    )
  end
end

local function select_review_requests_native(prs, show_icons, on_select)
  local items = {}
  local pr_map = {}

  for _, pr in ipairs(prs) do
    local display = format_review_request(pr, show_icons)
    table.insert(items, display)
    pr_map[display] = pr
  end

  vim.ui.select(items, {
    prompt = "Select PR to review:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      on_select(pr_map[choice])
    end
  end)
end

local function select_review_requests_fzf(prs, show_icons, on_select)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_review_requests_native(prs, show_icons, on_select)
  end

  local items = {}
  local pr_map = {}

  for _, pr in ipairs(prs) do
    local display = format_review_request(pr, show_icons)
    table.insert(items, display)
    pr_map[display] = pr
  end

  fzf.fzf_exec(items, {
    prompt = "Review Requests> ",
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          on_select(pr_map[selected[1]])
        end
      end,
    },
  })
end

local function select_review_requests_telescope(prs, show_icons, on_select)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_review_requests_native(prs, show_icons, on_select)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Review Requests",
      finder = finders.new_table({
        results = prs,
        entry_maker = function(pr)
          local display = format_review_request(pr, show_icons)
          return {
            value = pr,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            on_select(selection.value)
          end
        end)

        return true
      end,
    })
    :find()
end

function M.select_review_request(prs, picker, show_icons, on_select)
  if picker == "fzf-lua" then
    select_review_requests_fzf(prs, show_icons, on_select)
  elseif picker == "telescope" then
    select_review_requests_telescope(prs, show_icons, on_select)
  else
    select_review_requests_native(prs, show_icons, on_select)
  end
end

-- Pending comments picker functions
local function format_pending_comment(comment)
  local preview = comment.body:gsub("\n", " "):sub(1, 60)
  if #comment.body > 60 then
    preview = preview .. "..."
  end
  return string.format("[%s:%d] %s: %s", comment.path, comment.line, comment.user, preview)
end

local function select_pending_comments_native(comments, callback)
  if #comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(comments) do
    table.insert(items, format_pending_comment(comment))
  end

  vim.ui.select(items, {
    prompt = "Select pending comment:",
  }, function(_, idx)
    if idx then
      callback(comments[idx])
    end
  end)
end

local function select_pending_comments_fzf(comments, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_pending_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  local items = {}
  local comment_map = {}
  for _, comment in ipairs(comments) do
    local display = format_pending_comment(comment)
    table.insert(items, display)
    comment_map[display] = comment
  end

  fzf.fzf_exec(items, {
    prompt = "Pending Comments> ",
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          callback(comment_map[selected[1]])
        end
      end,
    },
  })
end

local function select_pending_comments_telescope(comments, callback)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_pending_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Pending Comments",
      finder = finders.new_table({
        results = comments,
        entry_maker = function(comment)
          local display = format_pending_comment(comment)
          return {
            value = comment,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            callback(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.select_pending_comment(comments, picker, callback)
  if picker == "fzf-lua" then
    select_pending_comments_fzf(comments, callback)
  elseif picker == "telescope" then
    select_pending_comments_telescope(comments, callback)
  else
    select_pending_comments_native(comments, callback)
  end
end

-- All comments picker functions (with preview)
local function format_all_comment(comment)
  local status = comment.is_local and "[Pending]" or "[Posted]"
  return string.format("%s %s", status, comment.path)
end

local function select_all_comments_native(comments, callback)
  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(comments) do
    table.insert(items, format_all_comment(comment))
  end

  vim.ui.select(items, {
    prompt = "Select comment:",
  }, function(_, idx)
    if idx then
      callback(comments[idx])
    end
  end)
end

local function select_all_comments_fzf(comments, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_all_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  -- Create a temp directory for comment files
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  -- Write each comment to a separate file
  local temp_files = {}
  for i, comment in ipairs(comments) do
    local temp_file = temp_dir .. "/comment_" .. i .. ".txt"
    local status = comment.is_local and "[Pending]" or "[Posted]"
    local lines = {}
    table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    table.insert(lines, string.format("%s %s:%d", status, comment.path, comment.line))
    table.insert(lines, string.format("Author: %s", comment.user))
    if comment.created_at and comment.created_at ~= "" then
      table.insert(lines, string.format("Date: %s", comment.created_at))
    end
    table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    table.insert(lines, "")
    table.insert(lines, comment.body)

    vim.fn.writefile(lines, temp_file)
    table.insert(temp_files, temp_file)
  end

  -- Create entries with index
  local entries = {}
  for i, comment in ipairs(comments) do
    local status = comment.is_local and "[Pending]" or "[Posted]"
    local entry = string.format("%d|%s %s", i, status, comment.path)
    table.insert(entries, entry)
  end

  -- Create preview command
  local preview_cmd = string.format([[
    idx=$(echo {} | cut -d'|' -f1)
    if [ -z "$idx" ]; then echo "No preview"; exit 0; fi
    cat "%s/comment_${idx}.txt" 2>/dev/null || echo "Preview not available"
  ]], temp_dir)

  fzf.fzf_exec(entries, {
    prompt = "Comments> ",
    fzf_opts = {
      ["--delimiter"] = "|",
      ["--with-nth"] = "2..",
      ["--preview"] = preview_cmd,
      ["--preview-window"] = "right:60%:wrap",
    },
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          local idx = tonumber(selected[1]:match("^(%d+)"))
          if idx and comments[idx] then
            callback(comments[idx])
          end
        end
        -- Clean up temp files
        vim.fn.delete(temp_dir, "rf")
      end,
    },
  })
end

local function select_all_comments_telescope(comments, callback)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_all_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers
    .new({}, {
      prompt_title = "All Comments",
      finder = finders.new_table({
        results = comments,
        entry_maker = function(comment)
          local display = format_all_comment(comment)
          return {
            value = comment,
            display = display,
            ordinal = display,
            path = comment.path,
            lnum = comment.line,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Comment Preview",
        define_preview = function(self, entry)
          local comment = entry.value

          -- Show comment info
          local lines = {}
          local status = comment.is_local and "[Pending]" or "[Posted]"
          table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
          table.insert(lines, string.format("%s %s:%d", status, comment.path, comment.line))
          table.insert(lines, string.format("Author: %s", comment.user))
          if comment.created_at and comment.created_at ~= "" then
            table.insert(lines, string.format("Date: %s", comment.created_at))
          end
          table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
          table.insert(lines, "")

          -- Add comment body
          for line in comment.body:gmatch("[^\r\n]+") do
            table.insert(lines, line)
          end

          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "markdown"
        end,
      }),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            callback(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.select_all_comments(comments, picker, callback)
  if picker == "fzf-lua" then
    select_all_comments_fzf(comments, callback)
  elseif picker == "telescope" then
    select_all_comments_telescope(comments, callback)
  else
    select_all_comments_native(comments, callback)
  end
end

-- Select global PR comment with fzf-lua
local function select_global_comments_fzf(comments, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, using native picker", vim.log.levels.WARN)
    -- Fallback to vim.ui.select
    local items = {}
    for i, comment in ipairs(comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 80)
      if #comment.body > 80 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("#%d - %s: %s", i, comment.user, preview))
    end
    vim.ui.select(items, {
      prompt = "Global PR Comments:",
    }, function(_, idx)
      if idx then
        callback(comments[idx])
      end
    end)
    return
  end

  if #comments == 0 then
    vim.notify("No global comments", vim.log.levels.INFO)
    return
  end

  -- Create entries with index
  local entries = {}
  for i, comment in ipairs(comments) do
    local preview = comment.body:gsub("\n", " "):sub(1, 60)
    if #comment.body > 60 then
      preview = preview .. "..."
    end
    local entry = string.format("%d|%s: %s", i, comment.user, preview)
    table.insert(entries, entry)
  end

  fzf.fzf_exec(entries, {
    prompt = "Global Comments> ",
    fzf_opts = {
      ["--delimiter"] = "|",
      ["--with-nth"] = "2..",
      ["--preview"] = "echo {}  | cut -d'|' -f2-",
      ["--preview-window"] = "down:40%:wrap",
    },
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          local idx = tonumber(selected[1]:match("^(%d+)"))
          if idx and comments[idx] then
            callback(comments[idx], idx)
          end
        end
      end,
    },
  })
end

-- Select global PR comment with telescope
local function select_global_comments_telescope(comments, callback)
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope not installed, using native picker", vim.log.levels.WARN)
    -- Fallback to vim.ui.select
    local items = {}
    for i, comment in ipairs(comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 80)
      if #comment.body > 80 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("#%d - %s: %s", i, comment.user, preview))
    end
    vim.ui.select(items, {
      prompt = "Global PR Comments:",
    }, function(_, idx)
      if idx then
        callback(comments[idx])
      end
    end)
    return
  end

  if #comments == 0 then
    vim.notify("No global comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  -- Create entries
  local results = {}
  for i, comment in ipairs(comments) do
    table.insert(results, {
      index = i,
      user = comment.user,
      body = comment.body,
      created_at = comment.created_at,
      display = string.format("#%d - %s (%s)", i, comment.user, comment.created_at:sub(1, 10)),
    })
  end

  pickers.new({}, {
    prompt_title = "Global PR Comments",
    finder = finders.new_table({
      results = results,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.display,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Comment Body",
      define_preview = function(self, entry)
        local lines = vim.split(entry.value.body, "\n")
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          callback(comments[selection.value.index], selection.value.index)
        end
      end)
      return true
    end,
  }):find()
end

-- Main function to select global comments with specified picker
function M.select_global_comments(comments, picker, callback)
  if picker == "fzf-lua" or picker == "fzf" then
    select_global_comments_fzf(comments, callback)
  elseif picker == "telescope" then
    select_global_comments_telescope(comments, callback)
  else
    -- Use vim.ui.select as fallback
    local items = {}
    for i, comment in ipairs(comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 80)
      if #comment.body > 80 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("#%d - %s: %s", i, comment.user, preview))
    end
    vim.ui.select(items, {
      prompt = "Global PR Comments:",
    }, function(_, idx)
      if idx then
        callback(comments[idx], idx)
      end
    end)
  end
end

-- Select emoji reaction
function M.select_emoji_reaction(callback)
  local reactions = {
    { emoji = "👍", label = "👍 Thumbs Up", content = "+1" },
    { emoji = "👎", label = "👎 Thumbs Down", content = "-1" },
    { emoji = "😄", label = "😄 Laugh", content = "laugh" },
    { emoji = "🎉", label = "🎉 Hooray", content = "hooray" },
    { emoji = "😕", label = "😕 Confused", content = "confused" },
    { emoji = "❤️", label = "❤️ Heart", content = "heart" },
    { emoji = "🚀", label = "🚀 Rocket", content = "rocket" },
    { emoji = "👀", label = "👀 Eyes", content = "eyes" },
  }

  local items = {}
  local reaction_map = {}
  for _, reaction in ipairs(reactions) do
    table.insert(items, reaction.label)
    reaction_map[reaction.label] = reaction.content
  end

  vim.ui.select(items, {
    prompt = "Select emoji reaction:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      callback(reaction_map[choice])
    else
      callback(nil)
    end
  end)
end

return M
