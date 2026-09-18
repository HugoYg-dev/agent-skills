#!/usr/bin/env bash
#
# install.sh — 将本仓库的自研 skills 分发到各个 agent harness（幂等，可重复执行）
#
# 两步走：
#   1) 仓库（唯一源头）→ ~/.agents/skills（分发枢纽）。大多数 harness（ZCode、
#      Antigravity IDE 等）原生读取枢纽，装到这里即可用。
#   2) 仅对不原生读取枢纽的 harness（如 Claude Code、Gemini CLI），按需软链其私有
#      skills 目录——目录存在（harness 已安装）才建链，否则跳过。
# browser-skill 等第三方 skill 由 `npx skills` 管理，本脚本不碰。

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$REPO_DIR/skills"
HUB="$HOME/.agents/skills"

# 参加分发的 skill（skills/ 下的目录名）。低频 skill 保持注释状态（on-demand，不占各
# harness 每次会话的 context），需要时取消注释并重跑本脚本。
ACTIVE_SKILLS=(
  git-commit-cn
  handoff
  web-content-fetcher
  # bilibili-render-pdf
  # youtube-render-pdf
)

# 仅列"不原生读取枢纽"的 harness 的私有 skills 目录。Codex 等已原生读取
# ~/.agents/skills，无需软链。接入新 harness 时先确认它是否原生读枢纽——兼容就
# 不要加进来，否则同一 skill 会被加载两次。目录不存在（harness 未安装）时自动跳过。
LEGACY_HARNESS_DIRS=(
  "$HOME/.claude/skills"   # Claude Code
  "$HOME/.gemini/skills"   # Gemini CLI
  # "$HOME/.gemini/antigravity-cli/skills"  # Antigravity CLI（用到再打开）
)

log()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
tilde() { printf '%s' "${1/#$HOME/~}"; }

# 把实体副本替换为软链：仅当内容与源头一致才动手，不一致则跳过等人工处理
replace_copy_with_link() {
  local copy="$1" source="$2" label="$3"
  if diff -rq -x .DS_Store "$source" "$copy" >/dev/null 2>&1; then
    rm -r "$copy"
    ln -s "$source" "$copy"
    log "  ${label}：实体副本与源头一致，已替换为软链"
  else
    warn "${label}：存在与源头不一致的实体副本，已跳过，请人工合并后重跑"
    return 1
  fi
}

# 确保 target 以软链形式指向 source
link_entry() {
  local target="$1" source="$2" label="$3"
  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" = "$source" ]; then
      log "  ${label}：✓"
    else
      ln -sfn "$source" "$target"
      log "  ${label}：已修正 → $(tilde "$source")"
    fi
  elif [ -e "$target" ]; then
    replace_copy_with_link "$target" "$source" "$label"
  else
    ln -s "$source" "$target"
    log "  ${label}：新建软链"
  fi
}

fail=0
log "仓库：$(tilde "$REPO_DIR")"
log "枢纽：$(tilde "$HUB")"
log ""

for skill in "${ACTIVE_SKILLS[@]}"; do
  if [ ! -d "$SKILLS_DIR/$skill" ]; then
    warn "仓库中不存在 skill 目录：$skill"
    fail=1
    continue
  fi

  log "$skill"
  link_entry "$HUB/$skill" "$SKILLS_DIR/$skill" "枢纽" || fail=1
  for dir in "${LEGACY_HARNESS_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
      log "  $(tilde "$dir")：目录不存在（harness 未安装），跳过"
      continue
    fi
    link_entry "$dir/$skill" "$HUB/$skill" "$(tilde "$dir")" || fail=1
  done
  log ""
done

# 校验：每个 skill 在每个位置都应能读到 SKILL.md
missing=0
for skill in "${ACTIVE_SKILLS[@]}"; do
  for dir in "$HUB" "${LEGACY_HARNESS_DIRS[@]}"; do
    [ "$dir" = "$HUB" ] || [ -d "$dir" ] || continue
    if [ ! -e "$dir/$skill/SKILL.md" ]; then
      warn "校验失败：$(tilde "$dir")/$skill/SKILL.md 不可达"
      missing=1
    fi
  done
done

if [ "$missing" -eq 0 ]; then
  log "✅ 校验通过：${#ACTIVE_SKILLS[@]} 个 skill 已装入枢纽（原生兼容的 harness 即刻可用），已安装的需软链 harness 全部可达"
else
  log "❌ 存在不可达的 skill，请处理上方 ⚠️ 后重跑"
  fail=1
fi

# 仓库里处于 on-demand 状态的 skill（有 SKILL.md 但未加入 ACTIVE_SKILLS）
on_demand=()
for d in "$SKILLS_DIR"/*/; do
  [ -f "${d}SKILL.md" ] || continue
  name="$(basename "$d")"
  if [[ " ${ACTIVE_SKILLS[*]} " != *" $name "* ]]; then
    on_demand+=("$name")
  fi
done
if [ "${#on_demand[@]}" -gt 0 ]; then
  log ""
  log "on-demand（未分发，需要时在 ACTIVE_SKILLS 中启用）：${on_demand[*]}"
fi

exit "$fail"
