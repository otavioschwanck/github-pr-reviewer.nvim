local M = {}

M._comments_cache = {}
M._viewed_prs = {}

function M.list_open_prs()
  local result = vim.fn.system("gh pr list --state open --json number,title,headRefName,baseRefName,author")

  if vim.v.shell_error ~= 0 then
    return nil, "Failed to fetch PRs. Make sure 'gh' CLI is installed and authenticated."
  end

  local ok, prs = pcall(vim.fn.json_decode, result)
  if not ok or not prs then
    return nil, "Failed to parse PR data"
  end

  local formatted = {}
  for _, pr in ipairs(prs) do
    table.insert(formatted, {
      number = pr.number,
      title = pr.title,
      head_branch = pr.headRefName,
      base_branch = pr.baseRefName,
      author = pr.author and pr.author.login or "unknown",
    })
  end

  return formatted, nil
end

function M.list_review_requests(callback)
  local cmd = "gh pr list --search 'is:open review-requested:@me' --json number,title,headRefName,baseRefName,author,updatedAt,additions,deletions"

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, prs = pcall(vim.fn.json_decode, json_str)
      if not ok or not prs then
        vim.schedule(function()
          callback(nil, "Failed to parse PR data")
        end)
        return
      end

      -- Fetch viewed status for each PR
      local formatted = {}
      local pending = #prs

      if pending == 0 then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      for _, pr in ipairs(prs) do
        local viewed_cmd = string.format(
          "gh pr view %d --json files --jq '[.files[].viewerViewedState] | all(. == \"VIEWED\")'",
          pr.number
        )

        vim.fn.jobstart(viewed_cmd, {
          stdout_buffered = true,
          on_stdout = function(_, viewed_data)
            local is_viewed = false
            if viewed_data and viewed_data[1] then
              is_viewed = viewed_data[1] == "true"
            end

            table.insert(formatted, {
              number = pr.number,
              title = pr.title,
              head_branch = pr.headRefName,
              base_branch = pr.baseRefName,
              author = pr.author and pr.author.login or "unknown",
              updated_at = pr.updatedAt,
              additions = pr.additions or 0,
              deletions = pr.deletions or 0,
              viewed = is_viewed,
            })

            pending = pending - 1
            if pending == 0 then
              -- Sort by viewed status (unviewed first) then by number
              table.sort(formatted, function(a, b)
                if a.viewed ~= b.viewed then
                  return not a.viewed
                end
                return a.number > b.number
              end)

              vim.schedule(function()
                callback(formatted, nil)
              end)
            end
          end,
          on_exit = function(_, code)
            if code ~= 0 then
              pending = pending - 1
              table.insert(formatted, {
                number = pr.number,
                title = pr.title,
                head_branch = pr.headRefName,
                base_branch = pr.baseRefName,
                author = pr.author and pr.author.login or "unknown",
                updated_at = pr.updatedAt,
                additions = pr.additions or 0,
                deletions = pr.deletions or 0,
                viewed = false,
              })

              if pending == 0 then
                table.sort(formatted, function(a, b)
                  if a.viewed ~= b.viewed then
                    return not a.viewed
                  end
                  return a.number > b.number
                end)

                vim.schedule(function()
                  callback(formatted, nil)
                end)
              end
            end
          end,
        })
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

function M.mark_pr_as_viewed(pr_number, callback)
  -- Mark as viewed locally first (hides from list in this session)
  M._viewed_prs[pr_number] = true

  -- Also mark files as viewed on GitHub
  local cmd = string.format("gh pr view %d --json files --jq '.files[].path'", pr_number)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 then
        vim.schedule(function()
          callback(true, nil)
        end)
        return
      end

      local files = {}
      for _, file in ipairs(data) do
        if file and file ~= "" then
          table.insert(files, file)
        end
      end

      if #files == 0 then
        vim.schedule(function()
          callback(true, nil)
        end)
        return
      end

      local pending = #files

      for _, file in ipairs(files) do
        local view_cmd = string.format(
          "gh api repos/{owner}/{repo}/pulls/%d/viewed -X PUT -f path=%s 2>/dev/null || true",
          pr_number,
          vim.fn.shellescape(file)
        )

        vim.fn.jobstart(view_cmd, {
          on_exit = function()
            pending = pending - 1
            if pending == 0 then
              vim.schedule(function()
                callback(true, nil)
              end)
            end
          end,
        })
      end
    end,
    on_stderr = function()
      vim.schedule(function()
        callback(true, nil)
      end)
    end,
  })
end

function M.clear_viewed_prs()
  M._viewed_prs = {}
end

function M.get_pr_info(pr_number, callback)
  local cmd = string.format(
    "gh pr view %d --json number,title,author,state,additions,deletions,changedFiles,reviews,comments,headRefName,baseRefName,createdAt,updatedAt,mergeable,reviewDecision",
    pr_number
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback(nil, "Failed to fetch PR info")
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, info = pcall(vim.fn.json_decode, json_str)
      if not ok or not info then
        vim.schedule(function()
          callback(nil, "Failed to parse PR info")
        end)
        return
      end

      local review_counts = {
        approved = 0,
        changes_requested = 0,
        commented = 0,
        pending = 0,
      }

      local reviewers = {
        approved = {},
        changes_requested = {},
      }

      if info.reviews then
        for _, review in ipairs(info.reviews) do
          local state = review.state:lower()
          local reviewer = review.author and review.author.login or "unknown"
          if state == "approved" then
            review_counts.approved = review_counts.approved + 1
            if not vim.tbl_contains(reviewers.approved, reviewer) then
              table.insert(reviewers.approved, reviewer)
            end
          elseif state == "changes_requested" then
            review_counts.changes_requested = review_counts.changes_requested + 1
            if not vim.tbl_contains(reviewers.changes_requested, reviewer) then
              table.insert(reviewers.changes_requested, reviewer)
            end
          elseif state == "commented" then
            review_counts.commented = review_counts.commented + 1
          elseif state == "pending" then
            review_counts.pending = review_counts.pending + 1
          end
        end
      end

      vim.schedule(function()
        callback({
          number = info.number,
          title = info.title,
          author = info.author and info.author.login or "unknown",
          state = info.state,
          head_branch = info.headRefName,
          base_branch = info.baseRefName,
          additions = info.additions or 0,
          deletions = info.deletions or 0,
          changed_files = info.changedFiles or 0,
          comments_count = info.comments and #info.comments or 0,
          reviews = review_counts,
          reviewers = reviewers,
          review_decision = info.reviewDecision,
          mergeable = info.mergeable,
          created_at = info.createdAt,
          updated_at = info.updatedAt,
        }, nil)
      end)
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

function M.fetch_pr_comments(pr_number, callback)
  if M._comments_cache[pr_number] then
    callback(M._comments_cache[pr_number], nil)
    return
  end

  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/%d/comments --jq '.[] | {id: .id, path: .path, line: (.line // .original_line), body: .body, user: .user.login, created_at: .created_at, in_reply_to_id: .in_reply_to_id}'",
    pr_number
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 or (data[1] == "" and #data == 1) then
        M._comments_cache[pr_number] = {}
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      local comments = {}
      for _, line in ipairs(data) do
        if line and line ~= "" then
          local ok, comment = pcall(vim.fn.json_decode, line)
          if ok and comment then
            table.insert(comments, {
              id = comment.id,
              path = comment.path,
              line = comment.line,
              body = comment.body,
              user = comment.user,
              created_at = comment.created_at,
              in_reply_to_id = comment.in_reply_to_id,
            })
          end
        end
      end

      M._comments_cache[pr_number] = comments
      vim.schedule(function()
        callback(comments, nil)
      end)
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

function M.get_comments_for_file(pr_number, file_path, callback)
  M.fetch_pr_comments(pr_number, function(comments, err)
    if err then
      callback(nil, err)
      return
    end

    local file_comments = {}
    for _, comment in ipairs(comments or {}) do
      if comment.path == file_path then
        table.insert(file_comments, comment)
      end
    end

    callback(file_comments, nil)
  end)
end

function M.clear_cache()
  M._comments_cache = {}
end

function M.get_current_user(callback)
  vim.fn.jobstart("gh api user --jq '.login'", {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(data[1]:gsub("%s+", ""), nil)
        end)
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback(nil, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

function M.approve_pr(pr_number, body, callback)
  local cmd
  if body and body ~= "" then
    cmd = string.format("gh pr review %d --approve --body %s", pr_number, vim.fn.shellescape(body))
  else
    cmd = string.format("gh pr review %d --approve", pr_number)
  end

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to approve PR")
        end
      end)
    end,
  })
end

function M.request_changes(pr_number, body, callback)
  if not body or body == "" then
    callback(false, "Body is required when requesting changes")
    return
  end

  local cmd = string.format("gh pr review %d --request-changes --body %s", pr_number, vim.fn.shellescape(body))

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to request changes")
        end
      end)
    end,
  })
end

function M.add_pr_comment(pr_number, body, callback)
  local cmd = string.format("gh pr comment %d --body %s", pr_number, vim.fn.shellescape(body))

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to add comment")
        end
      end)
    end,
  })
end

function M.add_review_comment(pr_number, path, line, body, callback)
  local get_head_cmd = string.format("gh pr view %d --json headRefOid --jq '.headRefOid'", pr_number)

  vim.fn.jobstart(get_head_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback(false, "Failed to get PR head commit")
        end)
        return
      end

      local commit_id = data[1]:gsub("%s+", "")

      local json_body = vim.fn.json_encode({
        body = body,
        path = path,
        line = line,
        side = "RIGHT",
        commit_id = commit_id,
      })

      local cmd = string.format(
        "gh api repos/{owner}/{repo}/pulls/%d/comments -X POST --input -",
        pr_number
      )

      local stderr_output = {}
      local job_id = vim.fn.jobstart(cmd, {
        stderr_buffered = true,
        on_stderr = function(_, err_data)
          if err_data then
            stderr_output = err_data
          end
        end,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              M._comments_cache[pr_number] = nil
              callback(true, nil)
            else
              local err_msg = table.concat(stderr_output, "\n")
              callback(false, "Failed to add review comment: " .. err_msg)
            end
          end)
        end,
      })

      vim.fn.chansend(job_id, json_body)
      vim.fn.chanclose(job_id, "stdin")
    end,
  })
end

function M.reply_to_comment(pr_number, comment_id, body, callback)
  local json_body = vim.fn.json_encode({
    body = body,
    in_reply_to = comment_id,
  })

  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/%d/comments -X POST --input -",
    pr_number
  )

  local job_id = vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          callback(false, "Failed to reply to comment")
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, json_body)
  vim.fn.chanclose(job_id, "stdin")
end

function M.edit_comment(pr_number, comment_id, body, callback)
  local json_body = vim.fn.json_encode({
    body = body,
  })

  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d -X PATCH --input -",
    comment_id
  )

  local job_id = vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          callback(false, "Failed to edit comment")
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, json_body)
  vim.fn.chanclose(job_id, "stdin")
end

function M.delete_comment(pr_number, comment_id, callback)
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d -X DELETE",
    comment_id
  )

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          callback(false, "Failed to delete comment")
        end
      end)
    end,
  })
end

return M
