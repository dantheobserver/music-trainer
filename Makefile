PROJECT := music_trainer
BUILD_DIR := build
OUT := $(BUILD_DIR)/$(PROJECT)

.PHONY: build run clean release appimage release-macos dmg

build:
	@mkdir -p $(BUILD_DIR)
	@rm -f $(OUT)
	odin build . -out=$(OUT)

release:
	@mkdir -p $(BUILD_DIR)
	@rm -f $(OUT)
	odin build . -out=$(OUT) -o:speed

appimage: release
	./packaging/build-appimage.sh x86_64

# macOS (host must be macOS): build both architectures and merge into a
# universal binary covering Apple Silicon and Intel Macs.
release-macos: release-macos-arm64 release-macos-amd64
	lipo -create -output $(BUILD_DIR)/$(PROJECT) \
		$(BUILD_DIR)/$(PROJECT)_arm64 $(BUILD_DIR)/$(PROJECT)_amd64

release-macos-arm64:
	@mkdir -p $(BUILD_DIR)
	odin build . -target:darwin_arm64 -out=$(BUILD_DIR)/$(PROJECT)_arm64 -o:speed

release-macos-amd64:
	@mkdir -p $(BUILD_DIR)
	odin build . -target:darwin_amd64 -out=$(BUILD_DIR)/$(PROJECT)_amd64 -o:speed

dmg: release-macos
	./packaging/build-dmg.sh

run: build
	./$(OUT)

clean:
	rm -rf $(BUILD_DIR)
