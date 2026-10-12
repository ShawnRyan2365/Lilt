# Lilt 品牌资产

四枚宽阔的弧形围绕中心留白旋转，形成紧凑的「回旋」标志，表达连续、轮换与接力。采用黑、白、灰；标志本身是纯色平面图形。App Icon 默认白底黑标，另提供黑底白标版本。

## 文件

- `lilt-icon.png`：1024 × 1024 默认 App Icon，白底黑标，圆角外透明。
- `lilt-icon-dark.png`：1024 × 1024 黑底白标备选图标。
- `lilt-mark.svg` / `lilt-mark-light.svg`：独立标志，黑 / 白，透明背景。
- `lilt-mark.png`：1024 × 1024 透明黑色标志。
- `lilt-logo.svg` / `lilt-logo-light.svg`：标志与 Lilt 字标，字形已转为路径，不依赖字体。
- `lilt-logo.png`：1540 × 780 透明 Logo。
- `brand-preview.png`：1600 × 900 展示图，包含浅底、深底及 128 / 64 / 32 / 16 px 图标预览。

颜色：墨黑 `#141414`、浅白 `#FAFAFA`、反白 `#F5F5F5`、边框灰 `#DEDEDE`。保持原比例，四周至少留出标志宽度的 1/8 空白。不要单独旋转其中一瓣、添加彩色渐变或改变瓣间留白。

## 重新生成

在 macOS 上、仓库根目录运行：

```sh
swift scripts/make-icon.swift build --brand-assets
./scripts/build-app.sh
```

`make-icon.swift` 是正式资产的唯一绘图源：同一组贝塞尔路径生成 SVG、PNG、10 个标准 macOS iconset 文件，以及 18 pt 的菜单栏模板图。App 构建自动生成 `build/Lilt.app/Contents/Resources/LiltOrbit.icns`，不依赖绘图软件或第三方包。图标使用新的资源名和构建号，避免 macOS 继续命中旧绿色图标缓存。菜单栏关闭自动接力时显示回旋标志，开启后保留原有的接力箭头状态提示。

形态探索使用内置图像生成工具，正式交付重新构建为四重旋转对称的原生矢量路径。字标以 macOS 随附的 Helvetica Neue 转曲。参考与探索提示词见 [design-notes.md](design-notes.md)。
