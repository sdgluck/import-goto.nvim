# import-goto.nvim

`gd` on a JS/TS import path opens the file it points at — resolved the way
TypeScript and Node resolve it — instantly, and without an LSP.

```ts
import { Button } from "@ui/button";      // tsconfig paths → src/ui/button.tsx
import { db } from "#db";                 // package.json "imports"
import { thing } from "@acme/shared";     // workspace pkg → packages/shared/src/index.ts (not dist/)
import { readFile } from "node:fs";       // → @types/node/fs.d.ts
jest.mock("../api/client");               // jest/vitest mock paths too
```

## Why

- **No waiting.** tsserver can take many seconds to attach in a big monorepo;
  path resolution doesn't need it.
- **Source, not build output.** A workspace package whose entry is
  `dist/index.js` lands on `src/index.ts`.
- **Works without an LSP.** In plain-JS directories, `gd` on an imported name
  (or any later use of it, or `ns.x` on a namespace import) jumps to the
  export in the resolved module, following `export { x as y } from`,
  `export *`, `export default x`, re-exported imports, and CommonJS
  `exports.x`. `<C-t>` comes back, as with LSP `gd`.
- **Falls back cleanly.** Anything it can't resolve (e.g. bundler-only
  aliases) goes to your LSP's definition, then to built-in `gd`.

## Resolution

| Specifier | Resolved via |
|---|---|
| `./x` `../x` | extension probing, `.js`→`.ts` swaps, `index.*`, a directory's `package.json` entry; bundler `?query` suffixes dropped |
| `@alias/x` `~/x` | tsconfig/jsconfig `paths` + `baseUrl`, following `extends` (files and packages), `${configDir}`, solution-style `references` |
| `/x` | absolute, else root-relative to the project |
| `#internal` | `package.json` `imports` |
| `pkg` `@scope/pkg/sub` | `node_modules`, honouring `exports` conditions; `@types/*` siblings; `node:` builtins via `@types/node` |

Not handled (falls back to the LSP): Yarn PnP, `typesVersions`, `rootDirs`,
`moduleSuffixes`, `null` targets in `exports`, vite/webpack `resolve.alias`.

## Install

Requires Neovim 0.11+. The `javascript`, `typescript` and `tsx` treesitter
parsers are needed for the cursor features (path resolution itself needs none).

```lua
-- lazy.nvim
{
  "sdgluck/import-goto.nvim",
  ft = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  opts = {},
}
```

## Configuration

Defaults:

```lua
require("import-goto").setup {
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  gd = true,   -- buffer-local gd: import path → file, else LSP definition, else built-in gd
  gf = true,   -- set 'includeexpr' so gf / <C-w>f resolve specifiers too
  conditions = { "source", "types", "typings", "import", "module", "require", "node", "default" },
  out_dirs = { "dist", "build", "out", "lib" },  -- build dirs to hop back to src/ from
}
```

If you set `gd` yourself in an `LspAttach` handler, it will replace this
plugin's mapping. Wrap your handler instead:

```lua
vim.keymap.set("n", "gd", function()
  require("import-goto").goto_definition(vim.lsp.buf.definition)
end, { buffer = args.buf })
```

## API

```lua
local ig = require "import-goto"
ig.resolve(spec, from_file)      -- absolute path or nil
ig.specifier_at_cursor()         -- module path under the cursor, or nil
ig.goto_imported_name()          -- jump to an imported name's export; false if not an import
ig.goto_definition(fallback)     -- the gd behaviour, with your own fallback
```

`:checkhealth import-goto` reports missing parsers.

## Development

```sh
make test   # fetches plenary + builds the JS/TS parsers into .deps/, then runs the suite
make lint
```

Set `PLENARY_DIR` / `PARSER_DIR` to reuse copies you already have.

## License

MIT
