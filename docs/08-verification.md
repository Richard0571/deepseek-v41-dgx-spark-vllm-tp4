# 08 · 验收

**这篇讲什么**：从「容器起来了」到「这套部署真的可用」。现役配方目标：**720896 窗、image:20、Engram-on-disk**。

---

## 0. 验收顺序

```
① 四台容器 Up → ② /v1/models → ③ 最小 chat 200
→ ④ Engram DISK-backed 日志 → ⑤ KV 池数量级 → ⑥ 长上下文 needle
→ ⑦ 图片输入 → ⑧ 视觉多轮（可选）
```

---

## 1. 容器在岗

```bash
for ip in 10.100.24.4 10.100.24.3 10.100.24.1 10.100.24.2; do
  ssh -n $ip 'docker ps --format "{{.Names}} {{.Status}}" | grep vllm_dsv41 || echo GONE'
done
```

四台 `Up`。

---

## 2. API 就绪

```bash
curl -s http://10.100.24.4:8001/v1/models | python3 -m json.tool
```

期望：`deepseek-v4.1-flash` 在列表中。

脚本轮询：`>>> OK: deepseek-v4.1-flash UP after ~Ns`。

---

## 3. 最小请求

```bash
curl -s http://10.100.24.4:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

期望：`200`，有 `choices[0].message.content`。

`/health` 200 **不能**代替本步 —— 补丁缺 import 时 health 仍绿、请求 500。

---

## 4. Engram 补丁生效

```bash
ssh spark-01 'docker logs vllm_dsv41 2>&1 | grep -i "Engram table DISK-backed"'
```

期望：每 rank 有 `23.60 GiB not allocated` 类行。

无此行 + 加载期 MemAvailable 崩溃 ⇒ 可能未挂补丁或 `DSV41_ENGRAM_DISK` 未进容器。

---

## 5. KV 池（本 boot 参考值，A 级）

从 head 日志或 metrics 读 GPU KV cache 容量。本配方 **无 KVB** 时由 profiling 决定。

| 指标 | 本 boot 参考（2026-09-14） |
|---|---|
| KV tokens | **2,552,135** |
| KV GiB | **13.79** |
| 满窗倍数 | **3.54×** |

⚠️ 跨 boot 只看数量级。旧 KVB 档 1,722,343 不可直比。

---

## 6. 长上下文 needle（A 级实录）

241,634 token 真实长 prompt，needle `COPPER-LANTERN-8315` ⇒ **命中**。

---

## 7. 图片输入（A 级实录）

三色条纹图 ⇒ 识别正确（213 prompt tok / 1.2 s）。

---

## 8. 性能参考（A 级，同 boot，含 TTFT）

| 项 | 值 |
|---|---|
| 单流 decode | **88.4 tok/s**（256 tok / 2.89 s） |
| Prefill | **≈1950 tok/s**（241K tok） |
| 冷启动到 ready | ~495 s（首跑）；cache 命中 ~108 s engine init |

对外对比 decode 请丢首样本、同 boot 重复 3 次报中位（见 docs/11）。

---

## 9. 视觉多轮（image:20，可选）

同一会话连续 5 轮带图请求 ⇒ **5/5 completed**，无 400。

`image:4` 时第 5 轮可能触发上限 400 —— 已用 20 修复。

---

## 10. 失败时

| 现象 | 先看 |
|---|---|
| `GUARD-OFF` / exit 3 | 四台哨兵 `v41-mg-phase.sh status` |
| head `exited` | `docker logs vllm_dsv41` 末 50 行 |
| wedge（SSH banner 超时） | 是否未打 Engram 补丁；等 25–40 min 或断电 |
| `patch md5` / 挂载失败 | 四台是否都有 `PATCH_DIR` 七个文件 |

详见 [`10-troubleshooting.md`](10-troubleshooting.md)。
