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
  return file ~= "" and core.resolve(fname, file) or fname
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
