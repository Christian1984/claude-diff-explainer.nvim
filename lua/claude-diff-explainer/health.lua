local M = {}

function M.check()
  vim.health.start("claude-diff-explainer")
  local config = require("claude-diff-explainer").config

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 is required (vim.system)")
  end

  for _, exe in ipairs({ config.claude, "git" }) do
    if vim.fn.executable(exe) == 1 then
      vim.health.ok(exe .. " found: " .. vim.fn.exepath(exe))
    else
      vim.health.error(exe .. " not found in PATH")
    end
  end

  if vim.fn.executable(config.claude) == 1 then
    local status = vim.system({ config.claude, "auth", "status" }, { text = true }):wait()
    local ok, parsed = pcall(vim.json.decode, status.stdout)
    if ok and type(parsed) == "table" and parsed.loggedIn then
      vim.health.ok("claude is logged in (" .. tostring(parsed.authMethod) .. ")")
    else
      vim.health.warn("claude does not report a login; run `claude` and `/login`")
    end
  end

  if pcall(require, "diffview.lib") then
    vim.health.ok("diffview.nvim present: explanations inside a Diffview use its revision range")
  else
    vim.health.info("diffview.nvim not found: diffs are taken from the branch against its base branch")
  end
end

return M
