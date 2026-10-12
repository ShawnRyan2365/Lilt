# Lilt 品牌资产

标志由两段圆润、前倾的笔画组成一个「L」。斜切留白表现接力交接，上扬的底部表现继续前进。应用图标用深松绿底色、奶白主笔画和薄荷绿接力笔画；独立 Logo 使用单色，适合浅色与深色背景。

## 文件

- `lilt-icon.png`：1024 × 1024 App Icon，圆角外透明。
- `lilt-mark.svg` / `lilt-mark-light.svg`：独立标志，深绿 / 奶白，透明背景。
- `lilt-mark.png`：1024 × 1024 透明标志。
- `lilt-logo.svg` / `lilt-logo-light.svg`：标志与 Lilt 字标，字形已转为路径，不依赖字体。
- `lilt-logo.png`：1540 × 780 透明 Logo。
- `brand-preview.png`：1600 × 900 展示图，包含浅底、深底及 128 / 64 / 32 / 16 px 图标预览。

主色：松绿 `#194D3E`、奶白 `#F2F8E9`、薄荷绿 `#B6ECC0`。App Icon 的底色与笔画使用轻微渐变；单色 Logo 保留相同轮廓。保持原比例，四周至少留出标志高度的 1/8 空白。

## 重新生成

在 macOS 上、仓库根目录运行：

```sh
swift scripts/make-icon.swift build --brand-assets
./scripts/build-app.sh
```

`make-icon.swift` 是唯一绘图源：同一组贝塞尔路径生成 SVG、PNG、10 个标准 macOS iconset 文件，以及 18 pt 的菜单栏模板图。App 构建会自动生成 `build/Lilt.app/Contents/Resources/Lilt.icns`，不依赖绘图软件或第三方包。菜单栏关闭自动接力时显示 L 标志，开启后保留原有的接力箭头状态提示。

此版本使用原生矢量绘制，没有使用 AI 位图生成。字标以 Helvetica Neue Medium 转曲；重新生成字标需要 macOS 随附的该字体。
