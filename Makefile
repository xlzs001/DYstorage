# Local overrides such as THEOS or SDK paths can live in Makefile.local.
-include Makefile.local

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# Match DYYY's package interface: rootless by default, with explicit schemes
# available through SCHEME=rootful/rootless/roothide.
SCHEME ?= rootless
ifeq ($(SCHEME),roothide)
    export THEOS_PACKAGE_SCHEME = roothide
    export FINALPACKAGE = 1
else ifeq ($(SCHEME),rootful)
    unexport THEOS_PACKAGE_SCHEME
    # Keep the version string identical across schemes (otherwise a local
    # rootful build appends Theos' -1 debug stage suffix).
    export FINALPACKAGE = 1
else ifeq ($(SCHEME),rootless)
    export THEOS_PACKAGE_SCHEME = rootless
    export FINALPACKAGE = 1
else
    $(error Unknown SCHEME=$(SCHEME); use rootless, rootful, or roothide)
endif

ifeq ($(GITHUB_ACTIONS),true)
    export INSTALL = 0
    export FINALPACKAGE = 1
endif

export DEBUG = 0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYStorage

DYStorage_FILES = Tweak.xm DYStorageManager.m DYStorageDeveloperScanner.m DYStorageSearchCatalog.m DYStorageSearchCoordinator.m DYStorageRuntimeIndex.m
# control is the single source of truth for the version string: it is read at
# build time and compiled in, so a local build can never drift from the package.
DYSTORAGE_VERSION := $(shell awk -F': ' '$$1=="Version"{print $$2; exit}' $(THEOS_PROJECT_DIR)/control)

DYStorage_CFLAGS = -fobjc-arc -fobjc-arc-exceptions -Wno-deprecated-declarations -Wno-unguarded-availability -DDYSTORAGE_VERSION_STRING='@"$(DYSTORAGE_VERSION)"'
DYStorage_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

clean::
	@rm -rf .theos packages

after-package::
	@echo "Packaging complete."
