# Claude Code Status Line - MiniMax Version

自定义 Claude Code 状态栏，支持 MiniMax API 用量显示。

## 功能

- **Model** - 当前模型名称
- **CWD@Branch** - 当前目录和 Git 分支（含变更统计）
- **Tokens** - 已用 Token 数量和百分比
- **Effort** - 推理强度（low/med/high）
- **MiniMax** - MiniMax API 已使用百分比和重置时间

## 效果预览

```
MiniMax-M2.5-highspeed | mwledgerly@develop (+5 -2) | 12k/200k (6%) | med | 72% 15:00
```

## 安装

### 1. 下载脚本

```bash
curl -o ~/.claude/statusline-minimax.sh https://raw.githubusercontent.com/你的用户名/claude-code-statusline-minimax/main/statusline-minimax.sh
chmod +x ~/.claude/statusline-minimax.sh
```

### 2. 配置 Claude Code

编辑 `~/.claude/settings.json`，添加：

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-minimax.sh"
  }
}
```

### 3. 重启 Claude Code

## 依赖

- `jq` - JSON 解析
- `curl` - API 请求
- Git（用于显示分支信息）

## 兼容性

- macOS / Linux
- Claude Code Pro/Max 订阅
- 使用 MiniMax API 作为后端

## 许可证

MIT
