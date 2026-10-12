# 设计方向与来源

用户要求：替换上一版绿色 L 字母图标；参考 OpenAI、Claude、Grok 的图标气质，以黑、白、灰为主。

选择四瓣回旋：宽阔曲面构成集中轮廓，中心与瓣间留白带来节奏，适合应用图标与单色菜单栏。正式图形使用一枚贝塞尔曲线瓣旋转四次，保留瓣间开口。图标为纯色标志配白色系统圆角底板；阴影仅在底板外，随输出尺寸缩放。

## 参考

- [OpenAI Design Guidelines](https://openai.com/brand/)：几何秩序、曲线与单色呈现。
- [Claude / Anthropic](https://www.anthropic.com/)：紧凑的放射形标志与有机轮廓。
- [Grok Brand Guidelines](https://x.ai/legal/brand-guidelines)：黑白对比、强轮廓与负形。

以上是视觉研究来源。交付文件使用为 Lilt 新建的路径，不包含这些品牌的图形资产。

## 图像探索

使用内置 image_gen 生成三方向探索图，生产资产以左侧的四瓣回旋方向重新绘制。探索图不作为应用资源；正式源文件是 `scripts/make-icon.swift`。

提示词：

> Use case: logo-brand. Create a refined monochrome logo exploration sheet for Lilt, a personal AI developer utility for continuity and account handoff. Three distinct original abstract symbol concepts arranged left to right on a clean white landscape canvas, no text whatsoever, equal visual size, generous whitespace. Aim for the restraint and unforgettable silhouette quality of OpenAI, Claude and Grok brand marks, but do not reproduce any existing logo. Solid black vector-like shapes only, sharp impeccably smooth edges. Each mark must be one cohesive compact shape, readable at 24px. Concept left: four broad, gently curved interlocking arms circulating around a small diamond-shaped negative-space center, balanced square rotational symmetry, subtly folded aperture with four generous openings, elegant and soft yet technical. Concept center: two opposing sweeping organic crescents seamlessly suggesting a continuous relay and a quiet orbital motion, compact circular silhouette with strong negative space. Concept right: a minimal six-lobed rhythmic radial glyph with broad organic leaves and a small open central hexagon, calm and sculptural. Flat 2D black ink only. No letter L, no letters, no wordmarks, no color, no gradients, no 3D, no shadows, no border, no mockup, no tile, no generic sparkle or atom or circuitry. Premium professional identity design, controlled geometry, uncommon silhouette.
