-- import-goto.nvim: jump from a JS/TS import specifier to the file it resolves
-- to, the way TypeScript/Node would, without waiting on (or needing) an LSP.
local config = require "import-goto.config"
local core = require "import-goto.core"

local M = {}

-- Public API (see :h import-goto-api).
M.resolve = core.resolve
M.specifier_at_cursor = core.specifier_at_cursor
M.goto_imported_name = core.goto_imported_name
M.goto_definition = core.goto_definition

-- 'includeexpr' target: the resolved path, or the name unchanged so gf's
-- normal 'path' search still applies.
function M.includeexpr(fname)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return fname
  end
  -- '@' isn't in the default 'isfname' (a global option, so not ours to
  -- change): "@org/pkg" and "@/x" arrive as "org/pkg" and "/x".
  if vim.api.nvim_get_current_line():find("@" .. fname, 1, true) then
    local r = core.resolve("@" .. fname, file)
    if r then
      return r
    end
  end
  return core.resolve(fname, file) or fname
end

local function default_fallback()
  if #vim.lsp.get_clients { bufnr = 0, method = "textDocument/definition" } > 0 then
    vim.lsp.buf.definition()
  else
    vim.cmd "normal! gd"
  end
end

local function attach(buf)
  if config.options.gd then
    vim.keymap.set("n", "gd", function()
      core.goto_definition(default_fallback)
    end, { buffer = buf, desc = "Go to definition (import-goto)" })
  end
  if config.options.gf then
    vim.bo[buf].includeexpr = "v:lua.require'import-goto'.includeexpr(v:fname)"
  end
end

function M.setup(opts)
  config.set(opts)
  -- Core maps these filetypes to same-named languages, which have no parser;
  -- nvim-treesitter registers the same, so only fill the gap without it.
  for ft, lang in pairs { typescriptreact = "tsx", javascriptreact = "javascript" } do
    if vim.treesitter.language.get_lang(ft) == ft then
      vim.treesitter.language.register(lang, ft)
    end
  end
  local group = vim.api.nvim_create_augroup("import-goto", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.options.filetypes,
    callback = function(args)
      attach(args.buf)
    end,
  })
  -- Buffers already open when setup() runs (lazy-loaded on ft).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(config.options.filetypes, vim.bo[buf].filetype) then
      attach(buf)
    end
  end
end

return M
