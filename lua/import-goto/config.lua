local M = {}

M.defaults = {
  -- Filetypes that get the gd mapping and the gf hook.
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },

  -- Buffer-local `gd`: on an import path open the resolved file, otherwise fall
  -- back to the LSP's definition (or to built-in gd with no LSP attached).
  -- Set false to wire it yourself with require("import-goto").goto_definition().
  gd = true,

  -- Set 'includeexpr' so `gf` / `<C-w>f` resolve specifiers the same way.
  gf = true,

  -- Order to pick through `exports`/`imports` condition objects. Source/types
  -- first: they're what you want to read, rather than a bundled dist file.
  conditions = { "source", "types", "typings", "import", "module", "require", "node", "default" },

  -- Build-output directories in workspace packages. A resolved file under one
  -- of these jumps to the matching file under src/ when it exists.
  out_dirs = { "dist", "build", "out", "lib" },
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Lists replace rather than merge: a user's `conditions` is the full order.
  for _, k in ipairs { "filetypes", "conditions", "out_dirs" } do
    if opts and opts[k] then
      M.options[k] = opts[k]
    end
  end
end

return M
