.DEFAULT_GOAL := help

.PHONY: help install-hooks lint test android android-test ios-test mobile-build mobile-build-android mobile-build-ios clean

UNAME_S := $(shell uname -s)
IOS_DEST := $(shell xcodebuild -showdestinations -project ios/*.xcodeproj -scheme * 2>/dev/null | grep 'platform:iOS Simulator' | grep 'iPhone' | head -1 | sed -n 's/.*id:\([^,]*\).*/id=\1/p')
ifeq ($(IOS_DEST),)
IOS_DEST := platform=iOS Simulator,name=iPhone 16
endif

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

install-hooks: ## Install pre-commit hooks
	pre-commit install
	pre-commit install --hook-type pre-push

lint: ## Run pre-commit linters and go vet
	pre-commit run --all-files
	cd core && go vet ./...

test: ## Run Go core unit tests
	cd core && go test -race -v ./...

android: ## Assemble Android debug build
	cd android && if [ -f "./gradlew" ]; then ./gradlew assembleDebug; fi

android-test: ## Run Android unit tests + release compile check
	cd android && if [ -f "./gradlew" ]; then ./gradlew testDebugUnitTest compileReleaseKotlin; fi

mobile-build: ## Build mobile native libraries (Android AAR + iOS xcframework)
	./scripts/build-mobile.sh

mobile-build-android: ## Build Android AAR library
	./scripts/build-mobile.sh --android-only

mobile-build-ios: ## Build iOS xcframework library
	./scripts/build-mobile.sh --ios-only

ios-test: ## Run iOS simulator unit tests
ifeq ($(UNAME_S),Darwin)
	xcodebuild test -project ios/*.xcodeproj -scheme * -destination '$(IOS_DEST)' CODE_SIGNING_ALLOWED=NO
else
	@echo "==> Linux detected: xcodebuild is unavailable on Linux."
endif

clean: ## Clean build artifacts
	rm -rf dist/ coverage.txt core/coverage.txt
	cd android && if [ -f "./gradlew" ]; then ./gradlew clean; fi
