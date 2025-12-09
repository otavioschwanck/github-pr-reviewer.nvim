# GitHub PR Reviewer for Neovim

A powerful Neovim plugin for reviewing GitHub Pull Requests directly in your editor. Review PRs with the full power of your development environment - LSP, navigation, favorite files, and all your familiar tools.

![demo](https://i.imgur.com/WsYYVQy.gif)
![menu](https://i.imgur.com/77Tc8HS.png)

## Disclaimer

It is a experimental project and may contain bugs. Use at your own risk.

## Why This Plugin?

**Traditional PR review tools force you into a limited web interface.** This plugin brings PR reviews into your Neovim environment where you have:

- 🚀 **Full LSP support** - Jump to definitions, find references, see type information while reviewing
- 📁 **Your favorite navigation tools** - Use arrow.nvim, harpoon, telescope, or any file navigation plugin
- 🔍 **See the full codebase** - Not limited to just the changed lines - explore the entire context
- ⚡ **Efficient workflows** - Built-in keybindings for navigation and smart change tracking
- 💬 **Comprehensive comment management** - Add, edit, delete, reply to comments with a great UX
- 📝 **Pending comments** - Draft comments locally and submit them all together when you're ready
- 🎯 **Context-aware** - View conversation threads, see file previews, and navigate with ease

**Review faster, review better.** Use the same environment where you write code to review it.

## Features

### Core Review Features
- ✅ **Review PRs locally** - Checkout PR changes as unstaged modifications
- ✅ **Session persistence** - Resume reviews after restarting Neovim
- ✅ **Fork PR support** - Automatically handles PRs from forks
- ✅ **Review requests** - List PRs where you're requested as reviewer
- ✅ **Review buffer** - Interactive file browser with foldable directories
- ✅ **Split diff view** - Toggle between unified and split (side-by-side) diff view
- ✅ **Change tracking** - See your progress with floating indicators (toggle on/off)
- ✅ **Inline diff** - Built-in diff visualization (no gitsigns required)

### Comment Management
- 💬 **View comments inline** - PR comments appear as virtual text with reactions
- 💬 **Add line comments** - Comment on specific lines with context
- 💬 **Pending comments** - Draft comments locally, submit all at once
- 💬 **List all comments** - Browse all PR comments (posted + pending) with file preview
- 💬 **Reply to comments** - Continue conversation threads
- 💬 **Edit/Delete** - Modify or remove your comments
- 💬 **Comment threads** - View full conversation context when replying
- 👍 **Emoji reactions** - Add/remove GitHub reactions (👍 👎 😄 🎉 😕 ❤️ 🚀 👀) to comments

### Review Actions
- ✓ **Approve PRs** - Submit approval with optional comment
- ✗ **Request changes** - Request changes with explanation
- 📊 **PR Info** - View stats, reviews, merge status, CI checks
- 🌐 **Open in browser** - Quick access to PR on GitHub
- 🎨 **Interactive menu** - `:PR` command for quick access to all features

### UI & Pickers
- 🔍 **Multiple picker support** - Native `vim.ui.select`, Telescope, or fzf-lua
- 🔍 **File previews** - See file content and context when selecting comments
- 🎨 **Smart formatting** - Shows file paths, authors, status, and comment previews
- ⌨️ **Keyboard-driven** - Efficient navigation with configurable keybindings

## Requirements

- Neovim >= 0.11.0
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Git
- Optional: [bat](https://github.com/sharkdp/bat) for syntax-highlighted previews in fzf-lua

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "otavioschwanck/github-pr-reviewer.nvim",
  opts = {
    -- options here
  },
  keys = {
    { "<leader>p", "<cmd>PRReviewMenu<cr>",    desc = "PR Review Menu" },
    { "<leader>p", ":<C-u>'<,'>PRSuggestChange<CR>", desc = "Suggest change", mode = "v" }
  }
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "otavioschwanck/github-pr-reviewer.nvim",
  config = function()
    require("github-pr-reviewer").setup()

    -- Recommended keymaps
    vim.keymap.set("n", "<leader>p", "<cmd>PRReviewMenu<cr>", { desc = "PR Review Menu" })
    vim.keymap.set("v", "<leader>p", ":<C-u>'<,'>PRSuggestChange<CR>", { desc = "Suggest change" })
  end
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'otavioschwanck/github-pr-reviewer.nvim'

" In your init.vim or init.lua
lua << EOF
  require("github-pr-reviewer").setup()

  -- Recommended keymaps
  vim.keymap.set("n", "<leader>p", "<cmd>PRReviewMenu<cr>", { desc = "PR Review Menu" })
  vim.keymap.set("v", "<leader>p", ":<C-u>'<,'>PRSuggestChange<CR>", { desc = "Suggest change" })
EOF
```

## Configuration

```lua
require("github-pr-reviewer").setup({
  -- Prefix for review branches (default: "reviewing_")
  branch_prefix = "reviewing_",

  -- Picker for PR selection: "native", "fzf-lua", or "telescope"
  picker = "native",

  -- Open the first file automatically
  open_files_on_review = true,

  -- Show PR comments as virtual text in buffers
  show_comments = true,

  -- Show icons/emojis in UI (set to false for a text-only interface)
  show_icons = true,

  -- Show inline diff in buffers (old lines as virtual text above changes)
  show_inline_diff = true,

  -- Show floating windows with PR info, stats, and keymaps
  show_floats = true,

  -- Key to mark file as viewed and go to next file (only works in review mode)
  mark_as_viewed_key = "<CR>",

  -- Key to toggle between unified and split diff view (only works in review mode)
  diff_view_toggle_key = "<C-v>",

  -- Key to toggle floating windows visibility (only works in review mode)
  toggle_floats_key = "<C-r>",

  -- Key to jump to next hunk (only works in review mode)
  next_hunk_key = "<C-j>",

  -- Key to jump to previous hunk (only works in review mode)
  prev_hunk_key = "<C-k>",

  -- Key to go to next modified file (only works in review mode)
  next_file_key = "<C-l>",

  -- Key to go to previous modified file (only works in review mode)
  prev_file_key = "<C-h>",
})
```

## Commands

### Main Menu

| Command | Description |
|---------|-------------|
| `:PR` or `:PRReviewMenu` | Show interactive menu with all available actions |

### Review Workflow

| Command | Description |
|---------|-------------|
| `:PRReview` | Select and start reviewing a PR |
| `:PRListReviewRequests` | List PRs where you are requested as reviewer |
| `:PRReviewCleanup` | End review, clean up changes, return to previous branch |
| `:PRInfo` | Show PR information (stats, reviews, merge status) |
| `:PROpen` | Open PR in browser |
| `:PRLoadLastSession` | Restore last PR review session (after restarting Neovim) |
| `:PRReviewBuffer` | Toggle review buffer (interactive file browser) |

### Comments

| Command | Description |
|---------|-------------|
| `:PRReviewComment` | Show comments at cursor line (also shows on `CursorHold`) |
| `:PRLineComment` | Add a review comment on the current line |
| `:PRPendingComment` | Add a pending comment (submitted with approval/rejection) |
| `:PRListPendingComments` | List all pending comments and navigate to selected one |
| `:PRListAllComments` | List ALL comments (pending + posted) with file preview |
| `:PRReply` | Reply to a comment on the current line |
| `:PREditComment` | Edit your comment (works for both pending and posted) |
| `:PRDeleteComment` | Delete your comment on the current line |
| `:PRToggleReaction` | Toggle emoji reaction on a comment at the current line |

### Review Actions

| Command | Description |
|---------|-------------|
| `:PRApprove` | Approve the PR (submits pending comments if any) |
| `:PRRequestChanges` | Request changes on the PR (submits pending comments if any) |
| `:PRComment` | Add a general comment to the PR |

## Quick Start

### The `:PR` Menu - Your Review Command Center

**The easiest way to use this plugin is through the interactive `:PR` menu.** Simply type `:PR` and use single-key shortcuts to access all features:

```vim
:PR              " Open the interactive menu
```

From the menu, press:
- `r` - Start reviewing a PR (list all open PRs)
- `l` - List PRs where you're requested as reviewer
- `b` - Toggle review buffer (see all changed files)
- `i` - Show PR info (stats, reviews, CI checks)
- `o` - Open PR in browser
- `R` - Toggle emoji reaction on comment at cursor
- `a` - **Approve** the PR
- `x` - **Request changes** on the PR
- `c` - Cleanup and exit review mode

**No need to memorize commands!** The menu adapts based on whether you're in review mode or not, showing only relevant options.

### Quick Review Workflow (Using the Menu)

1. **Open the menu and start a review:**
   ```vim
   :PR
   " Press 'r' to review a PR, or 'l' to see review requests
   ```

2. **Browse changed files:**
   ```vim
   :PR
   " Press 'b' to open the review buffer
   " Press <CR> on a file to open it
   " Press <CR> on a directory to collapse/expand it
   ```

3. **Navigate with full LSP support:**
   - Use `gd` to jump to definitions
   - Use `gr` to find references
   - Use `K` to see documentation
   - Use Telescope/fzf to search across the codebase
   - **You're not limited to changed lines** - explore the full context!

4. **Add pending comments as you review:**
   - Use `:PRPendingComment` to draft comments
   - All pending comments are saved locally
   - You can continue reviewing multiple files

5. **Finish the review:**
   ```vim
   :PR
   " Press 'a' to approve (submits all pending comments)
   " Or press 'x' to request changes
   " Then press 'c' to cleanup and return to your branch
   ```

### Alternative: Direct Commands

While the `:PR` menu is recommended, you can also use direct commands if you prefer:

- `:PRReview` - Start reviewing a PR
- `:PRReviewBuffer` - Toggle review buffer
- `:PRApprove` - Approve the PR
- `:PRReviewCleanup` - Exit review mode

See the [Commands](#commands) section for the full list.

## Usage Guide

### Starting a Review

1. Make sure you have no uncommitted changes (the plugin will warn you)
2. Run `:PRListReviewRequests` to see PRs requesting your review, or `:PRReview` for all open PRs
3. Select a PR from the list
4. The plugin will:
   - Save your current branch
   - Create a review branch
   - Soft-merge the PR changes (unstaged)
   - Fetch all PR comments
   - Open the review buffer with all modified files

### Review Requests

Use `:PRListReviewRequests` to see PRs where you've been requested as a reviewer:

- Shows PR info with additions/deletions stats
- **Enter**: Start reviewing the selected PR

### Review Buffer (Interactive File Browser)

Press `:PRReviewBuffer` or use `b` in the `:PR` menu to open an interactive file browser:

```
┌─ PR #123: Add authentication ─────────────────────┐
│                                                    │
│  ▼ app/auth/                                       │
│    ✓ login.rb                          +45 -12    │
│    ○ session.rb                        +23 -5     │
│  ▶ spec/auth/                                      │
│  ✓ config/routes.rb                    +2 -0      │
│                                                    │
│  Progress: 2/4 files viewed                       │
│  <CR>: Open file | v: Toggle viewed | q: Close    │
└────────────────────────────────────────────────────┘
```

Features:
- **Foldable directories**: Press `<CR>` on a directory to collapse/expand it
  - **▼** = Expanded directory (showing files)
  - **▶** = Collapsed directory (files hidden)
- **✓** = File has been marked as viewed
- **○** = File not yet viewed
- Shows additions/deletions for each file
- Press `<CR>` on a file to open it
- Press `v` to toggle viewed status
- Press `q` to close
- Automatically refreshes as you mark files viewed

### Navigating Changes

The plugin includes built-in navigation that only works during PR review mode:

**Hunk Navigation** (within a file):
- `<C-j>` (default) - Jump to next hunk
- `<C-k>` (default) - Jump to previous hunk

**File Navigation** (between modified files):
- `<C-l>` (default) - Go to next modified file
- `<C-h>` (default) - Go to previous modified file
- `<CR>` (default) - Mark file as viewed and jump to next file

All keybindings are configurable in setup and only activate during PR review mode.

### Split Diff View

Toggle between unified (inline) and split (side-by-side) diff view with `<C-v>` (default):

**Unified View (Default)**:
- Shows changes inline with diff highlighting
- Deleted lines appear as virtual text above changes
- Added/modified lines highlighted in green

**Split View**:
- Left window: Base version (before changes)
- Right window: Current version (after changes)
- Both windows in diff mode with synchronized scrolling
- No inline diff markers needed - native Vim diff highlighting

The split view makes it easier to compare larger changes side-by-side. Press `<C-v>` again to return to unified view. The view mode persists as you navigate between files with `<C-l>`/`<C-h>`.

### Change Progress Indicator

When reviewing a file with changes, you'll see three floating windows providing context:

```
┌──────────────────────────┐  ┌─────────────┐  ┌──────────────────┐
│ ✓ Viewed                 │  │ +15 ~3 -8   │  │ <C-j> next hunk  │
│ 2/5 changes              │  │ 💬 2 💭 1   │  │ <C-k> prev hunk  │
│ <CR>: Mark as viewed     │  └─────────────┘  │ <C-v> split view │
└──────────────────────────┘                   │ <C-r> hide floats│
                                               └──────────────────┘
```

**Left Float (Progress)**:
- **Viewed status**: Shows if the current file has been marked as viewed
- **Change progress**: Current change position (groups consecutive changed lines together)
- **Mark as viewed**: Press `<CR>` to mark file as viewed and jump to next file

**Middle Float (Stats)**:
- **Stats**: +additions ~modifications -deletions
- **Comments**: 💬 Number of posted PR comments in this file
- **Pending**: 💭 Number of pending comments you've drafted

**Right Float (Keymaps)**:
- Shows available keyboard shortcuts for review mode

**Toggle Floating Windows**:
- Press `<C-r>` (default) to hide/show all three floating windows
- Set `show_floats = false` in config to disable them by default
- Useful when you want a cleaner view or need more screen space

### Pending Comments Workflow

One of the most efficient ways to review is using **pending comments**:

1. As you review, add pending comments with `:PRPendingComment`
2. These are saved locally (not submitted to GitHub yet)
3. Continue reviewing, adding more pending comments
4. Use `:PRListPendingComments` to review all your draft comments
5. When ready, run `:PRApprove` or `:PRRequestChanges`
6. The plugin shows a preview of ALL pending comments before submission
7. Confirm to submit your review + all pending comments at once

Benefits:
- Draft your thoughts as you review without interrupting your flow
- Review all your comments before submitting
- Submit everything together as a cohesive review
- Edit or delete pending comments before submission

### Viewing and Managing Comments

**Add Comments:**
- `:PRLineComment` - Add a review comment on the current line (submitted immediately)
- `:PRPendingComment` - Add a pending comment (submitted with approval/rejection)
- `:PRComment` - Add a general PR comment

**View Comments:**
- Comments appear as virtual text on lines automatically
- `:PRReviewComment` - Show comments at cursor line in a popup
- `:PRListAllComments` - Browse ALL comments with file preview

**Manage Comments:**
- `:PRReply` - Reply to a comment (cannot reply to pending comments)
- `:PREditComment` - Edit your comment (works for both pending and posted)
- `:PRDeleteComment` - Delete your comment
- `:PRToggleReaction` - Add or remove an emoji reaction to a comment

**React to Comments:**
- Position cursor on a line with a comment
- Use `:PRToggleReaction` or press `R` in the `:PR` menu
- Select an emoji (👍 👎 😄 🎉 😕 ❤️ 🚀 👀)
- Selecting the same reaction again removes it (toggle behavior)
- Reactions appear inline next to comment indicators and in comment previews

**List All Comments** (`:PRListAllComments`):
- Shows both pending and posted comments
- Includes author, file path, line number
- **Telescope**: Full file preview with syntax highlighting and comment highlighted
- **fzf-lua**: File preview with bat/cat showing context around the comment
- Navigate to comment location on selection

### Session Persistence

The plugin automatically saves your review session state:

- **Auto-save**: Session is saved when you start a review
- **Per-project**: Each project directory gets its own session file
- **What's saved**: PR number, previous branch, modified files, viewed status, pending comments
- **Auto-cleanup**: Session file is deleted when you run `:PRReviewCleanup`

To restore a session after restarting Neovim:

```vim
:PRLoadLastSession
```

Session files are stored in `~/.local/share/nvim/github-pr-reviewer-sessions/`.

### Inline Diff View

When `show_inline_diff` is enabled, the plugin displays the diff directly in your buffer:

- **Removed lines** appear as virtual text above the changed section (highlighted with `DiffDelete`)
- **Added/modified lines** are highlighted with `DiffAdd` and marked with a `+` sign
- This works **without gitsigns**, using native Neovim extmarks

Example visualization:
```
  - old line that was removed
  - another old line
+ new line that replaced them
+ another new line
```

Set `show_inline_diff = false` if you prefer to use gitsigns or another diff tool.

### Finishing the Review

1. Run `:PRApprove` to approve, or `:PRRequestChanges` to request changes
   - If you have pending comments, they'll be shown for confirmation
   - All pending comments are submitted with your review
2. Run `:PRReviewCleanup` to:
   - Revert all PR changes
   - Delete the review branch
   - Return to your original branch
   - Clear the session

## Complete Workflow Example

Here's a complete workflow for reviewing a PR efficiently:

```vim
" 1. See review requests
:PRListReviewRequests
" Select PR #42 from the list

" 2. Open the review buffer to see all files
:PRReviewBuffer

" 3. Jump to a file by pressing <CR>

" 4. Navigate with full LSP support
gd              " Go to definition
gr              " Find references
K               " See documentation

" 5. Use your favorite navigation tools
" - Telescope to search across files
" - Arrow/harpoon to mark important files
" - Normal Neovim navigation

" 6. Add pending comments as you review
:PRPendingComment
" Type your comment, press <C-s> to save locally

" 7. Mark file as viewed and go to next
<CR>            " Configured key to mark as viewed

" 8. Continue reviewing other files
<C-l>           " Next file
<C-h>           " Previous file

" 9. List all your pending comments to review them
:PRListAllComments

" 10. Approve and submit all pending comments at once
:PRApprove
" Review the preview, confirm to submit

" 11. Clean up and return to your work
:PRReviewCleanup
```

## Recommended Keymaps

```lua
-- Quick menu access
vim.keymap.set("n", "<leader>p", ":PR<CR>", { desc = "PR Review Menu" })

-- Review workflow
vim.keymap.set("n", "<leader>pr", ":PRReview<CR>", { desc = "Start PR review" })
vim.keymap.set("n", "<leader>pl", ":PRListReviewRequests<CR>", { desc = "List review requests" })
vim.keymap.set("n", "<leader>pc", ":PRReviewCleanup<CR>", { desc = "Cleanup PR review" })
vim.keymap.set("n", "<leader>pi", ":PRInfo<CR>", { desc = "Show PR info" })
vim.keymap.set("n", "<leader>po", ":PROpen<CR>", { desc = "Open PR in browser" })
vim.keymap.set("n", "<leader>pb", ":PRReviewBuffer<CR>", { desc = "Toggle review buffer" })

-- Comments
vim.keymap.set("n", "<leader>pC", ":PRLineComment<CR>", { desc = "Add line comment" })
vim.keymap.set("n", "<leader>pP", ":PRPendingComment<CR>", { desc = "Add pending comment" })
vim.keymap.set("n", "<leader>pv", ":PRListAllComments<CR>", { desc = "List all comments" })
vim.keymap.set("n", "<leader>pp", ":PRListPendingComments<CR>", { desc = "List pending comments" })
vim.keymap.set("n", "<leader>pR", ":PRReply<CR>", { desc = "Reply to comment" })
vim.keymap.set("n", "<leader>pe", ":PREditComment<CR>", { desc = "Edit my comment" })
vim.keymap.set("n", "<leader>pd", ":PRDeleteComment<CR>", { desc = "Delete my comment" })
vim.keymap.set("n", "<leader>pE", ":PRToggleReaction<CR>", { desc = "Toggle emoji reaction" })

-- Review actions
vim.keymap.set("n", "<leader>pa", ":PRApprove<CR>", { desc = "Approve PR" })
vim.keymap.set("n", "<leader>px", ":PRRequestChanges<CR>", { desc = "Request changes" })
```

## Integration with Other Plugins

### arrow.nvim / harpoon

Mark files you want to return to during review:

```lua
-- With arrow.nvim
require("arrow").setup()

-- With harpoon
require("harpoon").setup()
```

Both plugins work seamlessly during PR review, letting you mark important files and jump between them quickly.

### LSP (Native Neovim LSP or nvim-lspconfig)

Your LSP is fully functional during PR review:
- `gd` - Go to definition
- `gr` - Find references
- `K` - Hover documentation
- `<leader>rn` - Rename
- All your LSP keybindings work normally

**This is a huge advantage over web-based PR review** - you can explore the full codebase with full language intelligence.

### Telescope / fzf-lua

Set your preferred picker in the config:

```lua
require("github-pr-reviewer").setup({
  picker = "telescope",  -- or "fzf-lua" or "native"
})
```

Telescope and fzf-lua provide enhanced comment browsing with file previews.

### gitsigns.nvim (Optional)

**gitsigns.nvim is optional** - the plugin has built-in inline diff visualization. However, gitsigns can still be useful for:

- Hunk navigation with `]h` and `[h`
- Interactive hunk staging/unstaging
- Additional git blame and diff features

If you prefer to use gitsigns instead of the built-in inline diff:

```lua
require("github-pr-reviewer").setup({
  show_inline_diff = false,  -- Disable built-in diff, use gitsigns instead
})

require("gitsigns").setup({
  -- your gitsigns config
})

-- Navigation keymaps
vim.keymap.set("n", "]h", function() require("gitsigns").next_hunk() end)
vim.keymap.set("n", "[h", function() require("gitsigns").prev_hunk() end)
```

## How It Works

1. **Starting review**: Creates a branch from the PR's base branch, then soft-merges the PR's head branch without committing. This leaves all PR changes as unstaged modifications.

2. **Fork support**: Automatically detects fork PRs using GitHub's `isCrossRepository` field, adds the fork as a remote, and fetches from it.

3. **Comments**: Fetches PR comments via GitHub API and displays them as virtual text. Comments are cached per buffer for performance.

4. **Pending comments**: Stored locally in session files (JSON format) and submitted to GitHub when you approve/request changes.

5. **Change tracking**: Parses `git diff` output to identify changed lines and groups consecutive lines into "hunks" for the progress indicator.

6. **Cleanup**: Reverts only the files that were modified by the PR (safe for any other changes you made), deletes the review branch, and returns to your original branch.

## Troubleshooting

### "Cannot start review: you have uncommitted changes"

Commit or stash your changes before starting a review:

```bash
git stash
# or
git commit -am "WIP"
```

### "Not on a review branch"

You can only run `:PRReviewCleanup` when on a review branch (prefixed with `reviewing_` by default).

### Comments not showing

1. Make sure `show_comments = true` in your config
2. Check that you're authenticated with `gh auth status`
3. Try `:PRReviewComment` to manually show comments at cursor

### PR actions failing

Ensure GitHub CLI is properly authenticated:

```bash
gh auth status
gh auth login  # if not authenticated
```

### "git fetch failed"

If you see this error, you might have old fork remotes that are no longer accessible. Clean them up:

```bash
git remote | grep "^fork-" | xargs -I {} git remote remove {}
```

The plugin now has a fallback that tries `git fetch origin` if `git fetch --all` fails.

### Preview not working in fzf-lua

Install [bat](https://github.com/sharkdp/bat) for syntax-highlighted previews:

```bash
# macOS
brew install bat

# Ubuntu/Debian
apt install bat

# Arch
pacman -S bat
```

If `bat` is not available, the plugin falls back to `cat`.

## Performance

The plugin is designed for performance:

- **Lazy loading**: Comments are only fetched when entering a buffer
- **Caching**: Comments are cached per buffer to avoid repeated API calls
- **Efficient diff parsing**: Only parses diff output once per file
- **Background jobs**: File operations use async jobs when possible
- **Session files**: Small JSON files for fast load/save

Typical startup time: <100ms for a PR with 20+ files.

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Created by [Otávio Schwanck]

Inspired by the need for a better PR review experience in Neovim.

Special thanks to the Neovim community and all contributors!
