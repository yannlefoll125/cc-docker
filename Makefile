# Modular cc-docker Makefile. See docs/modular-build-engine/roadmap.md.
# The pre-modular Makefile is frozen at legacy/Makefile.
.PHONY: build stacks install

build:
	./build.sh

# List the available stack modules (name, version, description) — the names you put
# in cc-docker.yml's `modules: [ ... ]`.
stacks:
	@echo "Available stack modules (cc-docker.yml -> modules: [ ... ]):"
	@for f in stack/*/module.yml; do \
		[ -f "$$f" ] || continue; \
		name=$$(basename $$(dirname "$$f")); \
		version=$$(sed -nE 's/^version:[[:space:]]*//p' "$$f" | head -1 | sed -E "s/^[\"']//; s/[\"']$$//"); \
		desc=$$(sed -nE 's/^description:[[:space:]]*//p' "$$f" | head -1); \
		printf '  %-8s %-5s %s\n' "$$name" "$$version" "$$desc"; \
	done

install:
	@grep -q 'init-cc.sh' ~/.bashrc 2>/dev/null && echo "init-cc.sh already sourced in ~/.bashrc" || { \
		printf '\nexport CC_DOCKER_DIR=%s\nsource "$$CC_DOCKER_DIR/init-cc.sh"\n' "$(CURDIR)" >> ~/.bashrc; \
		echo "Added cc-docker to ~/.bashrc"; \
	}
