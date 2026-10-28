-- import-goto: module resolution (M.resolve), the specifier under the cursor,
-- and gd on an imported name. Fixture projects are written to a temp dir per
-- run, so node_modules/ and dist/ trees don't need to live in the repo.
local ig = require "import-goto"

local root

-- Write `files` ({ ["rel/path"] = "contents" }) under root.
local function tree(files)
  for rel, body in pairs(files) do
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    vim.fn.writefile(vim.split(body, "\n"), p)
  end
end

local function abs(rel)
  return vim.uv.fs_realpath(root .. "/" .. rel)
end

local function resolve(spec, from)
  return ig.resolve(spec, root .. "/" .. from)
end

-- Open `rel` with `body`, put the cursor on the first `needle`
-- (plus `offset` columns).
local function open(rel, body, needle, offset)
  tree { [rel] = body }
  vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. rel))
  local lnum = vim.fn.search("\\V" .. vim.fn.escape(needle, "\\"), "cw")
  assert(lnum > 0, "needle not found: " .. needle)
  local col = vim.api.nvim_win_get_cursor(0)[2]
  vim.api.nvim_win_set_cursor(0, { lnum, col + (offset or 0) })
  vim.treesitter.get_parser(0):parse()
end

local function here()
  local pos = vim.api.nvim_win_get_cursor(0)
  return vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), pos[1], pos[2]
end

describe("import-goto", function()
  before_each(function()
    root = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    root = vim.uv.fs_realpath(root)
  end)

  after_each(function()
    vim.cmd "silent! %bwipeout!"
    vim.fn.delete(root, "rf")
  end)

  describe("resolve: relative", function()
    it("probes extensions, .js -> .ts swaps and directory index files", function()
      tree {
        ["src/a.ts"] = "",
        ["src/b.ts"] = "",
        ["src/dir/index.tsx"] = "",
        ["src/style.css"] = "",
        ["main.ts"] = "",
      }
      assert.equals(abs "src/b.ts", resolve("./b", "src/a.ts"))
      assert.equals(abs "src/b.ts", resolve("./b.js", "src/a.ts"))
      assert.equals(abs "src/dir/index.tsx", resolve("./dir", "src/a.ts"))
      assert.equals(abs "src/style.css", resolve("./style.css", "src/a.ts"))
      assert.equals(abs "main.ts", resolve("../main", "src/a.ts"))
    end)

    it("follows a directory's package.json entry before index", function()
      tree {
        ["src/a.ts"] = "",
        ["src/lib/package.json"] = [[{ "main": "./entry.js" }]],
        ["src/lib/entry.ts"] = "",
        ["src/lib/index.ts"] = "",
      }
      assert.equals(abs "src/lib/entry.ts", resolve("./lib", "src/a.ts"))
    end)

    it("doesn't hop a relative import under lib/ to an unrelated src file", function()
      tree {
        ["src/app.ts"] = "",
        ["src/lib/format.js"] = "",
        ["src/format.ts"] = "",
      }
      assert.equals(abs "src/lib/format.js", resolve("./lib/format.js", "src/app.ts"))
    end)

    it("returns nil for a missing file", function()
      tree { ["src/a.ts"] = "" }
      assert.is_nil(resolve("./nope", "src/a.ts"))
    end)
  end)

  describe("resolve: tsconfig", function()
    it("maps `paths` relative to baseUrl, through JSONC comments and trailing commas", function()
      tree {
        ["tsconfig.json"] = [[{
          // comment
          "compilerOptions": {
            "baseUrl": "./src", /* block */
            "paths": { "@app/*": ["app/*"], "@site": ["https://x//y"], },
          },
        }]],
        ["src/app/thing.ts"] = "",
        ["src/app/a.ts"] = "",
      }
      assert.equals(abs "src/app/thing.ts", resolve("@app/thing", "src/app/a.ts"))
    end)

    it("resolves bare specifiers against baseUrl", function()
      tree {
        ["tsconfig.json"] = [[{ "compilerOptions": { "baseUrl": "src" } }]],
        ["src/utils/x.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "src/utils/x.ts", resolve("utils/x", "src/a.ts"))
    end)

    it("inherits `paths` through an extends chain, ${configDir} = the leaf config's dir", function()
      tree {
        ["node_modules/@org/tsconfig/base.json"] = [[{
          "compilerOptions": { "paths": { "~/*": ["${configDir}/src/*"] } }
        }]],
        ["apps/web/tsconfig.json"] = [[{ "extends": "@org/tsconfig/base.json" }]],
        ["apps/web/src/lib/x.ts"] = "",
        ["apps/web/src/a.ts"] = "",
      }
      assert.equals(abs "apps/web/src/lib/x.ts", resolve("~/lib/x", "apps/web/src/a.ts"))
    end)

    it("uses the referenced config of a solution-style tsconfig", function()
      tree {
        ["tsconfig.json"] = [[{ "files": [], "references": [{ "path": "./tsconfig.app.json" }] }]],
        ["tsconfig.app.json"] = [[{ "compilerOptions": { "paths": { "@/*": ["./src/*"] } } }]],
        ["src/x.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "src/x.ts", resolve("@/x", "src/a.ts"))
    end)

    it("picks up a same-second, same-size tsconfig edit", function()
      tree {
        ["tsconfig.json"] = [[{ "compilerOptions": { "paths": { "@a/*": ["./src/*"] } } }]],
        ["src/x.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "src/x.ts", resolve("@a/x", "src/a.ts"))
      local p = root .. "/tsconfig.json"
      local before = vim.uv.fs_stat(p).mtime
      -- Same length, same second; only the nanoseconds move.
      vim.fn.writefile({ [[{ "compilerOptions": { "paths": { "@b/*": ["./src/*"] } } }]] }, p)
      vim.uv.fs_utime(p, before.sec, before.sec + (before.nsec + 1) / 1e9)
      assert.equals(abs "src/x.ts", resolve("@b/x", "src/a.ts"))
    end)

    it("treats /path as root-relative when it isn't absolute on disk", function()
      tree {
        ["tsconfig.json"] = "{}",
        ["src/x.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "src/x.ts", resolve("/src/x", "src/a.ts"))
    end)
  end)

  describe("resolve: package.json imports", function()
    it("maps #subpaths through conditions and stars", function()
      tree {
        ["package.json"] = [[{ "imports": {
          "#db": { "types": "./src/db.ts", "default": "./dist/db.js" },
          "#util/*": "./src/util/*.ts"
        } }]],
        ["src/db.ts"] = "",
        ["src/util/str.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "src/db.ts", resolve("#db", "src/a.ts"))
      assert.equals(abs "src/util/str.ts", resolve("#util/str", "src/a.ts"))
    end)
  end)

  describe("resolve: node_modules", function()
    it("honours `exports`, preferring the types condition over import", function()
      tree {
        ["node_modules/pkg/package.json"] = [[{ "exports": {
          ".": { "import": "./dist/index.mjs", "types": "./dist/index.d.ts" },
          "./feature/*": { "types": "./dist/feature/*.d.ts" }
        } }]],
        ["node_modules/pkg/dist/index.d.ts"] = "",
        ["node_modules/pkg/dist/index.mjs"] = "",
        ["node_modules/pkg/dist/feature/x.d.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "node_modules/pkg/dist/index.d.ts", resolve("pkg", "src/a.ts"))
      assert.equals(abs "node_modules/pkg/dist/feature/x.d.ts", resolve("pkg/feature/x", "src/a.ts"))
    end)

    it("resolves scoped packages and a parent dir's node_modules", function()
      tree {
        ["node_modules/@s/pkg/package.json"] = [[{ "types": "./index.d.ts" }]],
        ["node_modules/@s/pkg/index.d.ts"] = "",
        ["packages/app/src/a.ts"] = "",
      }
      assert.equals(abs "node_modules/@s/pkg/index.d.ts", resolve("@s/pkg", "packages/app/src/a.ts"))
    end)

    it("prefers an @types sibling over a bare-JS entry", function()
      tree {
        ["node_modules/react/package.json"] = [[{ "main": "index.js" }]],
        ["node_modules/react/index.js"] = "",
        ["node_modules/@types/react/index.d.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "node_modules/@types/react/index.d.ts", resolve("react", "src/a.ts"))
    end)

    it("sends node builtins (with or without node:) to @types/node", function()
      tree {
        ["node_modules/@types/node/fs.d.ts"] = "",
        ["src/a.ts"] = "",
      }
      assert.equals(abs "node_modules/@types/node/fs.d.ts", resolve("fs", "src/a.ts"))
      assert.equals(abs "node_modules/@types/node/fs.d.ts", resolve("node:fs", "src/a.ts"))
    end)

    it("hops from a symlinked workspace package's dist/ to its src/", function()
      tree {
        ["packages/lib/package.json"] = [[{ "main": "dist/index.js" }]],
        ["packages/lib/dist/index.js"] = "",
        ["packages/lib/src/index.ts"] = "",
        ["apps/web/a.ts"] = "",
      }
      vim.fn.mkdir(root .. "/node_modules", "p")
      assert(vim.uv.fs_symlink(root .. "/packages/lib", root .. "/node_modules/lib"))
      assert.equals(abs "packages/lib/src/index.ts", resolve("lib", "apps/web/a.ts"))
    end)
  end)

  describe("specifier_at_cursor", function()
    it("reads import, export-from, require and jest.mock paths", function()
      open("a.ts", [[import x from "./one"]], "./one")
      assert.equals("./one", ig.specifier_at_cursor())
      open("b.ts", [[export * from "./two"]], "./two")
      assert.equals("./two", ig.specifier_at_cursor())
      open("c.js", [[const y = require("./three")]], "./three")
      assert.equals("./three", ig.specifier_at_cursor())
      open("d.ts", [[jest.mock("./four", () => ({}))]], "./four")
      assert.equals("./four", ig.specifier_at_cursor())
    end)

    it("works before the buffer has been parsed", function()
      tree { ["a.ts"] = [[import x from "./one"]] }
      vim.cmd.edit(vim.fn.fnameescape(root .. "/a.ts"))
      vim.api.nvim_win_set_cursor(0, { 1, 16 })
      assert.equals("./one", ig.specifier_at_cursor())
    end)

    it("reads paths in .tsx and .jsx buffers", function()
      open("a.tsx", [[import x from "./one"]], "./one")
      assert.equals("./one", ig.specifier_at_cursor())
      open("b.jsx", [[import y from "./two"]], "./two")
      assert.equals("./two", ig.specifier_at_cursor())
    end)

    it("ignores ordinary strings and dynamic template paths", function()
      open("a.ts", [[const s = "./not-a-module"]], "./not")
      assert.is_nil(ig.specifier_at_cursor())
      open("c.ts", [[export default "./not-a-module"]], "./not")
      assert.is_nil(ig.specifier_at_cursor())
      open("b.ts", "const m = import(`./x/${name}`)", "./x")
      assert.is_nil(ig.specifier_at_cursor())
    end)
  end)

  describe("goto_imported_name", function()
    it("jumps to a named export declaration", function()
      tree { ["lib.ts"] = "const pad = 1\n\nexport function foo() {}" }
      open("a.ts", 'import { foo } from "./lib"\nfoo()', "foo()")
      assert.is_true(ig.goto_imported_name())
      local path, row, col = here()
      assert.equals(abs "lib.ts", path)
      assert.same({ 3, 16 }, { row, col })
    end)

    it("follows an aliased re-export to the original declaration", function()
      tree {
        ["impl.ts"] = "export const inner = 1",
        ["index.ts"] = 'export { inner as foo } from "./impl"',
      }
      -- Cursor on the later use (line 2), not the import specifier.
      open("a.ts", 'import { foo } from "./index"\nfoo', "foo")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "impl.ts", path)
      assert.equals(1, row)
    end)

    it("searches `export *` sources", function()
      tree {
        ["impl.ts"] = "\nexport class Foo {}",
        ["index.ts"] = 'export * from "./impl"',
      }
      open("a.ts", 'import { Foo } from "./index"', "Foo")
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "impl.ts", path)
      assert.equals(2, row)
    end)

    it("finds a default export", function()
      tree { ["lib.ts"] = "const x = 1\nexport default x" }
      open("a.ts", 'import thing from "./lib"', "thing")
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "lib.ts", path)
      assert.equals(2, row)
    end)

    it("finds CommonJS exports.name for a destructured require", function()
      tree { ["lib.js"] = "// header\nexports.foo = () => 1" }
      open("a.js", 'const { foo } = require("./lib")\nfoo()', "foo()")
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "lib.js", path)
      assert.equals(2, row)
    end)

    it("prefers a CommonJS declaration over an earlier top-level call", function()
      tree { ["lib.js"] = "foo()\nfunction foo() {}\nmodule.exports = { foo }" }
      open("a.js", 'const { foo } = require("./lib")', "foo")
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "lib.js", path)
      assert.equals(2, row)
    end)

    it("doesn't line-scan an ES module for an unexported namesake", function()
      tree { ["lib.ts"] = "export const bar = 1\nfoo()" }
      open("a.ts", 'import { foo } from "./lib"', "foo")
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "lib.ts", path)
      assert.equals(1, row)
    end)

    it("still line-scans `export =` declaration files", function()
      tree { ["lib.d.ts"] = "declare namespace ns {\n  function foo(): void\n}\nexport = ns" }
      open("a.ts", 'import { foo } from "./lib"', "foo")
      assert.is_true(ig.goto_imported_name())
      local path, row = here()
      assert.equals(abs "lib.d.ts", path)
      assert.equals(2, row)
    end)

    it("reports an :edit failure instead of erroring", function()
      tree { ["b.ts"] = "" }
      open("a.ts", 'import x from "./b"', "./b")
      local hidden, notify, msgs = vim.o.hidden, vim.notify, {}
      vim.o.hidden = false
      vim.notify = function(msg)
        msgs[#msgs + 1] = msg
      end
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { "// edited" })
      local ok, err = pcall(ig.goto_definition, function() end)
      vim.o.hidden, vim.notify = hidden, notify
      assert(ok, err)
      assert.equals(abs "a.ts", (here()))
      assert.matches("E37", msgs[1])
    end)

    it("returns false for a name that isn't imported", function()
      open("a.ts", "const local = 1\nlocal", "local")
      assert.is_false(ig.goto_imported_name())
    end)
  end)
end)
