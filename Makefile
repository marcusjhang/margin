PROJECT := Margin.xcodeproj
SCHEME := Margin
DERIVED := .build

.PHONY: generate build run test clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build

run: build
	open $(DERIVED)/Build/Products/Debug/Margin.app

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) test

clean:
	rm -rf $(DERIVED) $(PROJECT)
