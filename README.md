# Agent Skills Collection

## Skills 目录

### 1. git-commit-cn
生成符合约定式提交规范的中文 Git 提交信息。自动分析代码变更，生成规范的中文提交信息。

### 2. bilibili-render-pdf
从B站讲座、教程或技术分享生成专业的、详细的、富含图表的 LaTeX 课程笔记和 PDF。支持提取视频章节、字幕、高清截图和公式代码。

### 3. youtube-render-pdf
从YouTube讲座、教程或技术分享生成专业的、详细的、富含图表的 LaTeX 课程笔记和 PDF。支持提取视频章节、字幕、高清截图和公式代码。

### 4. web-content-fetcher
提取任何URL的文章内容为干净的Markdown格式。支持Scrapling和Jina Reader两种方式，保留标题、链接、图片、列表和代码块。

### 5. handoff
编写或更新交接文档，使下一个agent可以继续接手工作。

## 安装（新机器）

```bash
git clone <本仓库> && cd agent-skills && ./install.sh
```

本仓库是唯一源头。脚本第一步把 skill 装入分发枢纽 `~/.agents/skills`——大多数 harness（ZCode、Codex、Antigravity IDE 等）原生读取枢纽，装完即可用；第二步仅对不原生读取枢纽的 harness（如 Claude Code、Gemini CLI）按需软链其私有 skills 目录，且只为已存在的目录建链（未安装的 harness 自动跳过），名单由脚本内 `LEGACY_HARNESS_DIRS` 控制。脚本幂等，可重复执行。

- 参加分发的 skill 由脚本内 `ACTIVE_SKILLS` 控制。低频 skill（如两个 render-pdf）默认 on-demand：仓库里保留、不链入枢纽，避免占用每次会话的 context，需要时取消注释重跑。
- 发现实体副本时，仅当内容与源头一致才替换为软链，否则跳过并提示人工合并。
- browser-skill、find-skills 等第三方 skill 由 [skills CLI](https://github.com/vercel-labs/skills)（`npx skills add`）管理并记录在 `~/.agents/.skill-lock.json`，本脚本不接管。
