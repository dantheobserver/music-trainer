PROJECT := music_trainer
BUILD_DIR := build
OUT := $(BUILD_DIR)/$(PROJECT)

.PHONY: build run clean

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

run: build
	./$(OUT)

clean:
	rm -rf $(BUILD_DIR)
