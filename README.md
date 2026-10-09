# Lilt

轻快接力，继续手头的工作。

Lilt 是一个面向 macOS 的 Claude Code 本地账号管理工具，使用 SwiftUI 和 Apple 原生 Liquid Glass。它管理多个 Pro/Max 账号，在额度接近耗尽时尝试在原 CLI 进程中切换凭据，让当前任务继续。

模型请求由官方 Claude Code 直接发送给 Anthropic。Lilt 不提供反向代理、模型网关或请求转发服务。

## 项目状态

2026-10-09：需求文档与研究记录已建立，尚未编写应用或创建 Xcode 工程。账号热切换、长效 Token 兼容性和额度采集需要先完成技术验证。

- [产品需求文档](docs/PRD.md)
- [技术证据与待验证事项](docs/RESEARCH.md)
- [实施与验收计划](docs/IMPLEMENTATION.md)

目标系统：macOS 26+。首版用于个人本机使用，账号类型为 Claude Pro / Max。


名称 Lilt 表达轻快、流畅的节奏；目前是内部项目名，未进行商标或域名检索。
