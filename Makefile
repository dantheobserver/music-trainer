PROJECT := music_trainer
BUILD_DIR := build
OUT := $(BUILD_DIR)/$(PROJECT)

.PHONY: build run clean

build:
	@mkdir -p $(BUILD_DIR)
	@rm -f $(OUT)
	odin build . -out=$(OUT)

run: build
	./$(OUT)

clean:
	rm -rf $(BUILD_DIR)
