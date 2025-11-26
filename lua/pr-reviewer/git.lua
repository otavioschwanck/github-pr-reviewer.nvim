local M = {}

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
          callback(false, "git fetch failed")
        end
      end)
    end,
  })
end

function M.create_review_branch(branch_name, base_branch, callback)
  local existing = vim.fn.system("git branch --list " .. branch_name):gsub("%s+", "")
  if existing ~= "" then
    vim.fn.jobstart("git branch -D " .. branch_name, {
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
  local cmd = string.format("git checkout -b %s %s", branch_name, remote_base)

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

function M.soft_merge(source_branch, callback)
  local remote_source = "origin/" .. source_branch
  local cmd = string.format("git merge --no-commit --no-ff %s", remote_source)

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._unstage_all(callback)
        else
          vim.fn.jobstart("git merge --abort", {
            on_exit = function()
              vim.schedule(function()
                callback(false, "Merge failed (conflicts?). Aborted.")
              end)
            end,
          })
        end
      end)
    end,
  })
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
  local result = vim.fn.system("git diff --name-status")
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
      local diff_cmd = string.format("git diff --unified=0 -- %s", vim.fn.shellescape(file.path))
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
    vim.fn.jobstart("git checkout " .. target_branch, {
      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 then
            callback(false, "Failed to checkout " .. target_branch)
            return
          end

          vim.fn.jobstart("git branch -D " .. review_branch, {
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
      vim.fn.jobstart("rm -rf " .. path, {
        on_exit = function()
          pending = pending - 1
          if pending == 0 then
            vim.schedule(next_callback)
          end
        end,
      })
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
