local M = {}

-- Debug logging helper
local function debug_log(msg)
  local pr_reviewer = require("github-pr-reviewer")
  if pr_reviewer.config.debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

function M.get_current_branch()
  local result = vim.fn.system("git branch --show-current"):gsub("%s+", "")
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

function M.has_uncommitted_changes()
  local status = vim.fn.system("git status --porcelain")
  if vim.v.shell_error ~= 0 then
    return true
  end
  return status ~= ""
end

function M.fetch_all(callback)
  vim.fn.jobstart("git fetch --all", {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          -- Silently try just fetching origin as fallback
          vim.fn.jobstart("git fetch origin", {
            on_exit = function(_, origin_code)
              vim.schedule(function()
                if origin_code == 0 then
                  callback(true, nil)
                else
                  callback(false, "git fetch failed")
                end
              end)
            end,
          })
        end
      end)
    end,
  })
end

function M.create_review_branch(branch_name, base_branch, callback)
  local existing = vim.fn.system("git branch --list " .. vim.fn.shellescape(branch_name)):gsub("%s+", "")
  if existing ~= "" then
    vim.fn.jobstart("git branch -D " .. vim.fn.shellescape(branch_name), {
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then
            M._do_create_branch(branch_name, base_branch, callback)
          else
            callback(false, "Failed to delete existing review branch")
          end
        end)
      end,
    })
  else
    M._do_create_branch(branch_name, base_branch, callback)
  end
end

function M._do_create_branch(branch_name, base_branch, callback)
  local remote_base = "origin/" .. base_branch
  local cmd = string.format("git checkout -b %s %s", vim.fn.shellescape(branch_name), vim.fn.shellescape(remote_base))

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to create branch from " .. remote_base)
        end
      end)
    end,
  })
end

-- Add remote for fork PR if needed
function M.add_fork_remote(repo_owner, repo_url, callback)
  if not repo_owner or not repo_url then
    callback("origin")
    return
  end

  local remote_name = "fork-" .. repo_owner

  -- Check if remote already exists
  vim.fn.jobstart("git remote", {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local remote_exists = false
      if data then
        for _, line in ipairs(data) do
          if line == remote_name then
            remote_exists = true
            break
          end
        end
      end

      vim.schedule(function()
        if remote_exists then
          -- Remote exists, just fetch
          vim.fn.jobstart(string.format("git fetch %s", remote_name), {
            on_exit = function(_, code)
              vim.schedule(function()
                if code == 0 then
                  callback(remote_name)
                else
                  callback("origin") -- fallback
                end
              end)
            end,
          })
        else
          -- Add remote and fetch
          vim.fn.jobstart(string.format("git remote add %s %s", remote_name, repo_url), {
            on_exit = function(_, add_code)
              vim.schedule(function()
                if add_code == 0 then
                  vim.fn.jobstart(string.format("git fetch %s", remote_name), {
                    on_exit = function(_, fetch_code)
                      vim.schedule(function()
                        if fetch_code == 0 then
                          callback(remote_name)
                        else
                          callback("origin") -- fallback
                        end
                      end)
                    end,
                  })
                else
                  callback("origin") -- fallback
                end
              end)
            end,
          })
        end
      end)
    end,
  })
end

local function compute_merge_base()
  local result = vim.fn.system("git merge-base ORIG_HEAD MERGE_HEAD"):gsub("%s+", "")
  if vim.v.shell_error ~= 0 or result == "" then
    return nil
  end
  return result
end

-- After merge, checkout all PR files (added/modified) from MERGE_HEAD so the
-- working tree reflects the PR branch state, not the merged state.
-- This ensures diffs match GitHub (PR changes only, no base-only changes).
local function checkout_pr_files_from_merge_head(merge_base, callback)
  if not merge_base then
    callback()
    return
  end
  local diff_cmd = string.format("git diff --name-only --diff-filter=AM %s MERGE_HEAD", merge_base)
  vim.fn.jobstart(diff_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local pr_files = {}
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(pr_files, line)
          end
        end
      end
      vim.schedule(function()
        if #pr_files == 0 then
          callback()
          return
        end
        local files_str = table.concat(vim.tbl_map(vim.fn.shellescape, pr_files), " ")
        vim.fn.jobstart("git checkout MERGE_HEAD -- " .. files_str, {
          on_exit = function()
            vim.schedule(callback)
          end,
        })
      end)
    end,
  })
end

local function do_merge(cmd, callback)
  local stderr_lines = {}
  vim.fn.jobstart(cmd, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(stderr_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        debug_log(string.format("Debug: Merge exit code = %d", code))
        local status = vim.fn.system("git status --porcelain")
        local has_conflicts = status:match("UU ") or status:match("AA ") or status:match("DD ")

        if code == 0 or has_conflicts then
          -- Compute merge_base before unstaging (MERGE_HEAD cleared by git reset)
          local merge_base = compute_merge_base()

          -- Checkout all added/modified PR files from MERGE_HEAD so working tree
          -- reflects the PR branch state (not the merged state with base changes)
          checkout_pr_files_from_merge_head(merge_base, function()
            M._unstage_all(function(ok, err)
              callback(ok, err, merge_base)
            end)
          end)
        else
          local git_error = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or "unknown error"
          vim.fn.jobstart("git merge --abort", {
            on_exit = function()
              vim.schedule(function()
                callback(false, "Merge failed: " .. git_error)
              end)
            end,
          })
        end
      end)
    end,
  })
end

function M.soft_merge(source_branch, head_repo_owner, head_repo_url, callback)
  -- If head_repo_owner is provided, setup fork remote
  if head_repo_owner and head_repo_url then
    M.add_fork_remote(head_repo_owner, head_repo_url, function(remote)
      local remote_source = remote .. "/" .. source_branch
      local cmd = string.format("git merge --no-commit --no-ff %s", vim.fn.shellescape(remote_source))
      debug_log(string.format("Debug: Merging %s", remote_source))
      do_merge(cmd, callback)
    end)
  else
    -- Fallback to origin if no owner specified
    local remote_source = "origin/" .. source_branch
    local cmd = string.format("git merge --no-commit --no-ff %s", vim.fn.shellescape(remote_source))
    debug_log(string.format("Debug: Merging %s", remote_source))
    do_merge(cmd, callback)
  end
end

function M._unstage_all(callback)
  vim.fn.jobstart("git reset HEAD", {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to unstage changes")
        end
      end)
    end,
  })
end

function M.get_modified_files_with_lines(callback)
  local merge_base = vim.g.pr_review_merge_base
  local base_ref = merge_base and merge_base or "HEAD"
  local result = vim.fn.system("git diff --name-status " .. base_ref)
  vim.schedule(function()
    debug_log(string.format("Debug: git diff output (first 200 chars): %s", result:sub(1, 200)))
  end)

  if vim.v.shell_error ~= 0 then
    callback({})
    return
  end

  local files = {}
  for line in result:gmatch("[^\r\n]+") do
    local status, path = line:match("^(%S+)%s+(.+)$")
    if status and path then
      table.insert(files, { path = path, status = status, line = nil })
    end
  end

  vim.schedule(function()
    debug_log(string.format("Debug: Found %d files", #files))
  end)

  local untracked = vim.fn.system("git ls-files --others --exclude-standard")
  if vim.v.shell_error == 0 then
    for path in untracked:gmatch("[^\r\n]+") do
      if path and path ~= "" then
        table.insert(files, { path = path, status = "?", line = 1 })
      end
    end
  end

  if #files == 0 then
    callback({})
    return
  end

  local pending = #files
  for i, file in ipairs(files) do
    if file.status ~= "D" and file.status ~= "?" then
      local diff_cmd = string.format("git diff --unified=0 %s -- %s", base_ref, vim.fn.shellescape(file.path))
      vim.fn.jobstart(diff_cmd, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          if data then
            for _, diff_line in ipairs(data) do
              local line_num = diff_line:match("^@@%s+%-%d+[,%d]*%s+%+(%d+)")
              if line_num then
                files[i].line = tonumber(line_num)
                break
              end
            end
          end
        end,
        on_exit = function()
          pending = pending - 1
          if pending == 0 then
            vim.schedule(function()
              callback(files)
            end)
          end
        end,
      })
    else
      files[i].line = 1
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          callback(files)
        end)
      end
    end
  end
end

function M.cleanup_review(review_branch, target_branch, callback)
  local files = vim.g.pr_review_modified_files or {}

  local function do_checkout_and_delete()
    vim.fn.jobstart("git checkout " .. vim.fn.shellescape(target_branch), {
      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 then
            callback(false, "Failed to checkout " .. target_branch)
            return
          end

          vim.fn.jobstart("git branch -D " .. vim.fn.shellescape(review_branch), {
            on_exit = function(_, del_code)
              vim.schedule(function()
                if del_code == 0 then
                  vim.g.pr_review_modified_files = nil
                  callback(true, nil)
                else
                  callback(false, "Failed to delete review branch")
                end
              end)
            end,
          })
        end)
      end,
    })
  end

  if #files == 0 then
    do_checkout_and_delete()
    return
  end

  local modified_paths = {}
  local new_paths = {}

  for _, file in ipairs(files) do
    if file.status == "A" or file.status == "?" then
      table.insert(new_paths, vim.fn.shellescape(file.path))
    else
      table.insert(modified_paths, vim.fn.shellescape(file.path))
    end
  end

  local function clean_new_files(next_callback)
    if #new_paths == 0 then
      next_callback()
      return
    end
    local pending = #new_paths
    for _, path in ipairs(new_paths) do
      -- Remove surrounding quotes from shellescape before passing to delete()
      local clean_path = path:gsub("^'", ""):gsub("'$", "")
      -- Use vim.fn.delete for cross-platform compatibility (works on Windows too)
      pcall(vim.fn.delete, clean_path, "rf")
      pending = pending - 1
      if pending == 0 then
        vim.schedule(next_callback)
      end
    end
  end

  local function restore_modified(next_callback)
    if #modified_paths == 0 then
      next_callback()
      return
    end
    local cmd = "git checkout -- " .. table.concat(modified_paths, " ")
    vim.fn.jobstart(cmd, {
      on_exit = function()
        vim.schedule(next_callback)
      end,
    })
  end

  restore_modified(function()
    clean_new_files(function()
      do_checkout_and_delete()
    end)
  end)
end

return M
