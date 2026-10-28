-- setup(): option overrides, the gd mapping and the gf hook.
local ig = require "import-goto"

describe("setup", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    root = vim.uv.fs_realpath(root)
  end)

  after_each(function()
    vim.cmd "silent! %bwipeout!"
    vim.fn.delete(root, "rf")
    ig.setup()
  end)

  local function write(rel, body)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    vim.fn.writefile(vim.split(body, "\n"), p)
    return p
  end

  it("maps gd and sets includeexpr on JS/TS buffers", function()
    vim.cmd.edit(write("a.ts", ""))
    assert.equals("Go to definition (import-goto)", vim.fn.maparg("gd", "n", false, true).desc)
    assert.matches("import%-goto", vim.bo.includeexpr)
  end)

  it("leaves both alone when disabled", function()
    ig.setup { gd = false, gf = false }
    vim.cmd.edit(write("a.ts", ""))
    assert.same({}, vim.fn.maparg("gd", "n", false, true))
    assert.equals("", vim.bo.includeexpr)
  end)

  it("includeexpr resolves a specifier, or returns it unchanged", function()
    local x = write("src/x.ts", "")
    vim.cmd.edit(write("src/a.ts", ""))
    assert.equals(x, ig.includeexpr "./x")
    assert.equals("./nope", ig.includeexpr "./nope")
  end)

  it("includeexpr restores the '@' that 'isfname' drops from <cfile>", function()
    local pkg = write("node_modules/@org/pkg/index.ts", "")
    local alias = write("src/components/x.ts", "")
    write("tsconfig.json", [[{ "compilerOptions": { "paths": { "@/*": ["./src/*"] } } }]])
    vim.cmd.edit(write("src/a.ts", 'import y from "@org/pkg"\nimport x from "@/components/x"'))
    vim.api.nvim_win_set_cursor(0, { 1, 16 })
    assert.equals(pkg, ig.includeexpr(vim.fn.expand "<cfile>"))
    vim.api.nvim_win_set_cursor(0, { 2, 16 })
    assert.equals(alias, ig.includeexpr(vim.fn.expand "<cfile>"))
  end)

  it("health reports a parser that fails to load", function()
    local add, warn, ok = vim.treesitter.language.add, vim.health.warn, vim.health.ok
    local warned = {}
    vim.treesitter.language.add = function()
      return nil, "no parser"
    end
    vim.health.warn = function(msg)
      warned[#warned + 1] = msg
    end
    vim.health.ok = function() end
    local done, err = pcall(require("import-goto.health").check)
    vim.treesitter.language.add, vim.health.warn, vim.health.ok = add, warn, ok
    assert(done, err)
    assert.same({ "javascript parser missing", "typescript parser missing", "tsx parser missing" }, warned)
  end)

  it("replaces the condition order instead of merging it", function()
    write("node_modules/pkg/package.json", [[{ "exports": { "import": "./esm.js", "types": "./types.d.ts" } }]])
    local esm = write("node_modules/pkg/esm.js", "")
    write("node_modules/pkg/types.d.ts", "")
    local from = write("a.ts", "")
    ig.setup { conditions = { "import", "default" } }
    assert.equals(esm, ig.resolve("pkg", from))
  end)

  it("uses configured out_dirs for the dist -> src hop", function()
    write("packages/lib/package.json", [[{ "main": "compiled/index.js" }]])
    write("packages/lib/compiled/index.js", "")
    local src = write("packages/lib/src/index.ts", "")
    local from = write("a.ts", "")
    ig.setup { out_dirs = { "compiled" } }
    assert.equals(src, ig.resolve("./packages/lib", from))
  end)
end)
