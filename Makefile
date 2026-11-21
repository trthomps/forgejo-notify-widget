APP := build/Forgejo Notifications.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print clean

app:
	./scripts/build-app.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	-pkill -x ForgejoNotify
	rm -rf "$(INSTALL_DIR)/Forgejo Notifications.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/Forgejo Notifications.app"
	@echo "Installed to $(INSTALL_DIR)/Forgejo Notifications.app"

run: app
	-pkill -x ForgejoNotify
	open "$(APP)"

print:
	swift run -c release ForgejoNotify --print

clean:
	rm -rf .build build
