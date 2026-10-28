local M = {}

function M.check()
  vim.health.start "import-goto"
  if vim.fn.has "nvim-0.11" == 1 then
    vim.health.ok "Neovim >= 0.11"
  else
    vim.health.error "Neovim 0.11+ required (current JS/TS parsers use treesitter ABI 15)"
  end
  -- Path resolution needs no parser; the cursor helpers and gd on an imported
  -- name do.
  for _, lang in ipairs { "javascript", "typescript", "tsx" } do
    -- add() returns nil + error on 0.11+ rather than throwing.
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    if ok and loaded then
      vim.health.ok(lang .. " parser found")
    else
      vim.health.warn(
        lang .. " parser missing",
        { "Install it (e.g. :TSInstall " .. lang .. "); gd on import paths in these buffers won't work without it" }
      )
    end
  end
  local opts = require("import-goto.config").options
  vim.health.info("gd mapping: " .. tostring(opts.gd) .. ", gf hook: " .. tostring(opts.gf))
end

return M
