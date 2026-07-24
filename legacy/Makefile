
build:
	./build.sh

install:
	@grep -q 'init-cc.sh' ~/.bashrc 2>/dev/null && echo "init-cc.sh already sourced in ~/.bashrc" || { \
		printf '\nexport CC_DOCKER_DIR=%s\nsource "$$CC_DOCKER_DIR/init-cc.sh"\n' "$(CURDIR)" >> ~/.bashrc; \
		echo "Added cc-docker to ~/.bashrc"; \
	}