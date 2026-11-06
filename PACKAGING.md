# 打包方式说明（给其它 AI / 开发者直接照做）

本项目是 **iOS 越狱插件（Theos + Logos tweak）**，不是 App、不是 Xcode 工程。
截图里的两个 `.deb` 是**同一份代码用两种 root 方案各打了一次**：

| 文件 | 方案 | 适用 |
| --- | --- | --- |
| `com.dpo.pluginnest_x.y.z_iphoneos-arm64.deb` | **rootless**（`/var/jb`） | Dopamine / palera1n rootless / ElleKit |
| `com.dpo.pluginnest_x.y.z_iphoneos-arm.deb` | **rootful**（`/`） | unc0ver / checkra1n / 传统越狱 |

包名、版本相同，体积几乎一样（273.8 / 273.9 KB），只是安装前缀不同。

---

## 0. 环境

```bash
# macOS + Xcode Command Line Tools
export THEOS=$HOME/theos
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

需要：`make`、`dpkg-deb`（Theos 自带）、`ldid`（Theos 自带）、iOS SDK（Theos 自动装）。

---

## 1. 目录结构

```
PluginNest/
├── Makefile
├── control
├── PluginNest.plist          # 注入目标 App 的过滤器
├── Tweak.x                   # Logos 入口（%ctor + 运行期 hook 安装）
├── DPO*.h / DPO*.m           # 普通 Objective-C 源文件
└── packages/                 # 产物目录（make package 生成）
```

---

## 2. Makefile（完整，可直接用）

```make
# 默认 rootless，可切换 rootful / roothide
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

# macOS 自带 tar 没有 lzma 时退回 gzip，避免打包阶段才报错
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

include $(THEOS_MAKE_PATH)/tweak.mk

clean::
	@rm -rf .theos packages

after-package::
	@echo "==> PluginNest packaged."
```

关键点：

- `ARCHS = arm64 arm64e`：同时出两个架构，安装到新旧设备都能跑；
- `THEOS_PACKAGE_SCHEME = rootless`：Theos 会把安装路径改写到 `/var/jb`，产物架构名变成 `iphoneos-arm64`；
- `unexport THEOS_PACKAGE_SCHEME`：回到 rootful，产物架构名是 `iphoneos-arm`；
- `FINALPACKAGE = 1`：强制出正式包（否则可能带 `-debug` 后缀）；
- `INSTALL_TARGET_PROCESSES = Aweme`：dpkg 安装后自动结束目标进程，Sileo/Zebra 会用它；
- `THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip`：macOS 没 `lzma` 时的兜底。

---

## 3. control（完整）

```
Package: com.dpo.pluginnest
Name: 插件收纳
Version: 1.1.8
Architecture: iphoneos-arm
Description: 把抖音设置页里所有第三方插件入口统一收进「插件收纳」二级页。
Maintainer: PluginNest
Author: PluginNest
Section: Tweaks
Depends: firmware (>= 14.0), mobilesubstrate
```

- `Architecture` 这里统一写 `iphoneos-arm`，Theos 打包时会按 scheme 改成 `iphoneos-arm64`；
- rootless 包的 `Depends: mobilesubstrate` 由 ElleKit 提供，无需改；
- `Version` 必须和界面里显示的版本号一致（本项目里是 `DPORuntime.m` 的 `DPOBuildVersion`）。

---

## 4. 注入过滤器 PluginNest.plist

```xml
{ Filter = { Bundles = ( "com.ss.iphone.ugc.Aweme" ); }; }
```

只注入抖音（`com.ss.iphone.ugc.Aweme`）。多目标就继续往数组里加 Bundle ID。

---

## 5. 打包命令

```bash
cd PluginNest

# rootless（Dopamine / palera1n rootless）
make package SCHEME=rootless

# rootful（unc0ver / checkra1n）
make package SCHEME=rootful

# roothide（可选）
make package SCHEME=roothide
```

产物：

```
packages/com.dpo.pluginnest_1.1.8_iphoneos-arm64.deb   # rootless
packages/com.dpo.pluginnest_1.1.8_iphoneos-arm.deb     # rootful
```

命名规则是 Theos 固定的：`<Package>_<Version>_<Architecture>.deb`。

---

## 6. deb 内部结构（Theos 自动生成）

rootful：

```
/Library/MobileSubstrate/DynamicLibraries/PluginNest.dylib
/Library/MobileSubstrate/DynamicLibraries/PluginNest.plist
```

rootless：

```
/var/jb/Library/MobileSubstrate/DynamicLibraries/PluginNest.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/PluginNest.plist
```

编译中间产物：`.theos/obj/arm64/PluginNest.dylib`、`.theos/obj/arm64e/PluginNest.dylib`。

---

## 7. 安装 / 卸载

```bash
# rootless
dpkg -i com.dpo.pluginnest_1.1.8_iphoneos-arm64.deb

# rootful
dpkg -i com.dpo.pluginnest_1.1.8_iphoneos-arm.deb

# 立即生效
killall -9 Aweme

# 卸载
dpkg -r com.dpo.pluginnest
```

Sileo / Zebra 直接点安装也可以，`INSTALL_TARGET_PROCESSES` 会自动结束抖音。

---

## 8. 常见坑

1. **装错包**：rootless 设备装 `iphoneos-arm.deb` 会提示依赖不满足或装到 `/` 不生效；认准 `_iphoneos-arm64.deb`。
2. **只打了一个包**：`make package` 默认按 `SCHEME ?= rootless` 走，rootful 必须显式 `SCHEME=rootful`。
3. **改了代码但装上去没变化**：`make clean` 后再打包；确认 `.theos/obj/arm64/PluginNest.dylib` 的修改时间更新。
4. **安装后没生效**：`killall -9 Aweme`，或重启目标 App；检查 `PluginNest.plist` 的 Bundle ID 是否写对。
5. **签名**：Theos 默认用 `ldid -S` 伪签名，越狱环境足够；不要用 Xcode 的 codesign。
6. **压缩**：macOS 没有 `lzma` 时，Theos 默认压缩会失败，上面的 Makefile 已兜底成 gzip。
