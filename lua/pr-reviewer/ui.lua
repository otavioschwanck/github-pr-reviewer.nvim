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

local function select_review_requests_native(prs, show_icons, on_select, on_mark_viewed)
  local items = {}
  local pr_map = {}

  for _, pr in ipairs(prs) do
    local display = format_review_request(pr, show_icons)
    table.insert(items, display)
    pr_map[display] = pr
  end

  vim.ui.select(items, {
    prompt = "Select PR to review (no mark as viewed in native picker):",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      on_select(pr_map[choice])
    end
  end)
end

local function select_review_requests_fzf(prs, show_icons, on_select, on_mark_viewed)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_review_requests_native(prs, show_icons, on_select, on_mark_viewed)
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
    fzf_opts = {
      ["--header"] = "enter: review | ctrl-v: mark as viewed",
    },
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          on_select(pr_map[selected[1]])
        end
      end,
      ["ctrl-v"] = function(selected)
        if selected and #selected > 0 then
          local pr = pr_map[selected[1]]
          on_mark_viewed(pr)
        end
      end,
    },
  })
end

local function select_review_requests_telescope(prs, show_icons, on_select, on_mark_viewed)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_review_requests_native(prs, show_icons, on_select, on_mark_viewed)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Review Requests (enter: review | <C-v>: mark as viewed)",
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

        map({ "i", "n" }, "<C-v>", function()
          local selection = action_state.get_selected_entry()
          if selection then
            actions.close(prompt_bufnr)
            on_mark_viewed(selection.value)
          end
        end)

        return true
      end,
    })
    :find()
end

function M.select_review_request(prs, picker, show_icons, on_select, on_mark_viewed)
  if picker == "fzf-lua" then
    select_review_requests_fzf(prs, show_icons, on_select, on_mark_viewed)
  elseif picker == "telescope" then
    select_review_requests_telescope(prs, show_icons, on_select, on_mark_viewed)
  else
    select_review_requests_native(prs, show_icons, on_select, on_mark_viewed)
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

return M
