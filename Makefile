# =============================================================================
#  PluginNest（插件收纳）—— 抖音第三方插件入口统一收纳 + 全局功能搜索
#
#  默认 rootless（Dopamine / palera1n rootless / ElleKit），可切换：
#     make package SCHEME=rootful
#     make package SCHEME=roothide
# =============================================================================
-include Makefile.local

TARGET = iphone:clang:latest:14.0
ARCHS  = arm64 arm64e

SCHEME ?= rootless
ifeq ($(SCHEME),roothide)
    export THEOS_PACKAGE_SCHEME = roothide
    export FINALPACKAGE = 1
else ifeq ($(SCHEME),rootful)
    unexport THEOS_PACKAGE_SCHEME
    export FINALPACKAGE = 1
else ifeq ($(SCHEME),rootless)
    export THEOS_PACKAGE_SCHEME = rootless
    export FINALPACKAGE = 1
else
    $(error Unknown SCHEME=$(SCHEME); use rootless, rootful, or roothide)
endif

export DEBUG = 0
INSTALL_TARGET_PROCESSES = Aweme

# macOS 自带 tar 没有 lzma，缺了自动退回 gzip，避免打包阶段才报错
ifeq ($(shell command -v lzma >/dev/null 2>&1 && echo yes),)
    export THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PluginNest

PluginNest_FILES = \
	Tweak.x \
	DPORuntime.m \
	DPOTheme.m \
	DPOModel.m \
	DPOPackageResolver.m \
	DPOHarvester.m \
	DPOViews.m \
	DPODiagnostics.m \
	DPOLogCenter.m \
	DPOLogViewController.m \
	DPOOrganizerViewController.m \
	DPOPluginDetailViewController.m

PluginNest_CFLAGS = -fobjc-arc -fobjc-arc-exceptions -Wall -Wno-unused-function
PluginNest_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore
PluginNest_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

clean::
	@rm -rf .theos packages

after-package::
	@echo "==> PluginNest packaged."
