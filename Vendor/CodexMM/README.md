# Codex Session Manager

本地 Web 管理台，用于管理 `Codex` 会话文件。

## 功能

- 扫描并索引 `~/.codex/sessions/**/*.jsonl`
- 读取并管理 `~/.codex/archived_sessions/**/*.jsonl`
- 搜索、筛选、查看会话详情
- 归档、恢复、安全删除、永久清理
- 生成并复制 `codex resume <session-id> -C <dir>` 命令
- 修复官方 Codex 的 `state_*.sqlite` 与 `session_index.jsonl`，补齐 threads / recent conversations
- 在 `~/.codex-session-manager` 中保存 snapshot、索引库与审计日志

## 开发

```bash
npm install
npm run dev
```

默认前端地址为 [http://127.0.0.1:4173](http://127.0.0.1:4173)。

## 本地验证

```bash
npm test
npm run typecheck
npm run build
```

## 生产构建

```bash
npm run build
npm start
```

## 环境变量

- `CODEX_HOME`: 覆盖默认的 `~/.codex`
- `CODEX_MANAGER_HOME`: 覆盖默认的 `~/.codex-session-manager`
- `PORT`: 覆盖服务端口，默认 `4318`
