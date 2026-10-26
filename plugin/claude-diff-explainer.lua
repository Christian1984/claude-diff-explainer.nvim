if vim.g.loaded_claude_diff_explainer then return end
vim.g.loaded_claude_diff_explainer = true

vim.api.nvim_create_user_command("ClaudeDiffExplain", function(opts)
  require("claude-diff-explainer").explain(opts.line1, opts.line2)
end, { range = true, desc = "Explain the selected lines and their diff with Claude" })

vim.api.nvim_create_user_command("ClaudeDiffAsk", function(opts)
  require("claude-diff-explainer").ask(opts.args)
end, { nargs = "*", desc = "Follow-up question in the ticket's dialog" })
