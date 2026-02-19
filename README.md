# Long-Running Agent Harness

**Author: Dr. Jeff Hou**

---

## Overview

An automated orchestration system based on **Eval-Driven Development (EDD)** that iteratively invokes the Claude CLI to transform natural-language project goals into fully functional, tested codebases — one feature at a time.

一套基于 **Eval-Driven Development (EDD)** 理念的自动化编排系统，通过循环调用 Claude CLI，将自然语言项目目标逐步转化为可运行、经过测试的完整代码库——每次只实现一个功能。

## Theoretical Foundations

This system synthesizes three lines of research:

本系统融合了三项研究思路：

**1. Eval-Driven Development** — Treats evaluations as "unit tests" for AI development. Pass/fail criteria are defined before coding begins, with the `passes` field in `features.json` serving as a deterministic verification gate. No feature is marked complete without passing its tests.

**1. 评估驱动开发** — 将评估（eval）视为 AI 开发的"单元测试"。在编码前定义通过标准，以 `features.json` 中的 `passes` 字段作为确定性验证门控，功能未经测试验证不会被标记为完成。

**2. Pass@k Reliability** — Inspired by the pass@k metric from Chen et al. (2021) *Evaluating Large Language Models Trained on Code*. The system allows up to 50 session iterations, tolerating individual failures and achieving high completion rates through retries (the OpenClack project achieved 90/90 features passing).

**2. Pass@k 可靠性度量** — 源自 Chen et al. (2021) *Evaluating Large Language Models Trained on Code* 提出的 pass@k 指标。系统允许最多 50 次 session 迭代，容忍单次失败，通过连续重试达到高完成率（OpenClack 项目 90/90 features 全部通过）。

**3. SWE-bench-Style Task Decomposition** — Inspired by Jimenez et al. (2024) *SWE-bench: Can Language Models Resolve Real-World GitHub Issues?*. Complex projects are decomposed into 20–200 atomic features, with each session tackling only one, reducing per-inference complexity.

**3. SWE-bench 式任务分解** — 受 Jimenez et al. (2024) *SWE-bench: Can Language Models Resolve Real-World GitHub Issues?* 启发，将复杂项目拆解为 20–200 个原子化 feature，每个 session 只解决一个，降低单次推理复杂度。

## Core Mechanism

```
Goal (natural language) → Phase 1: Initializer → Phase 2: Coding Loop → Complete Project
```

**Phase 1 — Initializer** (single execution): Analyzes the goal, creates the project scaffold, generates `features.json` (feature checklist), `init.sh` (environment script), and `claude-progress.txt` (cross-session memory), then initializes Git.

**Phase 1 — 初始化器**（单次执行）：分析目标，创建项目脚手架，生成 `features.json`（功能清单）、`init.sh`（环境脚本）、`claude-progress.txt`（跨 session 记忆），并初始化 Git。

**Phase 2 — Coding Loop** (up to N iterations): Each session strictly follows a 12-step sequence — read progress log → read Git history → select highest-priority incomplete feature → start environment → verify baseline tests → implement feature → run tests → update status → Git commit. The loop continues until all features pass.

**Phase 2 — 编码循环**（最多 N 次）：每个 session 严格执行 12 步流程——读进度日志 → 读 Git 历史 → 选最高优先级未完成 feature → 启动环境 → 验证基线测试 → 实现功能 → 运行测试 → 更新状态 → Git 提交。循环直到所有 feature 通过。

**Cross-Session Memory**: Context is carried across stateless Claude sessions through three persistent files (`features.json` + `claude-progress.txt` + Git log), overcoming context window limitations.

**跨 Session 记忆**：通过三个持久化文件（`features.json` + `claude-progress.txt` + Git log）在无状态的 Claude 会话间传递上下文，解决上下文窗口限制。

## Engineering Features

- **Dual Watchdog** — 60-min hard wall-clock timeout + 30-min idle timeout to prevent stuck sessions
- **Exponential Backoff** — Automatic retry with increasing delays; safe stop after 5 consecutive failures
- **Resume from Checkpoint** — `--skip-init` resumes from where the last run left off
- **Real-Time Monitor** — `monitor.sh` provides a zero-token terminal dashboard with stuck-detection, progress bars, and cost estimation
- **Language/Framework Agnostic** — The goal description determines the tech stack; validated on Electron/TypeScript, Android/Kotlin, and more

---

- **双重 Watchdog 守护** — 60 分钟硬超时 + 30 分钟空闲超时，防止 session 卡死
- **指数退避重试** — 连续失败时自动等待，5 次失败后安全停止
- **断点续传** — `--skip-init` 从上次中断处恢复
- **实时监控面板** — `monitor.sh` 提供零 token 消耗的终端仪表盘，含卡死检测、进度条、费用估算
- **语言/框架无关** — 目标描述决定技术栈，已验证 Electron/TypeScript、Android/Kotlin 等场景

## Usage

```bash
# Full run (Phase 1 + Phase 2)
./harness.sh -d /path/to/project -M sonnet -m 50 "Your project goal description"

# Resume from checkpoint (skip Phase 1)
./harness.sh --skip-init -d /path/to/project -M sonnet -m 50 "Your project goal"

# Monitor in a separate terminal
./monitor.sh /path/to/project
```

## Results

The OpenClack project (Electron desktop app): 90 features, ~24 automated sessions, all passing, producing 40+ Git commits with a complete test suite and CI/CD pipeline.

OpenClack 项目（Electron 桌面应用）：90 个 feature，约 24 个自动 session，全部通过，生成 40+ 次 Git 提交，含完整测试套件和 CI/CD 流水线。

## License

MIT
