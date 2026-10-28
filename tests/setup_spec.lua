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
