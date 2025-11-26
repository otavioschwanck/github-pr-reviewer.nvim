if vim.g.loaded_pr_reviewer then
  return
end
vim.g.loaded_pr_reviewer = true

vim.api.nvim_create_user_command("PRReview", function()
  require("pr-reviewer").review_pr()
end, { desc = "Select and review a GitHub PR" })

vim.api.nvim_create_user_command("PRReviewCleanup", function()
  require("pr-reviewer").cleanup_review_branch()
end, { desc = "Cleanup review branch and return to previous branch" })
