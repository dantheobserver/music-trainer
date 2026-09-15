PROJECT := music_trainer
BUILD_DIR := build
OUT := $(BUILD_DIR)/$(PROJECT)

# miniaudio capture shim (compiled to an object that odin links directly).
# On macOS compile it as a fat object so one file serves both the arm64 and
# amd64 odin targets of the universal build.
MINIAUDIO_OBJ := miniaudio/miniaudio.o
UNAME_S := $(shell uname -s)
MA_ARCH_FLAGS := $(if $(filter Darwin,$(UNAME_S)),-arch arm64 -arch x86_64,)

.PHONY: build run clean release appimage release-macos dmg

build: $(MINIAUDIO_OBJ)
	@mkdir -p $(BUILD_DIR)
	@rm -f $(OUT)
	odin build . -out=$(OUT)

$(MINIAUDIO_OBJ): miniaudio/miniaudio_shim.c miniaudio/miniaudio.h
	$(CC) $(MA_ARCH_FLAGS) -O2 -c miniaudio/miniaudio_shim.c -o $(MINIAUDIO_OBJ)

release: $(MINIAUDIO_OBJ)
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

release-macos-arm64: $(MINIAUDIO_OBJ)
	@mkdir -p $(BUILD_DIR)
	odin build . -target:darwin_arm64 -out=$(BUILD_DIR)/$(PROJECT)_arm64 -o:speed

release-macos-amd64: $(MINIAUDIO_OBJ)
	@mkdir -p $(BUILD_DIR)
	odin build . -target:darwin_amd64 -out=$(BUILD_DIR)/$(PROJECT)_amd64 -o:speed

dmg: release-macos
	./packaging/build-dmg.sh

run: build
	./$(OUT)

clean:
	rm -rf $(BUILD_DIR) $(MINIAUDIO_OBJ)