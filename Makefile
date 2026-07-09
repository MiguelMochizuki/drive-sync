LIB_DIR      = /usr/local/lib/drive-sync
BIN_DIR      = /usr/local/bin
USER_BIN_DIR = $(HOME)/.local/bin
SCRIPT_NAME  = drive-sync
SOURCE_DIR   = $(shell pwd)

.PHONY: install install-user uninstall

install:
	sudo mkdir -p $(LIB_DIR)
	sudo cp -r $(SOURCE_DIR)/lib $(LIB_DIR)/
	sudo cp $(SOURCE_DIR)/$(SCRIPT_NAME).sh $(LIB_DIR)/
	sudo chmod +x $(LIB_DIR)/$(SCRIPT_NAME).sh $(LIB_DIR)/lib/*.sh
	echo '#!/bin/bash' | sudo tee $(BIN_DIR)/$(SCRIPT_NAME) > /dev/null
	echo 'exec "$(LIB_DIR)/$(SCRIPT_NAME).sh" "$$@"' | sudo tee -a $(BIN_DIR)/$(SCRIPT_NAME) > /dev/null
	sudo chmod +x $(BIN_DIR)/$(SCRIPT_NAME)
	@echo "✅ Installed to $(BIN_DIR)/$(SCRIPT_NAME)"
	@echo "   Sources at $(LIB_DIR)/"

install-user:
	mkdir -p $(USER_BIN_DIR)
	echo '#!/bin/bash' > $(USER_BIN_DIR)/$(SCRIPT_NAME)
	echo 'export DRIVE_SYNC_HOME="$(SOURCE_DIR)"' >> $(USER_BIN_DIR)/$(SCRIPT_NAME)
	echo 'exec "$(SOURCE_DIR)/$(SCRIPT_NAME).sh" "$$@"' >> $(USER_BIN_DIR)/$(SCRIPT_NAME)
	chmod +x $(USER_BIN_DIR)/$(SCRIPT_NAME)
	@echo "✅ Installed to $(USER_BIN_DIR)/$(SCRIPT_NAME)"
	@echo "   Sources at $(SOURCE_DIR)/"
	@echo ""
	@echo "Make sure $(USER_BIN_DIR) is in your PATH:"
	@echo "  export PATH=\"\$$PATH:$(USER_BIN_DIR)\""

uninstall:
	-sudo rm -rf $(LIB_DIR)
	-sudo rm -f $(BIN_DIR)/$(SCRIPT_NAME)
	-rm -f $(USER_BIN_DIR)/$(SCRIPT_NAME)
	@echo "✅ Removed $(SCRIPT_NAME)"