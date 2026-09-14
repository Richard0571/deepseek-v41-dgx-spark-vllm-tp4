# Changelog

## 2026-09-14 — 第一方配方（覆盖旧版）

**Breaking**：废弃 KVB `5900000000` + `max-model-len 749568` + `image:4` + `--default-chat-template-kwargs thinking:false` 方案。

### 新增

- `scripts/v41-tuned-tp4.sh` — 现役起服脚本（Tony + joe + 本机实测）
- `patch/` — 七个 bind-mount 补丁 + `mounts.txt`（可直接部署）

### 现役参数

| 项 | 旧版 | 新版 |
|---|---|---|
| 窗 | 749568（KVB 档） | **720896**（profiling 路径） |
| KV 旋钮 | `--kv-cache-memory-bytes 5.9e9` | **无 KVB**，GMU 0.80 profiling |
| KV 池 | 1,722,343 tokens | **2,552,135 tokens**（本 boot） |
| image 上限 | 4 | **20** |
| Engram | 装载期入内存 | **DSV41_ENGRAM_DISK=1**（必须） |
| 思考 | `thinking: false` 默认关 | **recipe 默认 ON**（不设 default kwargs） |
| master-port | 29541 | **25410** |

### 实测（A 级，本 boot）

- 单流 88.4 tok/s、prefill ≈1950 tok/s
- 241K needle 命中、image 三色条纹正确
- 同会话五轮视觉压测 5/5（image:20）

### 文档

- `README.md` 重写
- `docs/06-launch-parameters.md` 按第一方配方更新
