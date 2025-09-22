.PHONY: lint help

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| cut -d ':' -f 1,2 \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: shellcheck

.PHONY: shellcheck
shellcheck:
	@which shellcheck >/dev/null 2>&1 || { \
		echo "Error: shellcheck is not installed"; \
		echo ""; \
		echo "To install shellcheck:"; \
		echo "  Ubuntu/Debian: apt-get install shellcheck"; \
		echo "  macOS:         brew install shellcheck"; \
		echo "  Fedora/RHEL:   dnf install shellcheck"; \
		echo ""; \
		exit 1; \
	}
	@shellcheck_version=$$(shellcheck --version | grep '^version:' | awk '{print $$2}'); \
	echo "Using shellcheck version: $$shellcheck_version"
	@echo "Running shellcheck on all .sh files..."
	@find . -name "*.sh" -type f -exec shellcheck {} \;
	@echo "Shellcheck completed successfully"
