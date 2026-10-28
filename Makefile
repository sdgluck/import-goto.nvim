# make test  -- fetch deps (once) and run the headless suite
# make deps  -- plenary.nvim + JS/TS treesitter parsers into .deps/
# make lint  -- stylua --check
DEPS := .deps
PARSERS := javascript typescript tsx

.PHONY: test deps lint clean

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua', sequential = true }"

deps: $(DEPS)/plenary.nvim $(addprefix $(DEPS)/site/parser/,$(addsuffix .so,$(PARSERS)))

$(DEPS)/plenary.nvim:
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

$(DEPS)/src/tree-sitter-javascript:
	git clone --depth 1 https://github.com/tree-sitter/tree-sitter-javascript $@

$(DEPS)/src/tree-sitter-typescript:
	git clone --depth 1 https://github.com/tree-sitter/tree-sitter-typescript $@

# Parsers are just parser.c (+ scanner.c) compiled to a shared object that
# Neovim finds on 'runtimepath' under parser/.
$(DEPS)/site/parser/javascript.so: | $(DEPS)/src/tree-sitter-javascript
	mkdir -p $(@D)
	cc -shared -fPIC -O2 -I$|/src $|/src/parser.c $|/src/scanner.c -o $@

$(DEPS)/site/parser/typescript.so: | $(DEPS)/src/tree-sitter-typescript
	mkdir -p $(@D)
	cc -shared -fPIC -O2 -I$|/typescript/src $|/typescript/src/parser.c $|/typescript/src/scanner.c -o $@

$(DEPS)/site/parser/tsx.so: | $(DEPS)/src/tree-sitter-typescript
	mkdir -p $(@D)
	cc -shared -fPIC -O2 -I$|/tsx/src $|/tsx/src/parser.c $|/tsx/src/scanner.c -o $@

lint:
	stylua --check lua tests

clean:
	rm -rf $(DEPS)
