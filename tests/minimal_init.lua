-- Bare runtime for the headless suite: this plugin, plenary for the busted
-- runner, and the JS/TS parsers. `make deps` fetches plenary and builds the
-- parsers into .deps/; set PLENARY_DIR / PARSER_DIR to reuse existing copies.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local deps = root .. "/.deps"

vim.opt.rtp = {
  root,
  vim.env.PLENARY_DIR or (deps .. "/plenary.nvim"),
  vim.env.PARSER_DIR or (deps .. "/site"),
  vim.env.VIMRUNTIME,
}
vim.opt.swapfile = false
vim.cmd "runtime plugin/plenary.vim"
require("import-goto").setup()
