# import-goto.nvim

`gd` on a JS/TS import path opens the file it points at, without an LSP.

```ts
import { Button } from "@ui/button";      // tsconfig paths → src/ui/button.tsx
import { db } from "#db";                 // package.json "imports"
import { thing } from "@acme/shared";     // workspace package → packages/shared/src/index.ts
import { readFile } from "node:fs";       // → @types/node/fs.d.ts
jest.mock("../api/client");               // jest/vitest mock paths
```

- `gd` on an import path opens the resolved file.
- `gd` on an imported name (or `ns.name`) opens its export, when no LSP is attached.
- `gf` / `<C-w>f` resolve import paths the same way.
- Anything unresolved falls back to the LSP's definition, then built-in `gd`.

## Supported specifiers

| Specifier | Example |
|---|---|
| Relative | `./x`, `../x.js`, `./dir`, `./icon.svg?react` |
| tsconfig/jsconfig `paths` and `baseUrl` | `@alias/x`, `~/x` |
| Absolute or project-root | `/src/x` |
| package.json `imports` | `#internal` |
| node_modules, `@types`, Node builtins | `pkg`, `@scope/pkg/sub`, `node:fs` |

## Install

Requires Neovim 0.11+ and the `javascript`, `typescript` and `tsx` treesitter parsers.

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
  gd = true,   -- map buffer-local gd
  gf = true,   -- set 'includeexpr' for gf / <C-w>f
  conditions = { "source", "types", "typings", "import", "module", "require", "node", "default" },
  out_dirs = { "dist", "build", "out", "lib" },  -- build dirs to map back to src/
}
```

If you map `gd` yourself (e.g. in `LspAttach`), call the plugin from it:

```lua
vim.keymap.set("n", "gd", function()
  require("import-goto").goto_definition(vim.lsp.buf.definition)
end, { buffer = args.buf })
```

## API

```lua
local ig = require "import-goto"
ig.resolve(spec, from_file)      -- absolute path or nil
ig.specifier_at_cursor()         -- import path under the cursor, or nil
ig.goto_imported_name()          -- jump to an imported name's export; false if not an import
ig.goto_definition(fallback)     -- the gd behaviour, with your own fallback
```

`:checkhealth import-goto` checks the Neovim version and parsers.

## Development

```sh
make test
make lint
```

## License

MIT
