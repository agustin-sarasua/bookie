# Bookie — build, flash and card chores.
#
#   make            list the targets
#   make go         build, flash and open the monitor (the one you want)
#   make card CARD=/Volumes/BOOKIE
#
# PlatformIO is found on PATH, or run through python3 if it is only a module.

# Absolute: `pio device monitor -d <relative>` chdirs into the project and then
# re-resolves the same relative path, looking for firmware/firmware.
DIR  := $(abspath firmware)
ENV  ?= lolin_d32
PIO  ?= $(shell command -v pio >/dev/null 2>&1 && echo pio || echo "python3 -m platformio")

# Optional: make flash PORT=/dev/cu.usbserial-0001 SPEED=115200
PORT_ARG   := $(if $(PORT),--upload-port $(PORT))
MONITOR_ARG := $(if $(PORT),--port $(PORT))
SPEED_ENV  := $(if $(SPEED),PLATFORMIO_UPLOAD_SPEED=$(SPEED))

RUN := $(SPEED_ENV) $(PIO) run -d $(DIR) -e $(ENV)

.DEFAULT_GOAL := help
.PHONY: help build flash go monitor debug clean erase size ports check card audio uid app app-test app-build

help: ## Show this list
	@echo "Bookie — ESP32 firmware for the NFC book"
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  variables: ENV=$(ENV)  PORT=<serial port>  SPEED=<upload baud>  CARD=<mounted card>"
	@echo
	@echo "  the app: melos run --help, or make app / app-test / app-build"

build: ## Compile the firmware
	$(RUN)

flash: ## Compile and flash over USB
	$(RUN) $(PORT_ARG) -t upload

go: ## Flash, then open the serial monitor
	$(RUN) $(PORT_ARG) -t upload -t monitor

monitor: ## Open the serial monitor (115200, ctrl-c to quit)
	$(PIO) device monitor -d $(DIR) -e $(ENV) $(MONITOR_ARG)

debug: ## Flash the chatty build (LOGD on) and watch it
	$(MAKE) go ENV=lolin_d32-debug

erase: ## Wipe the flash, including the stored language and volume
	$(RUN) $(PORT_ARG) -t erase

clean: ## Delete build output
	$(RUN) -t clean

size: ## Where the flash and RAM went
	$(PIO) run -d $(DIR) -e $(ENV) -t size

check: ## Static analysis over src/
	$(PIO) check -d $(DIR) -e $(ENV) --skip-packages --pattern src

ports: ## List the serial ports the board might be on
	$(PIO) device list

card: ## Copy firmware/sdcard/ onto the microSD card: make card CARD=/Volumes/BOOKIE
ifndef CARD
	@echo "Set CARD to the mounted card, e.g. make card CARD=/Volumes/BOOKIE"
	@echo "Mounted volumes:"; ls -1 /Volumes
	@exit 1
endif
	@test -d "$(CARD)" || { echo "$(CARD) is not mounted"; exit 1; }
	rsync -rtv --modify-window=2 --exclude '.DS_Store' --exclude 'README.md' \
		$(DIR)/sdcard/ "$(CARD)/"
	@sync
	@echo "Copied. Eject before pulling the card out."

audio: ## Convert recordings: make audio LANG=en SRC="~/clips/*.m4a"
	@test -n "$(SRC)" || { echo 'Usage: make audio LANG=en SRC="~/clips/*.m4a"'; exit 1; }
	$(DIR)/tools/prepare_audio.sh $(DIR)/sdcard/audio/$(or $(LANG),en) $(SRC)

# The app's own targets live in pubspec.yaml as Melos scripts, so there is one
# definition of each rather than two that drift. These are just the door in.
# Needs Melos once: dart pub global activate melos

app: ## Run Bookie Studio on a connected phone
	melos run app

app-test: ## The app's firmware-contract tests
	melos run test

app-build: ## Build the app for both platforms, without signing
	melos run build

uid: ## Reminder of how to read a tag's UID
	@echo "make monitor, then type:  uid"
	@echo "It prints the UID and the file it resolves to in every language."
