local M = {}

local defaults = {
  -- Language the answers are written in.
  language = "English",
  -- Model passed to `claude --model`; nil uses Claude Code's configured default.
  model = nil,
  -- The claude executable.
  claude = "claude",
  -- Branch a feature branch is compared against; nil detects origin/HEAD, then main, then master.
  base_branch = nil,
  -- Ticket a branch belongs to; one session and one dialog exist per ticket. Falls back to the
  -- repository name, so repositories without ticket branches still get a dialog.
  ticket = function(branch, root)
    return branch:match("%u+%-%d+") or vim.fs.basename(root)
  end,
  -- Where the dialog of a ticket is kept. Outside the repository by default; return a path inside
  -- it (for example root .. "/.scratch/" .. ticket .. "/code-explain.md") to keep it with the work.
  dialog = function(root, ticket)
    return string.format("%s/claude-diff-explainer/%s/%s.md", vim.fn.stdpath("state"), vim.fs.basename(root), ticket)
  end,
  -- Display name of the Claude session, shown by `claude --resume <id>`.
  session_name = function(ticket)
    return ticket .. ": code explainer"
  end,
  -- Headings of the two sections of an explanation. They are translated into `language` by Claude.
  headings = { what = "What it does", why = "What changed and why" },
  -- Texts the plugin writes into the dialog buffer or shows in prompts.
  labels = { question = "**Question:**", pending = "_Claude is answering…_", prompt = "Ask Claude: " },
  -- Normal-mode mapping inside the dialog buffer for a follow-up question; false disables it.
  followup_keymap = "<leader>a",
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function git(args)
  local result = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout) or nil
end

local function ticket_and_root()
  local root = git({ "rev-parse", "--show-toplevel" }) or vim.fn.getcwd()
  local branch = git({ "branch", "--show-current" }) or ""
  return M.config.ticket(branch, root), root
end

--- The branch a feature branch is compared against, or nil when none can be found.
function M.base_branch()
  if M.config.base_branch then return M.config.base_branch end
  local head = git({ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  if head then return (head:gsub("^origin/", "")) end
  for _, name in ipairs({ "main", "master" }) do
    if git({ "rev-parse", "--verify", "--quiet", "refs/heads/" .. name }) then return name end
  end
  return nil
end

local function new_uuid()
  if vim.fn.executable("uuidgen") == 1 then
    return vim.trim(vim.fn.system("uuidgen")):lower()
  end
  math.randomseed(os.time() + vim.uv.hrtime() % 1000000)
  return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)
    return ("%x"):format(v)
  end))
end

-- One Claude session per ticket. Its id is kept under the nvim state dir, so later calls resume it
-- and follow-up questions see the earlier explanations.
local function ask(prompt, on_done)
  local ticket, root = ticket_and_root()
  local dir = string.format("%s/claude-diff-explainer/sessions/%s", vim.fn.stdpath("state"), vim.fs.basename(root))
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/" .. ticket
  local existing = vim.fn.filereadable(file) == 1 and vim.trim(table.concat(vim.fn.readfile(file), "")) or nil

  local function claude(args)
    local cmd = { M.config.claude, "-p" }
    if M.config.model then vim.list_extend(cmd, { "--model", M.config.model }) end
    return vim.list_extend(vim.list_extend(cmd, args), { prompt })
  end

  local function start_fresh()
    local id = new_uuid()
    vim.fn.writefile({ id }, file)
    vim.system(claude({ "--session-id", id, "--name", M.config.session_name(ticket) }), { text = true }, on_done)
  end

  if not existing then return start_fresh() end
  vim.system(claude({ "--resume", existing }), { text = true }, vim.schedule_wrap(function(result)
    -- only a stale id (session pruned or started elsewhere) justifies a new session; any other
    -- failure, such as being logged out, keeps the id so the dialog continues once it is fixed
    if result.code ~= 0 and (result.stderr .. result.stdout):find("No conversation found", 1, true) then
      vim.fn.delete(file)
      return start_fresh()
    end
    on_done(result)
  end))
end

-- Where the current buffer sits in the repository and which diff it is part of: inside Diffview
-- the view's own revision range for the current file, elsewhere the branch against its base branch.
local function current_location()
  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  if view and view.cur_entry and view.left then
    local RevType = require("diffview.vcs.rev").RevType
    local path = view.cur_entry.path
    local args = { "diff", view.left:object_name() }
    if view.right.type == RevType.STAGE then
      table.insert(args, "--cached")
    elseif view.right.type ~= RevType.LOCAL then
      table.insert(args, view.right:object_name())
    end
    vim.list_extend(args, { "--", path })
    local range = view.rev_arg or (view.left:object_name(8) .. ".." .. view.right:object_name(8))
    return path, git(args) or "", range
  end
  local _, root = ticket_and_root()
  local path = vim.fn.expand("%:p")
  local relative = vim.startswith(path, root .. "/") and path:sub(#root + 2) or path
  -- the branch's whole change so far, committed or not; on the base branch itself that is the working tree
  local base_branch = M.base_branch()
  local base = base_branch and git({ "merge-base", base_branch, "HEAD" })
  if base then
    return relative, git({ "diff", base, "--", path }) or "", base_branch .. "...working tree"
  end
  return relative, git({ "diff", "HEAD", "--", path }) or "", "working tree vs HEAD"
end

-- The dialog is a markdown file shown in one window on the right; an existing window is reused.
local function dialog_buffer()
  local ticket, root = ticket_and_root()
  local path = M.config.dialog(root, ticket)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local buf = vim.fn.bufnr(path)
  local win = buf ~= -1 and vim.fn.bufwinid(buf) or -1
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("botright vsplit " .. vim.fn.fnameescape(path))
    vim.wo.wrap = true
  end
  buf = vim.api.nvim_get_current_buf()
  if M.config.followup_keymap then
    vim.keymap.set("n", M.config.followup_keymap, M.ask, { buffer = buf, desc = "Follow-up question to Claude" })
  end
  return buf
end

local namespace = vim.api.nvim_create_namespace("claude-diff-explainer")

-- Appends a heading and a placeholder, asks Claude, then swaps the placeholder for the answer and
-- writes the file. On an error the pending block is removed again: the file only ever holds answers.
local function converse(heading, prompt)
  local buf = dialog_buffer()
  local last = vim.api.nvim_buf_line_count(buf)
  local empty = last == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  local start = empty and 0 or last
  vim.api.nvim_buf_set_lines(buf, start, -1, false, { heading, "", M.config.labels.pending, "" })
  -- extmarks follow the block even if the user edits above it while waiting
  local from = vim.api.nvim_buf_set_extmark(buf, namespace, start, 0, {})
  local to = vim.api.nvim_buf_set_extmark(buf, namespace, start + 3, 0, {})
  vim.api.nvim_buf_call(buf, function() vim.cmd("normal! G") end)

  ask(prompt, vim.schedule_wrap(function(result)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local first = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, from, {})[1]
    local after = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, to, {})[1] + 1
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local text = vim.trim(result.stdout ~= "" and result.stdout or result.stderr)
    if result.code ~= 0 then
      vim.api.nvim_buf_set_lines(buf, first, after, false, {})
      local name = vim.api.nvim_buf_get_name(buf)
      local on_disk = vim.fn.filereadable(name) == 1 and vim.fn.readfile(name) or {}
      if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), on_disk) then vim.bo[buf].modified = false end
      vim.notify(string.format("claude-diff-explainer (exit %d): %s", result.code, text ~= "" and text or "no output"),
        vim.log.levels.ERROR)
      return
    end
    vim.api.nvim_buf_set_lines(buf, first + 2, first + 3, false, vim.split(text, "\n"))
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  end))
end

--- Explains the given line range of the current buffer (defaults to the last visual selection).
function M.explain(first, last)
  first, last = first or vim.fn.line("'<"), last or vim.fn.line("'>")
  local code = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
  local path, diff, range = current_location()
  local location = string.format("%s:%d-%d", path, first, last)
  local parts = {
    string.format("Explain the selected section of %s in exactly two sections, each under a level-3 markdown "
      .. "heading. First heading: '%s', covering what the code does. Second heading: '%s', using the diff: what is "
      .. "new or removed, and what purpose a newly introduced helper, parameter or type serves; if the file has no "
      .. "diff, say so in one sentence. Translate both headings into the answer language if they are not already. "
      .. "Be concise, plain prose. Answer in %s.",
      location, M.config.headings.what, M.config.headings.why, M.config.language),
    "Selected lines:\n```\n" .. code .. "\n```",
    diff ~= "" and string.format("Diff of %s (%s):\n```diff\n%s\n```", path, range, diff)
      or "There is no diff for this file; explain the code on its own.",
  }
  converse(string.format("## `%s` (%s)", location, os.date("%Y-%m-%d %H:%M")), table.concat(parts, "\n\n"))
end

--- Asks a follow-up question in the ticket's dialog; prompts for the question when none is given.
function M.ask(question)
  if type(question) ~= "string" or question == "" then
    return vim.ui.input({ prompt = M.config.labels.prompt }, function(input)
      if input and input ~= "" then M.ask(input) end
    end)
  end
  converse(M.config.labels.question .. " " .. question,
    question .. "\n\nAnswer in " .. M.config.language .. ", no heading.")
end

return M
