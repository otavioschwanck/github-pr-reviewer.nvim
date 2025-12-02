# Claude Code - Guide for AIs and Developers

This document contains essential information about the architecture, patterns, and important details of the `neovim-pr-reviewer` plugin.

## Overview

Neovim/Lua plugin for reviewing GitHub Pull Requests directly in the editor, with support for:
- Navigation between modified files
- Diff visualization (unified and split/side-by-side)
- Comment system (inline and global)
- PR approval/rejection
- Marking files as "viewed"

## Main Architecture

### Main File
- **`lua/github-pr-reviewer/init.lua`** (~4400 lines): Contains all plugin logic

### Auxiliary Modules
- **`lua/github-pr-reviewer/github.lua`**: GitHub GraphQL API interaction
- **`lua/github-pr-reviewer/ui.lua`**: UI components (pickers, menus)

## Important Concepts

### 1. Diff Visualization Modes

#### Unified Mode (Default)
- Single file with inline highlights
- **Visual indicators**: `│` (vertical bar) in the signs column for modified lines
- **Important namespaces**:
  - `changes_ns_id`: Change indicators (│)
  - `diff_ns_id`: Inline diff highlights (green/red)
  - `hunk_hints_ns_id`: Navigation hints (←/→)

#### Split Mode (Side-by-Side)
- **Two buffers side by side**:
  - Left: `[BEFORE] filename` (git base version)
  - Right: Current file (PR version)
- **Uses Vim's native diff mode**: `diffthis`, `diffoff`, `diffupdate`
- **CRITICAL**: Do NOT add extmarks/visual indicators when in split mode!
- **State stored in**: `M._split_view_state`

**Control variable**: `M._diff_view_mode` ("unified" | "split")

### 2. Buffer System

#### Special Buffers
- **`[BEFORE] <path>`**: Read-only buffer with git base content
- **Review Buffer**: Special buffer with list of modified files

#### Buffer State Tracking
```lua
M._buffer_changes[bufnr] = lines      -- Modified lines
M._buffer_hunks[bufnr] = hunks        -- Change hunks (for navigation)
M._buffer_comments[bufnr] = comments  -- Comments in buffer
M._buffer_stats[bufnr] = stats        -- Statistics (+X/-Y)
M._buffer_jumped[bufnr] = bool        -- Whether already jumped to first change
M._buffer_keymaps_saved[bufnr] = bool -- Whether keymaps already configured
```

### 3. Floating Windows (Popups)

Three floating windows displayed on the right:
1. **General Info**: File X/Total, viewed status
2. **Buffer Info**: Changes count, stats, comments
3. **Keymaps**: Available shortcuts

**IMPORTANT**: The floats depend on `M._buffer_hunks[bufnr]` being populated!

### 4. Navigation System

#### Automatic Navigation (C-h/C-l)
```lua
-- Flow when navigating with C-h or C-l:
1. restore_unified_view()           -- Closes previous split
2. open_file_safe(file)             -- Opens file with `edit`
3. defer_fn (50ms):
   - M._diff_view_mode = "unified"  -- Reset mode
   - M.toggle_diff_view()           -- Creates split if necessary
```

**Important flag**: `M._opening_file` (prevents autocmd interference)

#### Auto-Fix Split (Manual Buffer Change)

When user manually changes buffer (`:b` or fzf), `BufEnter` detects and runs `M.fix_vsplit()` automatically:

```lua
-- Conditions for auto-fix:
- M._diff_view_mode == "split"
- NOT M._opening_file (not navigating)
- Buffer is not [BEFORE]
- Split state doesn't match current buffer
- File is part of the PR
```

## Common Problems and Solutions

### Problem: Duplicate Highlights in Split Mode

**Cause**: Extmarks being added to buffers that are in diff mode, causing duplicate highlights (vim diff + our indicators).

**Solution**:
1. Clear ALL namespaces before creating split: `vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)`
2. Don't add extmarks when `M._diff_view_mode == "split"`
3. `BufEnter` must skip `load_inline_diff_for_buffer` in split mode

### Problem: Floats Don't Appear in Split Mode

**Cause**: `load_changes_for_buffer` wasn't being called in split mode, so `M._buffer_hunks[bufnr]` was empty.

**Solution**:
- **ALWAYS** call `load_changes_for_buffer` (to populate hunks)
- **CONDITIONALLY** add extmarks based on `M._diff_view_mode`

```lua
-- In load_changes_for_buffer:
if M._diff_view_mode ~= "split" then
  -- Only add visual indicators (│) if NOT in split mode
  vim.api.nvim_buf_set_extmark(...)
end
```

### Problem: Split with Wrong Highlights After Manual Change

**Cause**: Vim's internal state (diff cache) not being cleaned when recreating split.

**Solution** (`M.fix_vsplit()`):
```lua
1. restore_unified_view()                    -- Close split
2. vim.cmd("diffoff!")                       -- Turn off diff completely
3. vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)  -- Clear EVERYTHING
4. vim.cmd("edit " .. file_path)             -- Reload file
5. defer_fn(50ms):
   - M._diff_view_mode = "unified"           -- Reset mode
   - M.toggle_diff_view()                    -- Recreate clean split
```

**CRITICAL**: The 50ms delay is essential! Vim needs to process the `edit` before creating the split.

## Patterns and Conventions

### 1. Namespace IDs
```lua
local ns_id = vim.api.nvim_create_namespace("pr_review_comments")
local changes_ns_id = vim.api.nvim_create_namespace("pr_review_changes")
local diff_ns_id = vim.api.nvim_create_namespace("pr_review_diff")
local hunk_hints_ns_id = vim.api.nvim_create_namespace("pr_review_hunk_hints")
```

### 2. State Cleanup

**ALWAYS clear namespaces before recreating splits**:
```lua
vim.api.nvim_buf_clear_namespace(bufnr, diff_ns_id, 0, -1)
vim.api.nvim_buf_clear_namespace(bufnr, changes_ns_id, 0, -1)
```

**Clear EVERYTHING** (useful for complete reset):
```lua
vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)  -- -1 = all
```

### 3. Diff Mode

**Resetting mode to unified is CRITICAL**:
```lua
-- In restore_unified_view():
M._diff_view_mode = "unified"  -- ALWAYS reset!
```

Without this, the mode becomes out of sync with the real state.

### 4. Timing and Scheduling

Use `vim.defer_fn()` when you need Vim to process something first:
- After `edit` command (50ms)
- After creating buffers (50-100ms)
- After layout changes

Use `vim.schedule()` for operations that should run in the next event loop.

### 5. Validity Checks

**ALWAYS check if buffers/windows are valid before using**:
```lua
if vim.api.nvim_buf_is_valid(bufnr) then
  -- safe to use
end

if vim.api.nvim_win_is_valid(winnr) then
  -- safe to use
end
```

## Data Flow

### 1. Review Initialization

```
User: :PR <number>
  ↓
fetch_pr_changes() (github.lua)
  ↓
M.start_review()
  ↓
- Create review buffer with file list
- Populate M._review_files
- Setup autocmds (BufEnter, CursorMoved, etc)
```

### 2. File Opening

```
User: <CR> in review buffer OR C-l/C-h
  ↓
open_file_safe(file)
  ↓
vim.cmd("edit " .. file_path)
  ↓
BufEnter autocmd:
  - load_comments_for_buffer()
  - load_changes_for_buffer()      # Populate hunks
  - load_inline_diff_for_buffer()  # Unified mode only
  - Auto-fix split (if necessary)
  ↓
update_changes_float()  # Show popups
```

### 3. Toggle to Split Mode

```
User: <C-v> (or toggle_diff_view)
  ↓
M.toggle_diff_view()
  ↓
M._diff_view_mode = "split"
create_split_view(bufnr, file_path)
  ↓
1. Fetch base content: git show origin/base:file
2. Create [BEFORE] buffer with base content
3. Create left window with [BEFORE] buffer
4. Get right window (current file)
5. Clear namespaces (diff_ns_id, changes_ns_id)
6. vim.cmd("diffthis") in both windows
7. Store M._split_view_state
```

### 4. Restore to Unified

```
User: <C-v> again
  ↓
restore_unified_view()
  ↓
1. vim.cmd("diffoff") in both windows
2. Close left window
3. Delete [BEFORE] buffer
4. Set current window to right window
5. load_inline_diff_for_buffer()
6. M._diff_view_mode = "unified"  # CRITICAL!
7. Clear M._split_view_state
```

## Important Autocmds

### BufEnter
```lua
-- The most critical! Controls all buffer entry logic:
1. Load comments
2. Load changes (ALWAYS, for hunks)
3. Load inline diff (only if NOT split mode)
4. Auto-fix split (if necessary)
5. Update review buffer highlight
6. Jump to first change (first time)
```

### CursorMoved
```lua
-- Update hints and floats when cursor moves
update_hunk_navigation_hints()
update_changes_float()
```

### WinLeave
```lua
-- Close floats when leaving window
close_float_wins()
```

## Git Integration

### Fetching Base Content

Tries multiple refs in order:
```lua
1. origin/{base_branch}:{file}
2. {base_branch}:{file}
3. origin/main:{file}
4. origin/master:{file}
5. main:{file}
6. master:{file}
7. HEAD~1:{file}
```

### Archived Files (Deleted)

Status "D" (deleted):
- Fetch from `HEAD:{file}` (version before deletion)
- Read-only buffer
- All lines with DiffDelete highlight

### New Files

Status "A" or "N" (added/new):
- Base content = empty
- **DO NOT show indicators** (│) - entire file would be highlighted

## Available Commands

### Main
- `:PR <number>` - Start review
- `:PRApprove` - Approve PR
- `:PRReject` - Reject PR
- `:PRInfo` - Show PR information
- `:PRMenu` - Interactive menu

### Comments
- `:PRAddComment` - Add line comment
- `:PRAddPendingComment` - Pending comment (not published)
- `:PRSubmitPendingComments` - Publish pending comments
- `:PRListAllComments` - List all comments

### Navigation
- Keybinds (configurable):
  - `<C-j>` / `<C-k>` - Next/prev hunk
  - `<C-l>` / `<C-h>` - Next/prev file
  - `<C-v>` - Toggle split/unified
  - `<C-r>` - Toggle floats
  - `<CR>` - Mark as viewed and next

## Configuration

### Structure
```lua
M.config = {
  show_floats = true,
  next_hunk_key = "<C-j>",
  prev_hunk_key = "<C-k>",
  next_file_key = "<C-l>",
  prev_file_key = "<C-h>",
  diff_view_toggle_key = "<C-v>",
  mark_as_viewed_key = "<CR>",
  toggle_floats_key = "<C-r>",
  -- ... more options
}
```

### Highlight Groups

Defined in setup:
```lua
- PRReviewFile (links to Directory)
- PRReviewViewed (links to Comment)
- PRReviewCurrent (links to CursorLine)
- PRReviewStats (links to String)
```

## Debugging Tips

### 1. Check Current State
```lua
:lua print(vim.inspect(require('github-pr-reviewer')._diff_view_mode))
:lua print(vim.inspect(require('github-pr-reviewer')._split_view_state))
:lua print(vim.inspect(require('github-pr-reviewer')._buffer_hunks[vim.api.nvim_get_current_buf()]))
```

### 2. Force Reset
```lua
:lua require('github-pr-reviewer')._diff_view_mode = "unified"
:diffoff!
```

### 3. Check Namespaces
```lua
:lua vim.api.nvim_buf_clear_namespace(0, -1, 0, -1)  -- Clear everything
```

### 4. Reload Plugin
```lua
:luafile lua/github-pr-reviewer/init.lua
```

## Testing

### Important Test Cases

1. **Basic Split Mode**
   - Open file with C-l
   - Toggle to split (C-v)
   - Verify correct highlights (only on modified lines)

2. **Manual Buffer Change**
   - In split mode, do `:b <other_file>`
   - Should auto-fix and show correct split
   - Floats should appear

3. **File Navigation**
   - C-l/C-h to navigate
   - Split should follow correctly
   - No duplicate highlights

4. **Special Files**
   - New file (status A/N) - don't show indicators
   - Deleted file (status D) - show previous version
   - Renamed file - verify correct paths

5. **Comments in Split Mode**
   - Add comment in split mode
   - Verify it appears correctly
   - Toggle to unified - comment should persist

## Gotchas and Pitfalls

### ❌ DON'T DO

1. **Modify diffopt globally without restoring**
   ```lua
   -- WRONG:
   vim.o.diffopt = "internal,filler,iwhite"  -- Can break diff!

   -- RIGHT:
   -- Use user's diffopt without modifying
   ```

2. **Add extmarks in split mode**
   ```lua
   -- WRONG:
   vim.api.nvim_buf_set_extmark(bufnr, changes_ns_id, ...)  -- In any mode

   -- RIGHT:
   if M._diff_view_mode ~= "split" then
     vim.api.nvim_buf_set_extmark(bufnr, changes_ns_id, ...)
   end
   ```

3. **Forget to reset mode after restore**
   ```lua
   -- WRONG:
   restore_unified_view()
   -- mode is still "split"!

   -- RIGHT:
   restore_unified_view()  -- Already resets mode internally
   ```

4. **Don't check validity before using**
   ```lua
   -- WRONG:
   vim.api.nvim_win_close(win, true)  -- Can error if window already closed

   -- RIGHT:
   if vim.api.nvim_win_is_valid(win) then
     vim.api.nvim_win_close(win, true)
   end
   ```

### ✅ ALWAYS DO

1. **Clear namespaces before creating splits**
2. **Check buffer/window validity**
3. **Use defer_fn after layout operations**
4. **Reset M._diff_view_mode correctly**
5. **Test with new (A), deleted (D), and modified (M) files**

## Performance

### Implemented Optimizations

1. **Viewed files cache**: `M._viewed_files`
2. **Comments cache per buffer**: `M._buffer_comments`
3. **Saved keymaps per buffer**: `M._buffer_keymaps_saved` (avoids recreation)
4. **Update throttling**: `vim.defer_fn` with appropriate delays

### Areas for Improvement

- Load comments lazily (only when needed)
- Cache git show results
- Debounce update_changes_float on CursorMoved

## Contributing

### Checklist for New Features

- [ ] Works in unified mode?
- [ ] Works in split mode?
- [ ] Clears namespaces correctly?
- [ ] Doesn't add extmarks in split mode?
- [ ] Tests with A/D/M files?
- [ ] Tests manual navigation (`:b`)?
- [ ] Floats continue working?
- [ ] Doesn't break when toggling multiple times?

### Checklist for Bug Fixes

- [ ] Identified the root cause?
- [ ] Verified it doesn't break other modes?
- [ ] Added validity checks?
- [ ] Tested edge cases (new file, deleted)?
- [ ] Documented the fix?

## Recent Changelog

### 2025-01-XX - Major Fixes

- ✅ Fixed duplicate highlights in split mode
- ✅ Auto-fix when manually changing buffer (`:b`, fzf)
- ✅ Floats now appear in split mode
- ✅ Aggressive state cleanup when recreating splits
- ✅ Removed manual command `:PRFixVSplit` (now automatic)

## Contact and Support

- GitHub Issues: https://github.com/username/neovim-pr-reviewer/issues
- Documentation: `:h github-pr-reviewer`

---

**Last updated**: January 2025
**Plugin Version**: 0.1+
