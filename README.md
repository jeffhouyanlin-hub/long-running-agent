# Long-Running Agent Harness

## 概述

一套基于 **Eval-Driven Development (EDD)** 理念的自动化编排系统，通过循环调用 Claude CLI 将自然语言项目目标逐步转化为可运行的完整代码库。

## 理论基础

本系统融合了三项研究思路：

1. **Eval-Driven Development** — 将评估（eval）视为 AI 开发的"单元测试"，在编码前定义通过标准，以 `features.json` 中的 `passes` 字段作为确定性验证门控，确保每个功能经测试验证后才标记完成。

2. **Pass@k 可靠性度量** — 源自 Chen et al. (2021) *Evaluating Large Language Models Trained on Code* 提出的 pass@k 指标。系统允许最多 50 次 session 迭代，容忍单次失败，通过连续重试达到高完成率（OpenClack 项目 90/90 features 全部通过）。

3. **SWE-bench 式任务分解** — 受 Jimenez et al. (2024) *SWE-bench: Can Language Models Resolve Real-World GitHub Issues?* 启发，将复杂项目拆解为 20–200 个原子化 feature，每个 session 只解决一个，降低单次推理复杂度。

## 核心机制

```
Goal (自然语言) → Phase 1: Initializer → Phase 2: Coding Loop → 完整项目
```

**Phase 1 — Initializer**（单次执行）：分析目标，创建项目脚手架，生成 `features.json`（功能清单）、`init.sh`（环境脚本）、`claude-progress.txt`（跨 session 记忆），初始化 Git。

**Phase 2 — Coding Loop**（最多 N 次）：每个 session 严格执行 12 步流程——读进度日志 → 读 Git 历史 → 选最高优先级未完成 feature → 启动环境 → 验证基线测试 → 实现功能 → 运行测试 → 更新状态 → Git 提交。循环直到所有 feature 通过。

**跨 Session 记忆**：通过三个持久化文件（`features.json` + `claude-progress.txt` + Git log）在无状态的 Claude 会话间传递上下文，解决上下文窗口限制。

## 工程特性

- **Watchdog 双重守护**：30 分钟硬超时 + 10 分钟空闲超时，防止 session 卡死
- **指数退避重试**：连续失败时自动等待，5 次失败后安全停止
- **断点续传**：`--skip-init` 从上次中断处恢复
- **实时监控面板**：`monitor.sh` 提供零 token 消耗的终端仪表盘，含卡死检测、进度条、费用估算
- **语言/框架无关**：目标描述决定技术栈，已验证 Electron/TypeScript、Android/Kotlin 等场景

## 实际效果

OpenClack 项目（Electron 桌面应用）：90 个 feature，约 24 个自动 session，全部通过，生成 40+ 次 Git 提交，含完整测试套件和 CI/CD 流水线。
