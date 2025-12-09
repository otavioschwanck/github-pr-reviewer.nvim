local M = {}

M._comments_cache = {}

-- Debug logging helper
local function debug_log(msg)
  local pr_reviewer = require("github-pr-reviewer")
  if pr_reviewer.config.debug then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

function M.list_open_prs()
  local result = vim.fn.system("gh pr list --state open --json number,title,headRefName,baseRefName,author,headRepository,headRepositoryOwner,isCrossRepository,labels,headRefOid")

  if vim.v.shell_error ~= 0 then
    return nil, "Failed to fetch PRs. Make sure 'gh' CLI is installed and authenticated."
  end

  local ok, prs = pcall(vim.fn.json_decode, result)
  if not ok or not prs then
    return nil, "Failed to parse PR data"
  end

  local formatted = {}
  for _, pr in ipairs(prs) do
    -- For fork PRs, use the full reference including owner
    local head_branch = pr.headRefName
    local head_label = pr.headRepositoryOwner and
                      (pr.headRepositoryOwner.login .. ":" .. pr.headRefName) or
                      pr.headRefName

    -- Debug: print what we're getting
    debug_log(string.format("PR #%d: headRefName=%s, owner=%s, repo=%s, url=%s",
                             pr.number,
                             pr.headRefName or "nil",
                             (pr.headRepositoryOwner and pr.headRepositoryOwner.login) or "nil",
                             pr.headRepository and pr.headRepository.name or "nil",
                             pr.headRepository and pr.headRepository.url or "nil"))

    -- Check if it's a cross-repository PR (fork)
    local is_fork = pr.isCrossRepository or false
    local head_repo_owner = nil
    local repo_url = nil

    if is_fork and pr.headRepositoryOwner and pr.headRepository then
      head_repo_owner = pr.headRepositoryOwner.login
      repo_url = string.format("https://github.com/%s/%s.git",
                              head_repo_owner,
                              pr.headRepository.name)
    end

    table.insert(formatted, {
      number = pr.number,
      title = pr.title,
      head_branch = head_branch,
      head_label = head_label,
      base_branch = pr.baseRefName,
      author = pr.author and pr.author.login or "unknown",
      head_repo_owner = is_fork and head_repo_owner or nil,
      head_repo_url = is_fork and repo_url or nil,
    })
  end

  return formatted, nil
end

-- Get detailed PR info including correct branch for forks
function M.get_pr_details(pr_number, callback)
  local cmd = string.format("gh pr view %d --json headRefName,headRepositoryOwner", pr_number)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback(nil, "Failed to fetch PR details")
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, pr = pcall(vim.fn.json_decode, json_str)
      if not ok or not pr then
        vim.schedule(function()
          callback(nil, "Failed to parse PR details")
        end)
        return
      end

      vim.schedule(function()
        local head_branch = pr.headRefName
        local head_label = pr.headRepositoryOwner and
                          (pr.headRepositoryOwner.login .. ":" .. pr.headRefName) or
                          pr.headRefName

        debug_log(string.format("Debug: PR #%d actual branch = %s", pr_number, head_branch))

        callback({
          head_branch = head_branch,
          head_label = head_label,
        }, nil)
      end)
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          callback(nil, "gh pr view failed")
        end)
      end
    end,
  })
end

function M.list_review_requests(callback)
  local cmd = "gh pr list --search 'is:open review-requested:@me' --json number,title,headRefName,baseRefName,author,updatedAt,additions,deletions,headRepositoryOwner,headRepository,isCrossRepository"

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

            -- For fork PRs, use the full reference including owner
            local head_branch = pr.headRefName
            local head_label = pr.headRepositoryOwner and
                              (pr.headRepositoryOwner.login .. ":" .. pr.headRefName) or
                              pr.headRefName

            -- Check if it's a cross-repository PR (fork)
            local is_fork = pr.isCrossRepository or false
            local head_repo_owner = nil
            local repo_url = nil

            if is_fork and pr.headRepositoryOwner and pr.headRepository then
              head_repo_owner = pr.headRepositoryOwner.login
              repo_url = string.format("https://github.com/%s/%s.git",
                                      head_repo_owner,
                                      pr.headRepository.name)
            end

            table.insert(formatted, {
              number = pr.number,
              title = pr.title,
              head_branch = head_branch,
              head_label = head_label,
              base_branch = pr.baseRefName,
              author = pr.author and pr.author.login or "unknown",
              updated_at = pr.updatedAt,
              additions = pr.additions or 0,
              deletions = pr.deletions or 0,
              viewed = is_viewed,
              head_repo_owner = is_fork and head_repo_owner or nil,
              head_repo_url = is_fork and repo_url or nil,
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


function M.get_pr_info(pr_number, callback)
  local cmd = string.format(
    "gh pr view %d --json number,title,body,author,state,additions,deletions,changedFiles,reviews,comments,headRefName,baseRefName,createdAt,updatedAt,mergeable,reviewDecision",
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
          body = info.body or "",
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

function M.get_pr_checks(pr_number, callback)
  local cmd = string.format("gh pr checks %d --json name,state,conclusion,detailsUrl", pr_number)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or not data[1] or data[1] == "" then
        vim.schedule(function()
          callback({}, nil) -- Return empty array if no checks
        end)
        return
      end

      local json_str = table.concat(data, "")
      local ok, checks = pcall(vim.fn.json_decode, json_str)
      if not ok or not checks then
        vim.schedule(function()
          callback({}, nil) -- Return empty array on parse error
        end)
        return
      end

      vim.schedule(function()
        callback(checks, nil)
      end)
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.schedule(function()
          callback({}, table.concat(data, "\n"))
        end)
      end
    end,
  })
end

-- Fetch global/issue comments (not line-specific comments)
function M.fetch_pr_global_comments(pr_number, callback)
  -- First, fetch issue comments
  local cmd_comments = string.format(
    "gh api repos/{owner}/{repo}/issues/%d/comments --jq '.[] | {id: .id, body: .body, user: .user.login, created_at: .created_at, type: \"comment\"}'",
    pr_number
  )

  -- Also fetch PR reviews (approvals, rejections, etc)
  local cmd_reviews = string.format(
    "gh api repos/{owner}/{repo}/pulls/%d/reviews --jq '.[] | {id: .id, body: .body, user: .user.login, created_at: .submitted_at, state: .state, type: \"review\"}'",
    pr_number
  )

  local all_comments = {}
  local completed = 0
  local total = 2

  local function check_complete()
    completed = completed + 1
    if completed == total then
      -- Sort by date
      table.sort(all_comments, function(a, b)
        return a.created_at < b.created_at
      end)

      vim.schedule(function()
        callback(all_comments, nil)
      end)
    end
  end

  -- Fetch issue comments
  vim.fn.jobstart(cmd_comments, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 and not (data[1] == "" and #data == 1) then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            local ok, comment = pcall(vim.fn.json_decode, line)
            if ok and comment then
              table.insert(all_comments, {
                id = comment.id,
                body = comment.body,
                user = comment.user,
                created_at = comment.created_at,
                type = "comment",
              })
            end
          end
        end
      end
    end,
    on_exit = function()
      check_complete()
    end,
  })

  -- Fetch PR reviews
  vim.fn.jobstart(cmd_reviews, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 and not (data[1] == "" and #data == 1) then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            local ok, review = pcall(vim.fn.json_decode, line)
            if ok and review then
              -- Format state nicely
              local state_text = ""
              if review.state == "APPROVED" then
                state_text = "✅ Approved this pull request"
              elseif review.state == "CHANGES_REQUESTED" then
                state_text = "❌ Requested changes"
              elseif review.state == "COMMENTED" then
                state_text = "💬 Reviewed"
              elseif review.state == "DISMISSED" then
                state_text = "🚫 Review dismissed"
              else
                state_text = review.state
              end

              -- Combine state and body
              local full_body = state_text
              if review.body and review.body ~= "" and review.body ~= vim.NIL then
                full_body = state_text .. "\n\n" .. review.body
              end

              table.insert(all_comments, {
                id = review.id,
                body = full_body,
                user = review.user,
                created_at = review.created_at or review.submitted_at,
                type = "review",
                state = review.state,
              })
            end
          end
        end
      end
    end,
    on_exit = function()
      check_complete()
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
            -- Ensure line is a number (handle vim.NIL from JSON null)
            local line_num = comment.line
            if line_num == vim.NIL or type(line_num) ~= "number" then
              line_num = nil
            end

            table.insert(comments, {
              id = comment.id,
              path = comment.path,
              line = line_num,
              body = comment.body,
              user = comment.user,
              created_at = comment.created_at,
              in_reply_to_id = comment.in_reply_to_id,
              reactions = {},
            })
          end
        end
      end

      -- Fetch reactions for all comments
      if #comments == 0 then
        M._comments_cache[pr_number] = comments
        vim.schedule(function()
          callback(comments, nil)
        end)
        return
      end

      local pending = #comments
      for _, comment in ipairs(comments) do
        M.get_comment_reactions(comment.id, function(reactions, err)
          if not err and reactions then
            comment.reactions = reactions
          end

          pending = pending - 1
          if pending == 0 then
            M._comments_cache[pr_number] = comments
            vim.schedule(function()
              callback(comments, nil)
            end)
          end
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

-- Submit a review with comments and event (APPROVE, REQUEST_CHANGES, or COMMENT)
function M.submit_review_with_comments(pr_number, event, body, comments, callback)
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

      -- Build comments array for API
      local api_comments = {}
      for _, comment in ipairs(comments) do
        if comment.line and type(comment.line) == "number" and comment.line > 0 then
          local api_comment = {
            path = comment.path,
            line = comment.line,
            body = comment.body,
          }

          -- Add start_line for multi-line comments
          if comment.start_line and comment.start_line ~= comment.line then
            api_comment.start_line = comment.start_line
            api_comment.start_side = "RIGHT"
          end

          table.insert(api_comments, api_comment)
        end
      end

      local review_body = {
        commit_id = commit_id,
        event = event,
        comments = api_comments
      }

      -- Add body if provided
      if body and body ~= "" then
        review_body.body = body
      end

      local review_json = vim.fn.json_encode(review_body)

      local cmd = string.format(
        "gh api repos/{owner}/{repo}/pulls/%d/reviews -X POST --input -",
        pr_number
      )

      local stderr_output = {}
      local job_id = vim.fn.jobstart(cmd, {
        stderr_buffered = true,
        on_stderr = function(_, err_data)
          if err_data then
            vim.list_extend(stderr_output, err_data)
          end
        end,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              M._comments_cache[pr_number] = nil
              callback(true, nil)
            else
              local err_msg = table.concat(stderr_output, "\n")
              callback(false, "Failed to submit review: " .. err_msg)
            end
          end)
        end,
      })

      vim.fn.chansend(job_id, review_json)
      vim.fn.chanclose(job_id, "stdin")
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

function M.add_review_comment(pr_number, path, line, body, callback, start_line)
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

      local comment_data = {
        body = body,
        path = path,
        line = line,
        side = "RIGHT",
        commit_id = commit_id,
      }

      -- For multi-line comments, add start_line and start_side
      if start_line and start_line ~= line then
        comment_data.start_line = start_line
        comment_data.start_side = "RIGHT"
      end

      local json_body = vim.fn.json_encode(comment_data)

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

-- Helper function to create a pending review with comments
local function create_pending_review_with_comments(pr_number, commit_id, comments, callback)
  vim.schedule(function()
    debug_log(string.format("Debug: Creating review with %d comments", #comments))
  end)

  local review_body = vim.fn.json_encode({
    commit_id = commit_id,
    body = "",  -- Empty body for the review itself
    comments = comments
  })

  vim.schedule(function()
    debug_log(string.format("Debug: Review body: %s", review_body:sub(1, 300)))
  end)

  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/%d/reviews -X POST --input -",
    pr_number
  )

  local stderr_output = {}
  local stdout_output = {}
  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, out_data)
      if out_data then
        vim.list_extend(stdout_output, out_data)
      end
    end,
    on_stderr = function(_, err_data)
      if err_data then
        vim.list_extend(stderr_output, err_data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          M._comments_cache[pr_number] = nil
          callback(true, nil)
        else
          local err_msg = table.concat(stderr_output, "\n")
          local out_msg = table.concat(stdout_output, "\n")
          debug_log(string.format("Debug: Create failed - Stdout: %s", out_msg))
          debug_log(string.format("Debug: Create failed - Stderr: %s", err_msg))
          callback(false, "Failed to create pending review: " .. err_msg)
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, review_body)
  vim.fn.chanclose(job_id, "stdin")
end

-- Add a pending review comment (part of a review draft)
-- This creates a single-comment review that can be submitted later
function M.add_pending_review_comment(pr_number, path, line, body, callback)
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

      -- First, check if there's a pending review (even if empty)
      local get_review_cmd = string.format(
        "gh api repos/{owner}/{repo}/pulls/%d/reviews --jq '.[] | select(.state == \"PENDING\") | .id' | head -n 1",
        pr_number
      )

      vim.fn.jobstart(get_review_cmd, {
        stdout_buffered = true,
        on_stdout = function(_, review_data)
          local review_id = nil
          if review_data and review_data[1] and review_data[1] ~= "" then
            review_id = tonumber((review_data[1]:gsub("%s+", "")))
          end

          if review_id then
            vim.schedule(function()
              debug_log(string.format("Debug: Found existing pending review ID: %d", review_id))
            end)

            -- Get existing comments from the pending review
            M.get_pending_review_comments(pr_number, function(existing_comments, err)
              vim.schedule(function()
                debug_log(string.format("Debug: Found %d existing pending comments", #(existing_comments or {})))
              end)

              -- Build the comments array with existing + new comment
              local all_comments = {}

              -- Add existing comments (only if they have a valid line number)
              for _, ec in ipairs(existing_comments or {}) do
                if ec.line and type(ec.line) == "number" and ec.line > 0 then
                  table.insert(all_comments, {
                    path = ec.path,
                    line = ec.line,
                    body = ec.body,
                  })
                end
              end

              -- Add the new comment
              table.insert(all_comments, {
                path = path,
                line = line,
                body = body,
              })

              vim.schedule(function()
                debug_log(string.format("Debug: Total comments to add: %d", #all_comments))
                debug_log(string.format("Debug: Deleting existing review ID: %d", review_id))
              end)

              -- Delete the existing pending review
              local delete_cmd = string.format(
                "gh api repos/{owner}/{repo}/pulls/%d/reviews/%d -X DELETE",
                pr_number,
                review_id
              )

              vim.fn.jobstart(delete_cmd, {
                on_exit = function(_, del_code)
                  vim.schedule(function()
                    debug_log(string.format("Debug: Delete exit code: %d", del_code))
                    if del_code == 0 then
                      -- Now create the new review with all comments
                      create_pending_review_with_comments(pr_number, commit_id, all_comments, callback)
                    else
                      callback(false, "Failed to delete existing pending review")
                    end
                  end)
                end,
              })
            end)
          else
            vim.schedule(function()
              debug_log("Debug: No existing pending review found")
            end)

            -- No existing review, just create new with the comment
            local all_comments = {
              {
                path = path,
                line = line,
                body = body,
              }
            }
            create_pending_review_with_comments(pr_number, commit_id, all_comments, callback)
          end
        end,
      })
    end,
  })
end

-- Get pending review comments
function M.get_pending_review_comments(pr_number, callback)
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/%d/reviews --jq '.[] | select(.state == \"PENDING\") | .id'",
    pr_number
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 or (data[1] == "" and #data == 1) then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      -- Parse all review IDs
      local review_ids = {}
      for _, line in ipairs(data) do
        local cleaned = line:gsub("%s+", "")
        if cleaned ~= "" then
          local id = tonumber(cleaned)
          if id then
            table.insert(review_ids, id)
          end
        end
      end

      if #review_ids == 0 then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      -- Collect comments from all pending reviews
      local all_comments = {}
      local pending_requests = #review_ids

      for _, review_id in ipairs(review_ids) do
        -- Get all fields to find the absolute line number
        local comments_cmd = string.format(
          "gh api repos/{owner}/{repo}/pulls/%d/reviews/%d/comments",
          pr_number,
          review_id
        )

        vim.fn.jobstart(comments_cmd, {
          stdout_buffered = true,
          on_stdout = function(_, comments_data)
            if comments_data and #comments_data > 0 then
              local json_str = table.concat(comments_data, "")
              local ok, comments_array = pcall(vim.fn.json_decode, json_str)

              if ok and comments_array then
                for _, comment in ipairs(comments_array) do
                  if comment and comment.path then
                    -- Try multiple fields to get the line number
                    -- Priority: line > original_line > start_line > position
                    local line_num = comment.line or comment.original_line or comment.start_line or comment.position

                    -- Ensure it's a valid number
                    if line_num == vim.NIL or type(line_num) ~= "number" then
                      line_num = nil
                    end

                    -- Debug: log all line-related fields
                    vim.schedule(function()
                      debug_log(string.format("Debug: Comment fields - line=%s, original_line=%s, start_line=%s, position=%s, original_position=%s",
                        tostring(comment.line),
                        tostring(comment.original_line),
                        tostring(comment.start_line),
                        tostring(comment.position),
                        tostring(comment.original_position)), vim.log.levels.INFO)
                    end)

                    table.insert(all_comments, {
                      id = comment.id,
                      path = comment.path,
                      line = line_num,
                      body = comment.body,
                      user = comment.user and comment.user.login or comment.user,
                      created_at = comment.created_at,
                      in_reply_to_id = comment.in_reply_to_id,
                      reactions = {},
                    })
                  end
                end
              end
            end

            pending_requests = pending_requests - 1
            if pending_requests == 0 then
              vim.schedule(function()
                callback(all_comments, nil)
              end)
            end
          end,
          on_exit = function(_, code)
            if code ~= 0 then
              pending_requests = pending_requests - 1
              if pending_requests == 0 then
                vim.schedule(function()
                  callback(all_comments, nil)
                end)
              end
            end
          end,
        })
      end
    end,
  })
end

-- Get reactions for a comment
function M.get_comment_reactions(comment_id, callback)
  -- PR review comments use /pulls/comments, not /issues/comments
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d/reactions --jq '.[] | {id: .id, content: .content, user: .user.login}'",
    comment_id
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 or (data[1] == "" and #data == 1) then
        vim.schedule(function()
          callback({}, nil)
        end)
        return
      end

      local reactions = {}
      for _, line in ipairs(data) do
        if line and line ~= "" then
          local ok, reaction = pcall(vim.fn.json_decode, line)
          if ok and reaction then
            table.insert(reactions, {
              id = reaction.id,
              content = reaction.content,
              user = reaction.user,
            })
          end
        end
      end

      vim.schedule(function()
        callback(reactions, nil)
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

-- Add a reaction to a comment
-- content can be: "+1", "-1", "laugh", "confused", "heart", "hooray", "rocket", "eyes"
function M.add_comment_reaction(comment_id, content, callback)
  local json_body = vim.fn.json_encode({
    content = content,
  })

  -- PR review comments use /pulls/comments, not /issues/comments
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d/reactions -X POST --input - -H 'Accept: application/vnd.github+json'",
    comment_id
  )

  local stderr_output = {}
  local stdout_output = {}
  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_output, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_output, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          local err_msg = table.concat(stderr_output, "\n")
          local out_msg = table.concat(stdout_output, "\n")
          local full_error = err_msg ~= "" and err_msg or out_msg
          callback(false, full_error ~= "" and full_error or "Failed to add reaction (unknown error)")
        end
      end)
    end,
  })

  vim.fn.chansend(job_id, json_body)
  vim.fn.chanclose(job_id, "stdin")
end

-- Remove a reaction from a comment
function M.remove_comment_reaction(comment_id, reaction_id, callback)
  -- PR review comments use /pulls/comments, not /issues/comments
  local cmd = string.format(
    "gh api repos/{owner}/{repo}/pulls/comments/%d/reactions/%d -X DELETE -H 'Accept: application/vnd.github+json'",
    comment_id,
    reaction_id
  )

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          callback(true, nil)
        else
          callback(false, "Failed to remove reaction")
        end
      end)
    end,
  })
end

return M
