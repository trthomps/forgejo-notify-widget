APP := build/Forgejo Notifications.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: app install run print clean kde-install kde-uninstall kde-test

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

# KDE Plasma 6 widget (see kde/README.md)
KDE_ID := dev.forgejonotify.plasmoid

kde-install:
	kpackagetool6 -t Plasma/Applet -u kde/package 2>/dev/null || kpackagetool6 -t Plasma/Applet -i kde/package
	@echo "Installed. Add \"Forgejo Notifications\" from Add Widgets. After an upgrade, restart plasmashell: systemctl --user restart plasma-plasmashell"

kde-uninstall:
	kpackagetool6 -t Plasma/Applet -r $(KDE_ID)

kde-test:
	node kde/test/forgejo.test.js
