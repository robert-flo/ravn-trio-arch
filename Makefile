# ═══════════════════════════════════════════════════════════════
# 📦 RAVN-SESSIONIZER PACKAGE - Maintainer command center
# ═══════════════════════════════════════════════════════════════
# 🎯 Purpose: Build, install, validate, and clean the Arch package
# 📎 Details: Package, Git, and alias workflows live in ./make/

.DEFAULT_GOAL := help

RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[0;33m
BLUE := \033[0;34m
CYAN := \033[0;36m
DIM := \033[2m
NC := \033[0m

include make/package.mk
include make/git.mk
include make/aliases.mk

# ═══════════════════════════════════════════════════════════════
# 🧭 HELP - Show the available package workflows
# ═══════════════════════════════════════════════════════════════
.PHONY: help
help: ## Show all ravn-trio package commands
	@printf "\n"
	@printf "$(CYAN)═════════════════════════════════════════════════════════════════════════════════\n$(NC)"
	@printf "$(CYAN)  📦 ravn-trio · package maintainer command center\n$(NC)"
	@printf "$(CYAN)═════════════════════════════════════════════════════════════════════════════════\n$(NC)"
	@printf "\n"
	@printf "  $(DIM)Build locally, validate in disposable containers, and keep the checkout clean.\n$(NC)"
	@printf "  $(DIM)Use SOURCE_DIR=/path/to/source for validations that need the source repository.\n$(NC)"
	@printf "\n"
	@$(MAKE) --no-print-directory help-package
	@$(MAKE) --no-print-directory help-git
	@$(MAKE) --no-print-directory help-aliases
