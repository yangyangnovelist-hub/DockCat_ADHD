# DockCat_ADHD 🐾

[English](#english) | [简体中文](#chinese)

---

<a name="english"></a>
## English

**DockCat_ADHD** is a powerful agentic AI coding and task assistant specifically designed for users with ADHD. It focuses on maximizing focus, clarity, and minimizing cognitive load through a native, high-performance macOS interface.

### ✨ Current Features
- **Productivity Mascot**: A cute "Dock Cat" (currently stays static in "front" mode to minimize distraction) that stays on your screen to keep you grounded.
- **Native Task Management**: Swift-based native UI with drag-and-drop support for re-parenting tasks.
- **Deep macOS Integration**: High-performance SwiftUI implementation with multi-window support.
- **Mind Map Visualization**: Automatically transform your task lists into interactive mind maps (WebView based).
- **Sticky Note Mode**: A quick-access task board that behaves like a physical sticky note.
- **Low-Distraction Mode**: Hide everything that doesn't matter right now with one click.
- **Background Task Monitoring**: Keep track of multiple tasks simultaneously while focusing on a primary goal.

### 🚧 Limitations & Roadmap
- **AI Task Ingestion**: Currently relies on a rule-based syntax parser (`VikunjaQuickAdd`). AI-driven semantic parsing is under development.
- **Animation States**: Currently limited to static "idle" views by user preference; I tried my best to generate usable dynamic animations but failed. Some animations are implemented in the engine but operate awfully. Please help if you like the cat.
- **Syncing**: Local-first storage (SQLite/GRDB); cloud sync across devices is not yet implemented.

### 🚀 Getting Started
1. Clone the repository.
2. Open `Package.swift` in Xcode.
3. Build and Run, or use the pre-built `DockCat.app`.

---

<a name="chinese"></a>
## 简体中文 (Chinese)

**DockCat_ADHD** 是一款专为 ADHD（多动症/注意力不集中）开发者和日常用户设计的强力 AI 代理任务助理。它通过原生、高性能的 macOS 界面，致力于最大化用户的专注度，减少认知负荷。

### ✨ 现有功能
- **专注力萌物**：屏幕右下角的 “Dock Cat”（目前已设为静坐模式以减少分心），时刻视觉陪伴。
- **原生任务管理**：基于 Swift 的高性能 UI，支持通过拖拽自由调整任务层级（母子任务切换）。
- **原生 macOS 体验**：使用 SwiftUI 开发，支持多窗口协同。
- **脑图动态同步**：自动将任务清单转化为可视化脑图（基于 WebView），理清各级逻辑。
- **便签模式**：像物理便利贴一样的快速任务看板，随点随用。
- **超低干扰模式**：一键隐藏非必要信息，聚焦唯一重点。
- **后台任务监控**：在专注主线任务的同时，实时追踪多个后台进行的子任务。

### 🚧 缺陷与后续计划
- **AI 识别能力**：目前的“批量导入”仍依赖硬编码的解析规则（Vikunja 语法），尚不支持完全的自然语言语义拆解（开发中）。
- **动效状态**：目前猫猫采用静止状态.我尝试了所有生成图片的办法制作动画，可惜效果非常的差，无奈之下只能锁定蹲坐效果。文件中有部分生成的动画图片，但是大小不一，尺寸不一，会有闪动现象。如果有喜爱小猫的朋友，欢迎制作自己使用，并帮忙上传更新。
- **数据同步**：目前为本地优先存储（基于 SQLite/GRDB），尚未实现多端云同步。

### 🚀 如何开始
1. 克隆本仓库。
2. 在 Xcode 中打开 `Package.swift`。
3. 直接编译运行，或者使用已打包好的 `DockCat.app`。

---

*Made with ❤️ for the ADHD community.*
