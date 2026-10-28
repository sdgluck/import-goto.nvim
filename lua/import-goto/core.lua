-- gd on an import/require path: open the file it points at.
--
-- Handles every specifier shape, resolved the way TS/Node would:
--   "./x" "../x"        relative, with extension / index / .js->.ts probing
--   "/abs/x"            absolute, else relative to the project root
--   "@alias/x" "~/x"    tsconfig/jsconfig `paths` + `baseUrl` (follows `extends`
--                       chains, `${configDir}`, solution-style `references`)
--   "#internal"         package.json `imports`
--   "pkg" "@s/pkg/sub"  node_modules, honouring `exports`; "fs"/"node:fs" fall
--                       through to @types/node
--   "./x.css" etc.      any existing file, whatever its extension
-- Workspace packages whose entry points at a build artifact (dist/index.js)
-- land on the matching source file (src/index.ts) instead.
--
-- Anything this can't resolve (bundler-only aliases from vite/webpack configs)
-- falls back to the LSP's definition, which is what gd did before.
--
-- With no LSP attached (plain-JS dirs with no typescript package), gd on an
-- imported name -- or a use of one -- jumps to its export in the resolved
-- module, following re-exports and `export *`.
local M = {}

local uv = vim.uv

local EXTS = { ".ts", ".tsx", ".d.ts", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".json" }

-- TS ESM imports name the emitted file ("./foo.js") while the source is foo.ts.
local EXT_SWAPS = {
  [".js"] = { ".ts", ".tsx" },
  [".jsx"] = { ".tsx" },
  [".mjs"] = { ".mts" },
  [".cjs"] = { ".cts" },
}

-- Condition order for `exports`/`imports` and build-output dir names come from
-- setup() (see config.lua).
local config = require "import-goto.config"

-- Calls whose first argument is a module path.
local function is_module_call(callee)
  return callee == "require"
    or callee == "import"
    or callee:match "%.mock$"
    or callee:match "%.doMock$"
    or callee:match "%.unmock$"
    or callee:match "%.requireActual$"
    or callee:match "%.requireMock$"
    or callee:match "%.importActual$"
    or callee:match "%.importMock$"
    or callee:match "^require%.resolve$"
end

local function stat_type(p)
  local s = uv.fs_stat(p)
  return s and s.type
end

local function is_file(p)
  return stat_type(p) == "file"
end

local function is_dir(p)
  return stat_type(p) == "directory"
end

local function join(dir, rel)
  if rel:sub(1, 1) == "/" then
    return vim.fs.normalize(rel)
  end
  return vim.fs.normalize(vim.fs.joinpath(dir, rel))
end

-- JSONC (tsconfig) -> Lua. Strips comments and trailing commas outside strings;
-- plain package.json passes through untouched.
local function strip_jsonc(s)
  local out, i, n = {}, 1, #s
  local in_str = false
  while i <= n do
    local c = s:sub(i, i)
    if in_str then
      out[#out + 1] = c
      if c == "\\" then
        out[#out + 1] = s:sub(i + 1, i + 1)
        i = i + 1
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
      out[#out + 1] = c
    elseif s:sub(i, i + 1) == "//" then
      i = (s:find("\n", i, true) or n + 1) - 1
    elseif s:sub(i, i + 1) == "/*" then
      i = (s:find("*/", i + 2, true) or n) + 1
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  -- Comments are gone, so a trailing comma is now just `,` + whitespace + `}`/`]`.
  -- Second string-aware pass so a "," inside a string value survives.
  local src, res = table.concat(out), {}
  in_str, i, n = false, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if in_str then
      res[#res + 1] = c
      if c == "\\" then
        res[#res + 1] = src:sub(i + 1, i + 1)
        i = i + 1
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
      res[#res + 1] = c
    elseif not (c == "," and src:match("^%s*[}%]]", i + 1)) then
      res[#res + 1] = c
    end
    i = i + 1
  end
  return table.concat(res)
end

-- Parsed JSON files, invalidated by mtime (to the nanosecond: two quick
-- same-size edits share a second) so editing a tsconfig takes effect.
local json_cache = {}

local function read_json(path)
  local s = uv.fs_stat(path)
  if not s or s.type ~= "file" then
    return nil
  end
  local hit = json_cache[path]
  if hit and hit.sec == s.mtime.sec and hit.nsec == s.mtime.nsec and hit.size == s.size then
    return hit.value
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read "*a"
  fd:close()
  local ok, value = pcall(vim.json.decode, strip_jsonc(text), { luanil = { object = true, array = true } })
  value = ok and type(value) == "table" and value or nil
  json_cache[path] = { sec = s.mtime.sec, nsec = s.mtime.nsec, size = s.size, value = value }
  return value
end

-- First usable string out of an exports/imports target (string, condition
-- object, or fallback array).
local function pick(target)
  if type(target) == "string" then
    return target
  end
  if type(target) ~= "table" then
    return nil
  end
  if vim.islist(target) then
    for _, t in ipairs(target) do
      local r = pick(t)
      if r then
        return r
      end
    end
    return nil
  end
  for _, c in ipairs(config.options.conditions) do
    if target[c] ~= nil then
      local r = pick(target[c])
      if r then
        return r
      end
    end
  end
  for _, v in pairs(target) do
    local r = pick(v)
    if r then
      return r
    end
  end
end

-- Look `key` up in a subpath map (`exports`, `imports`, tsconfig `paths`):
-- exact key first, then the `*` pattern with the longest prefix.
-- Returns the raw target plus the text the `*` matched.
local function match_pattern_map(map, key)
  if map[key] ~= nil then
    return map[key], nil
  end
  local best, best_len, star
  for pat, target in pairs(map) do
    local pre, post = pat:match "^(.-)%*(.*)$"
    if
      pre
      and #key >= #pre + #post
      and key:sub(1, #pre) == pre
      and (post == "" or key:sub(-#post) == post)
      and #pre > (best_len or -1)
    then
      best, best_len, star = target, #pre, key:sub(#pre + 1, #key - #post)
    end
  end
  return best, star
end

local function fill_star(s, star)
  if not star then
    return s
  end
  return (s:gsub("%*", function()
    return star
  end))
end

local resolve_file

-- A package.json's entry point for its root ("pkg", no subpath).
local function package_root_entry(pkg)
  local exp = pkg.exports
  if exp ~= nil then
    if type(exp) == "table" and not vim.islist(exp) then
      local has_subpaths = false
      for k in pairs(exp) do
        if k:sub(1, 1) == "." then
          has_subpaths = true
          break
        end
      end
      if has_subpaths then
        exp = exp["."]
      end
    end
    local e = pick(exp)
    if e then
      return e
    end
  end
  for _, field in ipairs { "source", "types", "typings", "module", "main" } do
    if type(pkg[field]) == "string" then
      return pkg[field]
    end
  end
end

-- A build artifact in a workspace package (dist/index.js, lib/foo.d.ts) is
-- rarely what you want to read: hop to the matching source file if one exists.
-- Only outside node_modules; published packages don't ship their sources.
-- Applied to package entry points only: a relative "./lib/x.js" in a source
-- tree means that file, not a sibling src/x.ts.
local function prefer_source(path)
  local real = uv.fs_realpath(path) or path
  if real:find("/node_modules/", 1, true) then
    return real
  end
  if not (real:match "%.d%.[mc]?ts$" or real:match "%.[mc]?js$") then
    return real
  end
  for _, out in ipairs(config.options.out_dirs) do
    local pre, rest = real:match("^(.*)/" .. vim.pesc(out) .. "/(.*)$")
    if pre then
      rest = rest:gsub("%.d%.[mc]?ts$", ""):gsub("%.[mc]?js$", "")
      for _, root in ipairs { pre .. "/src/", pre .. "/" } do
        for _, e in ipairs { ".ts", ".tsx", ".mts", ".cts", "/index.ts", "/index.tsx" } do
          if is_file(root .. rest .. e) then
            return root .. rest .. e
          end
        end
      end
    end
  end
  return real
end

-- `base` as written, then with extensions, then as a directory (package.json
-- entry or index file). Mirrors TS's module resolution probing order.
function resolve_file(base, depth)
  depth = depth or 0
  if depth > 4 then
    return nil
  end
  if is_file(base) then
    return base
  end
  local stem, ext = base:match "^(.*)(%.[mc]?jsx?)$"
  if stem then
    for _, e in ipairs(EXT_SWAPS[ext] or {}) do
      if is_file(stem .. e) then
        return stem .. e
      end
    end
  end
  for _, e in ipairs(EXTS) do
    if is_file(base .. e) then
      return base .. e
    end
  end
  if is_dir(base) then
    local pkg = read_json(base .. "/package.json")
    local entry = pkg and package_root_entry(pkg)
    if entry then
      local p = join(base, entry)
      if p ~= vim.fs.normalize(base) then
        local r = resolve_file(p, depth + 1)
        if r then
          return prefer_source(r)
        end
      end
    end
    for _, e in ipairs(EXTS) do
      if is_file(base .. "/index" .. e) then
        return base .. "/index" .. e
      end
    end
  end
end

-- `extends` may name a file ("./base.json", "../tsconfig") or a package
-- ("@org/tsconfig/app.json", "@tsconfig/node20").
local function resolve_extends(spec, dir)
  local function as_config(p)
    if is_file(p) then
      return p
    end
    if is_file(p .. ".json") then
      return p .. ".json"
    end
    if is_dir(p) and is_file(p .. "/tsconfig.json") then
      return p .. "/tsconfig.json"
    end
  end
  if spec:match "^%.%.?/" or spec:sub(1, 1) == "/" then
    return as_config(join(dir, spec))
  end
  for d in vim.fs.parents(dir .. "/x") do
    local p = as_config(d .. "/node_modules/" .. spec)
    if p then
      return p
    end
  end
end

-- Effective compilerOptions.paths/baseUrl for one config file, following its
-- `extends` chain. Each setting remembers the directory it's relative to.
local function load_tsconfig(path, top_dir, seen)
  seen = seen or {}
  if seen[path] then
    return {}
  end
  seen[path] = true
  local cfg = read_json(path)
  if not cfg then
    return {}
  end
  local dir = vim.fs.dirname(path)
  top_dir = top_dir or dir
  local result = {}

  local exts = cfg.extends
  if type(exts) == "string" then
    exts = { exts }
  end
  for _, e in ipairs(type(exts) == "table" and exts or {}) do
    local p = resolve_extends(e, dir)
    if p then
      result = vim.tbl_extend("force", result, load_tsconfig(p, top_dir, seen))
    end
  end

  local function sub(s)
    return (s:gsub("%${configDir}", function()
      return top_dir
    end))
  end
  local co = cfg.compilerOptions or {}
  if type(co.baseUrl) == "string" then
    result.base_url = join(dir, sub(co.baseUrl))
  end
  if type(co.paths) == "table" then
    result.paths = co.paths
    result.paths_dir = dir
    result.sub = sub
  end
  result.references = cfg.references
  result.dir = dir
  return result
end

-- The nearest tsconfig/jsconfig above `file`, with solution-style configs
-- ({ "files": [], "references": [...] }) resolved into whichever referenced
-- config actually carries `paths`.
local function project_config(file)
  for dir in vim.fs.parents(file) do
    for _, name in ipairs { "tsconfig.json", "jsconfig.json" } do
      local p = dir .. "/" .. name
      if is_file(p) then
        local cfg = load_tsconfig(p)
        if not cfg.paths and type(cfg.references) == "table" then
          for _, ref in ipairs(cfg.references) do
            if type(ref) == "table" and type(ref.path) == "string" then
              local rp = join(dir, ref.path)
              if is_dir(rp) then
                rp = rp .. "/tsconfig.json"
              end
              local rc = is_file(rp) and load_tsconfig(rp)
              if rc and rc.paths then
                rc.dir = dir
                return rc
              end
            end
          end
        end
        return cfg
      end
    end
  end
  return {}
end

local function nearest(file, name)
  for dir in vim.fs.parents(file) do
    if is_file(dir .. "/" .. name) then
      return dir .. "/" .. name
    end
  end
end

local function resolve_tsconfig_paths(spec, cfg)
  if not cfg.paths then
    return nil
  end
  local targets, star = match_pattern_map(cfg.paths, spec)
  if type(targets) == "string" then
    targets = { targets }
  end
  if type(targets) ~= "table" then
    return nil
  end
  local base = cfg.base_url or cfg.paths_dir
  for _, t in ipairs(targets) do
    if type(t) == "string" then
      local r = resolve_file(join(base, fill_star(cfg.sub(t), star)))
      if r then
        return r
      end
    end
  end
end

-- "#foo" -> package.json "imports".
local function resolve_subpath_import(spec, file)
  local pj = nearest(file, "package.json")
  local pkg = pj and read_json(pj)
  if not (pkg and type(pkg.imports) == "table") then
    return nil
  end
  local target, star = match_pattern_map(pkg.imports, spec)
  local t = pick(target)
  if not t then
    return nil
  end
  t = fill_star(t, star)
  if t:match "^%." then
    return resolve_file(join(vim.fs.dirname(pj), t))
  end
  return M.resolve(t, pj)
end

local function split_package(spec)
  local name, sub
  if spec:sub(1, 1) == "@" then
    name, sub = spec:match "^(@[^/]+/[^/]+)/?(.*)$"
  else
    name, sub = spec:match "^([^/]+)/?(.*)$"
  end
  return name, sub or ""
end

local function resolve_package(spec, file)
  spec = spec:gsub("^node:", "")
  local name, sub = split_package(spec)
  if not name then
    return nil
  end
  local types_name = "@types/" .. name:gsub("^@", ""):gsub("/", "__")

  -- A bare-JS package ("react" -> index.js) with an @types sibling: go to the
  -- declarations instead, as tsserver does.
  local function types_for(nm)
    local td = nm .. types_name
    if is_dir(td) then
      return resolve_file(sub == "" and td or td .. "/" .. sub)
    end
  end
  local function prefer_types(r, nm)
    if r and r:match "%.[mc]?js$" then
      return types_for(nm) or r
    end
    return r
  end

  for dir in vim.fs.parents(file) do
    local nm = dir .. "/node_modules/"
    local pkg_dir = nm .. name
    if is_dir(pkg_dir) then
      local pkg = read_json(pkg_dir .. "/package.json") or {}
      if sub == "" then
        local r = prefer_types(resolve_file(pkg_dir), nm)
        if r then
          return r
        end
      else
        local exp = pkg.exports
        if type(exp) == "table" and not vim.islist(exp) then
          local target, star = match_pattern_map(exp, "./" .. sub)
          local t = pick(target)
          if t then
            local r = prefer_types(resolve_file(join(pkg_dir, fill_star(t, star))), nm)
            if r then
              return r
            end
          end
        end
        local r = prefer_types(resolve_file(pkg_dir .. "/" .. sub), nm)
        if r then
          return r
        end
      end
    end
    -- Types-only packages ("@types/lodash") and Node builtins ("fs" lives
    -- in @types/node/fs.d.ts).
    local r = types_for(nm)
    if r then
      return r
    end
    if is_dir(nm .. "@types/node") then
      local r = resolve_file(nm .. "@types/node/" .. spec)
      if r then
        return r
      end
    end
  end
end

-- Resolve a module specifier written in `file` to a path on disk, or nil.
function M.resolve(spec, file)
  local dir = vim.fs.dirname(file)
  local found

  if spec:match "^%.%.?/" or spec == "." or spec == ".." then
    found = resolve_file(join(dir, spec))
  elseif spec:sub(1, 1) == "#" then
    found = resolve_subpath_import(spec, file)
    found = found and prefer_source(found)
  else
    local cfg = project_config(file)
    found = resolve_tsconfig_paths(spec, cfg)
    if not found and spec:sub(1, 1) == "/" then
      -- A true absolute path, else root-relative ("/src/x" in Next/Vite).
      found = resolve_file(spec) or (cfg.dir and resolve_file(join(cfg.dir, spec:sub(2))))
    end
    if not found and cfg.base_url then
      found = resolve_file(join(cfg.base_url, spec))
    end
    if not found then
      found = resolve_package(spec, file)
      found = found and prefer_source(found)
    end
  end

  return found and (uv.fs_realpath(found) or found)
end

-- Named node under the cursor. get_node() doesn't parse, so without
-- treesitter highlighting (or before 0.12's async parse lands) the tree would
-- be missing or stale.
local function node_at_cursor()
  local ok, parser = pcall(vim.treesitter.get_parser, 0, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  parser:parse()
  local got, node = pcall(vim.treesitter.get_node)
  return got and node or nil
end

-- The module specifier under the cursor, or nil when the cursor isn't on the
-- path string of an import/export/require/import()/jest.mock(...).
function M.specifier_at_cursor()
  local node = node_at_cursor()
  if not node then
    return nil
  end
  for _ = 1, 2 do
    local t = node:type()
    if t == "string" or t == "template_string" then
      break
    end
    node = node:parent()
    if not node then
      return nil
    end
  end
  local t = node:type()
  if t ~= "string" and t ~= "template_string" then
    return nil
  end
  -- `./x/${name}` can't be resolved statically.
  for child in node:iter_children() do
    if child:type() == "template_substitution" then
      return nil
    end
  end

  local parent = node:parent()
  local pt = parent and parent:type()
  -- `export default "x"` is an export_statement too: only its `source` counts.
  local is_module = pt == "import_require_clause"
    or (pt == "import_statement" or pt == "export_statement") and parent:field("source")[1] == node
  if not is_module and pt == "arguments" and parent:named_child(0) == node then
    local call = parent:parent()
    local fn = call and call:type() == "call_expression" and call:field("function")[1]
    is_module = fn and is_module_call(vim.treesitter.get_node_text(fn, 0)) and true or false
  end
  if not is_module then
    return nil
  end

  local text = vim.treesitter.get_node_text(node, 0)
  return text:sub(2, -2)
end

-- ── Imported names, without an LSP ──────────────────────────────────────────
-- A plain-JS directory (or any buffer before tsserver attaches) has no LSP,
-- so gd on `foo` in `import { foo } from "./x.js"` -- or on
-- any later use of `foo` -- would otherwise be vim's built-in gd, which just
-- lands on the import line. Resolve the module and find the export instead.
-- Purely syntactic: a local that shadows an import still jumps to the import.

local function node_text(node, src)
  return vim.treesitter.get_node_text(node, src)
end

local function unquote(s)
  return (s:gsub("^[\"'`](.*)[\"'`]$", "%1"))
end

local function lang_for(path)
  if path:match "%.tsx$" then
    return "tsx"
  end
  if path:match "%.[mc]?ts$" then
    return "typescript"
  end
  return "javascript"
end

-- The module + exported name that `word` was imported as at the top level of
-- the buffer. name: an export name, "default", or nil for the whole module
-- (`import * as ns`, `const ns = require(...)`).
local function imported_binding(root, word)
  local function children(node, ty)
    local out = {}
    for c in node:iter_children() do
      if c:type() == ty then
        out[#out + 1] = c
      end
    end
    return out
  end

  for stmt in root:iter_children() do
    local st = stmt:type()
    local src = stmt:field("source")[1]
    if st == "import_statement" and src then
      local spec = unquote(node_text(src, 0))
      for _, clause in ipairs(children(stmt, "import_clause")) do
        for c in clause:iter_children() do
          local ct = c:type()
          if ct == "identifier" and node_text(c, 0) == word then
            return spec, "default"
          elseif ct == "namespace_import" then
            for _, id in ipairs(children(c, "identifier")) do
              if node_text(id, 0) == word then
                return spec, nil
              end
            end
          elseif ct == "named_imports" then
            for _, s in ipairs(children(c, "import_specifier")) do
              local name, alias = s:field("name")[1], s:field("alias")[1]
              if name and node_text(alias or name, 0) == word then
                return spec, unquote(node_text(name, 0))
              end
            end
          end
        end
      end
    elseif st == "lexical_declaration" or st == "variable_declaration" then
      -- const x = require("./x") / const { a, b: c } = require("./x")
      for _, decl in ipairs(children(stmt, "variable_declarator")) do
        local value, pat = decl:field("value")[1], decl:field("name")[1]
        local fn = value and value:type() == "call_expression" and value:field("function")[1]
        local args = fn and node_text(fn, 0) == "require" and value:field("arguments")[1]
        local arg = args and args:named_child(0)
        if arg and arg:type() == "string" and pat then
          local spec = unquote(node_text(arg, 0))
          if pat:type() == "identifier" and node_text(pat, 0) == word then
            return spec, nil
          elseif pat:type() == "object_pattern" then
            for p in pat:iter_children() do
              local pt = p:type()
              if pt == "shorthand_property_identifier_pattern" and node_text(p, 0) == word then
                return spec, word
              elseif pt == "pair_pattern" then
                local key, val = p:field("key")[1], p:field("value")[1]
                if key and val and node_text(val, 0) == word then
                  return spec, unquote(node_text(key, 0))
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Name nodes a declaration introduces (function/class/type/enum/const ...).
local function declared_names(decl)
  local t = decl:type()
  if t == "ambient_declaration" then
    local inner = decl:named_child(0)
    return inner and declared_names(inner) or {}
  end
  if t == "lexical_declaration" or t == "variable_declaration" then
    local out = {}
    for c in decl:iter_children() do
      local n = c:type() == "variable_declarator" and c:field("name")[1]
      if n and n:type() == "identifier" then
        out[#out + 1] = n
      end
    end
    return out
  end
  local n = decl:field("name")[1]
  return n and { n } or {}
end

local find_export

-- Where `name` is exported from `path`: { path, row, col }, with row/col nil
-- for "the file itself". Follows `export { x } from` / `export * from`.
function find_export(path, name, depth)
  depth = depth or 0
  if depth > 8 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local src = table.concat(lines, "\n")
  local parsed, parser = pcall(vim.treesitter.get_string_parser, src, lang_for(path))
  if not parsed then
    return nil
  end
  local root = parser:parse()[1]:root()
  local function at(node)
    local row, col = node:range()
    return { path = path, row = row, col = col }
  end

  -- Top-level declaration of a local name, for `export { local as name }`.
  local function local_decl(local_name)
    for stmt in root:iter_children() do
      local decl = stmt:type() == "export_statement" and stmt:field("declaration")[1] or stmt
      for _, n in ipairs(declared_names(decl)) do
        if node_text(n, src) == local_name then
          return at(n)
        end
      end
    end
  end

  local star_sources, esm = {}, false
  for stmt in root:iter_children() do
    if stmt:type() == "export_statement" then
      local source = stmt:field("source")[1]
      local spec = source and unquote(node_text(source, src))
      local clause, is_default, ns
      for c in stmt:iter_children() do
        local ct = c:type()
        if ct == "export_clause" then
          clause = c
        elseif ct == "default" then
          is_default = true
        elseif ct == "namespace_export" then
          ns = c
        end
      end

      if name == "default" and is_default and not spec then
        return at(stmt)
      end
      local decl = stmt:field("declaration")[1]
      -- Everything but TS's `export = x`, whose members the line scan finds.
      if decl or clause or is_default or ns or spec then
        esm = true
      end
      if decl and name ~= "default" then
        for _, n in ipairs(declared_names(decl)) do
          if node_text(n, src) == name then
            return at(n)
          end
        end
      end
      if clause then
        for s in clause:iter_children() do
          if s:type() == "export_specifier" then
            local sname, alias = s:field("name")[1], s:field("alias")[1]
            if sname and unquote(node_text(alias or sname, src)) == name then
              local inner = unquote(node_text(sname, src))
              if spec then
                local target = M.resolve(spec, path)
                return target and find_export(target, inner, depth + 1) or at(s)
              end
              return local_decl(inner) or at(s)
            end
          end
        end
      end
      if ns and spec then
        for c in ns:iter_children() do
          if c:type() == "identifier" and node_text(c, src) == name then
            local target = M.resolve(spec, path)
            return target and { path = target } or at(c)
          end
        end
      elseif spec and not clause and not decl then
        star_sources[#star_sources + 1] = spec
      end
    end
  end

  -- `export * from` never re-exports default.
  if name ~= "default" then
    for _, spec in ipairs(star_sources) do
      local target = M.resolve(spec, path)
      local r = target and find_export(target, name, depth + 1)
      if r and r.row then
        return r
      end
    end
  end

  -- An ES module's exports are all above; scanning lines would only find
  -- unexported namesakes.
  if esm then
    return nil
  end

  -- CommonJS: exports.name = ..., module.exports = { name }, or any
  -- declaration that happens to carry the name (also `declare module "fs"`
  -- blocks and `export =` namespaces in .d.ts files). Declarations first, so
  -- a top-level call `name()` above them doesn't win.
  local esc = vim.pesc(name)
  local passes = {
    {
      "exports%." .. esc .. "%f[^%w_$]",
      "%f[%w_$](function%*?%s+" .. esc .. "%f[^%w_$])",
      "%f[%w_$](class%s+" .. esc .. "%f[^%w_$])",
    },
    { "^%s*" .. esc .. "%f[^%w_$]%s*[,:(}]" },
  }
  for _, pats in ipairs(passes) do
    for i, line in ipairs(lines) do
      for _, pat in ipairs(pats) do
        local s = line:find(pat)
        if s then
          return { path = path, row = i - 1, col = s - 1 }
        end
      end
    end
  end
end

-- Open `path` (at 0-based row/col when given), leaving a jumplist entry. An
-- :edit failure (E37 with 'nohidden' and a modified buffer) is reported as a
-- message rather than a Lua error out of the mapping.
local function jump(path, row, col)
  vim.cmd "normal! m'"
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
  if not ok then
    vim.notify((tostring(err):gsub("^Vim:", "")), vim.log.levels.ERROR)
    return
  end
  if row then
    pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col })
  end
end

-- gd on an imported name (import specifier or a later use of it): jump to
-- its export in the resolved module. Returns false when the word under the
-- cursor isn't an import binding or the module doesn't resolve.
function M.goto_imported_name()
  local node = node_at_cursor()
  if not node then
    return false
  end
  local nt = node:type()
  if
    nt ~= "identifier"
    and nt ~= "type_identifier"
    and nt ~= "shorthand_property_identifier"
    and nt ~= "shorthand_property_identifier_pattern"
  then
    return false
  end
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return false
  end
  local spec, name = imported_binding(node:tree():root(), node_text(node, 0))
  local target = spec and M.resolve(spec, file)
  if not target then
    return false
  end
  local loc = (name and find_export(target, name)) or { path = target }
  jump(loc.path, loc.row, loc.col)
  return true
end

-- gd entry point: on a module path, open the file it resolves to; otherwise
-- (or when it doesn't resolve and an LSP is attached) run `fallback`. With no
-- LSP, an imported name jumps to its export before falling back.
function M.goto_definition(fallback)
  local has_lsp = #vim.lsp.get_clients { bufnr = 0, method = "textDocument/definition" } > 0
  local spec = M.specifier_at_cursor()
  if not spec then
    if not has_lsp and M.goto_imported_name() then
      return
    end
    return fallback()
  end
  local file = vim.api.nvim_buf_get_name(0)
  local target = file ~= "" and M.resolve(spec, file)
  if target then
    jump(target)
    return
  end
  if has_lsp then
    return fallback()
  end
  vim.notify("Can't resolve module: " .. spec, vim.log.levels.WARN)
end

return M
