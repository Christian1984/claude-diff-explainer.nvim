# claude-diff-explainer.nvim

Select a few lines in Neovim, press a key, and get an explanation from [Claude Code](https://claude.com/claude-code)
that covers two things: **what the code does** and **what changed and why**, read from the diff the file is part of.
Every answer lands in one markdown dialog per ticket, and follow-up questions continue the same Claude session, so
Claude remembers what it already explained.

It is a diff explainer, not a chat or editing plugin. It shells out to `claude -p`, so it uses whatever account the
`claude` CLI is logged in with, including a Claude subscription.

## How it works

- **Selection** – the visually selected lines go to Claude together with the file's diff.
- **Diff** – inside a [diffview.nvim](https://github.com/sindrets/diffview.nvim) view the diff is the view's own
  revision range for that file. Elsewhere it is the branch against its base branch (`origin/HEAD`, else `main`, else
  `master`), committed and uncommitted changes alike.
- **Ticket** – the branch name yields a ticket (`PROJ-1234` by default). One Claude session and one dialog file exist
  per ticket. On branches without a ticket, the repository name stands in.
- **Dialog** – a markdown file, shown in a split on the right. Each explanation starts with a heading naming
  `path:first-last` and the time. Follow-ups are appended below. Errors never reach the file: a failed call is
  removed from the buffer and reported with `vim.notify`.
- **Session** – the session id is stored under `stdpath("state")`. Sessions created with `claude -p` do not show in
  `claude --resume`'s picker, but `claude --resume <id>` opens them interactively.

## Requirements

- Neovim >= 0.10
- the `claude` CLI, logged in (`claude` then `/login`)
- git
- optional: diffview.nvim

Run `:checkhealth claude-diff-explainer` to verify.

## Installation

packer.nvim:

```lua
use "Christian1984/claude-diff-explainer.nvim"
```

lazy.nvim:

```lua
{
  "Christian1984/claude-diff-explainer.nvim",
  opts = { language = "English" },
  keys = {
    { "<leader>e", ":ClaudeDiffExplain<CR>", mode = "x", desc = "Explain selection with Claude" },
  },
}
```

## Configuration

All options with their defaults:

```lua
require("claude-diff-explainer").setup({
  language = "English",      -- language of the answers
  model = nil,               -- `claude --model`; nil = Claude Code's default
  claude = "claude",         -- the executable
  base_branch = nil,         -- nil = detect origin/HEAD, then main, then master
  ticket = function(branch, root)
    return branch:match("%u+%-%d+") or vim.fs.basename(root)
  end,
  dialog = function(root, ticket)
    return string.format("%s/claude-diff-explainer/%s/%s.md", vim.fn.stdpath("state"), vim.fs.basename(root), ticket)
  end,
  session_name = function(ticket) return ticket .. ": code explainer" end,
  headings = { what = "What it does", why = "What changed and why" },
  labels = { question = "**Question:**", pending = "_Claude is answering…_", prompt = "Ask Claude: " },
  followup_keymap = "<leader>a", -- normal mode, inside the dialog buffer only; false disables
})
```

Example: German answers, dialog kept inside the repository next to the ticket's other notes:

```lua
require("claude-diff-explainer").setup({
  language = "Deutsch",
  dialog = function(root, ticket)
    return root .. "/.scratch/" .. ticket:lower() .. "/code-explain.md"
  end,
  labels = { question = "**Frage:**", pending = "_Claude antwortet…_", prompt = "Frage an Claude: " },
})
```

## Commands and mappings

The plugin defines commands and no global mappings:

| Command | Does |
| --- | --- |
| `:'<,'>ClaudeDiffExplain` | explain the selected lines and their diff |
| `:ClaudeDiffAsk [question]` | follow-up in the ticket's dialog; prompts when no question is given |

Suggested mappings:

```lua
vim.keymap.set("x", "<leader>e", ":ClaudeDiffExplain<CR>", { silent = true, desc = "Explain selection with Claude" })
vim.keymap.set("n", "<leader>gd", function()
  local base = require("claude-diff-explainer").base_branch()
  vim.cmd("DiffviewOpen " .. (base and base .. "...HEAD" or ""))
end, { desc = "Diffview: branch vs base branch" })
```

Inside the dialog buffer, `<leader>a` (configurable) asks a follow-up question.

## Lua API

```lua
local explainer = require("claude-diff-explainer")
explainer.explain(first, last)  -- line range; defaults to the last visual selection
explainer.ask("question")       -- follow-up; prompts when called without a question
explainer.base_branch()         -- detected base branch or nil
```

## License

MIT
