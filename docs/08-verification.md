# 08 · 验收

**这篇讲什么**：从「容器起来了」到「这套部署真的可用」之间的检查顺序。**每一层都有它的专属陷阱**，跳过任何一层都可能带着一个「看起来正常」的坏状态上线。

---

## 0. 验收顺序（不要跳步）

```
① 容器在岗 → ② /health 200 → ③ 最小请求 200 → ④ 补丁真的生效（sha256）
→ ⑤ KV 池断言 → ⑥ Engram 行对拍 → ⑦ 前缀复用 → ⑧ 并发阶梯 → ⑨ 长上下文 → ⑩ 记录 boot 身份
```

**①–④ 是「能不能用」，⑤–⑦ 是「对不对」，⑧–⑨ 是「够不够」。**

---

## 1. 容器在岗

```bash
for i in 1 2 3 4; do
  ssh spark-0$i 'docker ps --format "{{.Names}} {{.Status}}" | grep <容器名> || echo GONE'
done
```

四台都要有，且状态是 `Up`。

---

## 2. `/health` 与 `/v1/models`

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://10.100.24.4:8001/health
curl -s http://10.100.24.4:8001/v1/models | python3 -m json.tool | head -20
```

期望：健康检查 `200`；`/v1/models` 返回配置的模型名。

### ⚠️ 这一层**不能**证明代码没问题

**`/health` 返回 200，只说明进程活着。**
一个少了 `import` 的补丁可以让**每一个**请求抛 `NameError`，而健康检查**照样 200**。

⇒ 必须做第 3 步。

---

## 3. 最小请求（防「健康但每个请求都 500」）

```bash
curl -s http://10.100.24.4:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<模型名>","messages":[{"role":"user","content":"只回数字 2"}],
       "max_tokens":8,"temperature":0,"stream":false}'
```

判据：

| 项 | 期望 |
|---|---|
| HTTP | **200** |
| 正文 | 能读出 `2`（内容不严格，但**不能是空/报错**） |
| 若补丁改了系统提示词相关逻辑 | 额外确认**系统提示词没被丢掉** |

**补丁部署后必须走这一步。** 这是「补丁真的能跑」的最低成本判据。

---

## 4. 补丁真的生效（host ↔ 容器 sha256）

**「容器重建了」≠「补丁生效了」。**

```bash
# 宿主端
sha256sum <PATCH_DIR>/engram.py
# 容器内（同一文件）
docker exec <容器名> sha256sum <SITE>/models/deepseek_v4_1/common/engram.py
```

| 判据 | 含义 |
|---|---|
| 两边 sha256 **相同** | 挂载真的生效 |
| 两边**不同** | 挂到了空目录 / 别的文件 / 没挂上 |
| 容器内目标不是普通文件 | 挂载点被创建成了目录 ⇒ 补丁不生效 |

```bash
# 顺手确认目标是普通文件
docker exec <容器名> stat -c '%F %s' <SITE>/models/deepseek_v4_1/common/engram.py
```

对**每一条** patch mount 都做一遍（或至少对本次改动的那几条）。

---

## 5. KV 池断言

```bash
docker logs <容器名> 2>&1 | grep -oE 'GPU KV cache size: [0-9,]+ tokens' | tail -1
docker logs <容器名> 2>&1 | grep -oE 'Maximum concurrency for [0-9,]+ tokens per request: [0-9.]+x' | tail -1
```

本配置的期望值（A 级）：

| 项 | 期望 |
|---|---|
| KV 池 | **1,722,343 tokens** |
| 并发倍数 | **2.30×** |

**若对不上**，先核容器**实际生效**的参数（不要信脚本）：

```bash
docker inspect <容器名> --format '{{join .Config.Cmd " "}}' \
  | grep -oE -- '--gpu-memory-utilization [0-9.]+|--max-num-batched-tokens [0-9]+|--kv-cache-memory-bytes [0-9]+'
```

**起服脚本应主动打印这三项**「实际生效值」，防止默认值静默漂移。

---

## 6. Engram 行对拍（防 rank-offset bug）

**这是唯一能发现 rank-offset bug 的方法**（见 [`docs/03`](03-model-preparation.md) §3）。

做法：对同一批行号，在**四个 rank** 上分别 lookup，比对结果。

| 结果 | 判定 |
|---|---|
| 四个 rank 全 MATCH | ✅ 通过 |
| rank 0 对、rank 1–3 错 | ❌ 典型的 offset bug |

**不做对拍就不算通过。** 输出「看起来正常文本」和「吞吐不变」都不构成证据。

---

## 7. 前缀复用检查

```bash
# 读引擎的缓存计数
curl -s http://10.100.24.4:8001/metrics | grep -E 'prefix_cache_(hits|queries)_total'
```

做法：**同一个 prompt 连发 3 次**，读每次响应的 `cached_tokens`。

| 现象 | 判读 |
|---|---|
| 第 2/3 次 `cached ≈ 全量` | ✅ 复用正常 |
| 三次都 `cached = 0` | ⚠️ 该尺寸/该时刻复用了失败 —— **这在本引擎上是已知的正常波动**（见 [`docs/12`](12-engine-runtime-notes.md)），**不要据此判服务坏**，也不要据此判「前缀变了」 |

用引擎的累计计数器逐位对账（`Δhits = n × 单次命中量`），比看单次响应更硬。

---

## 8. 并发阶梯

`--repeats 3 --warmup 1`（**先丢一个冷样本**），8 类 prompt，报**中位 / max / min**。

实测（A 级，**同一个 boot**，MAXB 2048 / KVB 5.9e9）：

| 并发 | `agg tok/s`（含 TTFT，**不可对外**） | **`decode-agg tok/s`（对外口径）** | 平均 TTFT |
|---|---|---|---|
| C1 | 52.39 | **59.75** | 0.240 s |
| C2 | 91.58 | **99.69** | 0.270 s |
| C4 | 122.90 | **130.66** | 0.300 s |
| C6 | 160.63 | **168.83** | 0.330 s |
| C8 | 202.08 | **215.33** | 0.370 s |

两点口径纪律：

1. **`agg` 含 TTFT，比 `decode-agg` 低 4.9%（C6）到 12.3%（C1）**。**对外一律用 `decode-agg`。**
2. `per-stream` 随并发下降是**预期行为**（每流让出带宽换聚合吞吐），不是问题。

⚠️ **跨 boot 不可直比**（见 [`docs/11`](11-measurement-notes.md)）。上面是某一次 boot 的结果，
你本次的实测值可能相差 1.25–1.41 倍 —— **以你本次同 boot 的数字为准**。

---

## 9. 冷 prefill 分档

`--literal-tokens`（**按真实 token 数造 prompt，不要用「词数 × 系数」的换算**），
每档 `--floor-gib 3.2`（低于该余量则跳过，避免把机器打死）。

实测（A 级，同一 boot）：

| 档 | **实测 prompt tokens** | TTFT | **prefill tok/s** | 起前 → 档后 head `avail` | 通过 |
|---|---|---|---|---|---|
| 标称 8250 | **8,337** | 5.136 s | **1,623.2** | 7.9 → 7.4 GiB | ✅ |
| 标称 32772 | **32,786** | 20.230 s | **1,620.7** | 7.4 → 6.7 GiB | ✅ |
| 标称 131313 | **131,542** | 85.545 s | **1,537.7** | 6.7 → 5.2 GiB | ✅ |
| 300,000 | **301,232** | 216.960 s | **1,388.4** | 5.2 → 5.6 GiB | ✅ |
| **614,400** | **617,166** | **537.154 s** | **1,149.0** | 5.6 → 5.2 GiB | ✅ |

⚠️ **一律写实测 token 数，不要写标称档位。** 历史上有一个 `0.55 词/token` 的旧换算，
会把「标称 8192」变成实测 12,003 tokens（差 1.465 倍），拿它去和别人的「8K 档」比就是错的。
现在统一走「按真实 token 数生成」。

---

## 10. 长上下文验收（最高风险项）

```bash
# 单请求，走长上下文脚本；注意观察每档后的余量与服务存活
python3 <LONGCTX_SCRIPT> --base http://10.100.24.4:8001/v1 \
  --literal-tokens --tiers 614400 --floor-gib 3.2 --out <结果文件>
```

判据（四条全过才算通过）：

| # | 判据 | 期望 |
|---|---|---|
| 1 | 请求完成 | 无 `RemoteDisconnected` / 无 4xx/5xx |
| 2 | **服务仍 200** | 档后 `/v1/models` 仍 200 |
| 3 | **本 boot 0 新增击杀** | `grep -c '!! 触发：' <哨兵日志>` 增量 = 0 |
| 4 | **最低 `avail` 有余量** | 连续采样最低值 ≥ 击杀线的数倍（实测 4,562 MB = 4.5×） |

> ⚠️ **600K 属于上游未验证区**：上游那条替换内核只在 **≤300,000 行宽**验证过。
> 线性外推下 600K 的每行 block 数可能接近硬件 SM 上限。
> ⇒ **第一次 600K 请求必须当风险实验做**：单独一档、随时可停、全程盯余量。

### 一条更强的检查：内容正确性

长上下文「跑通」不等于「答对」。建议加一个**检索型**判据：
在超长 prompt 的深处埋一个唯一标记，断言回复中包含该标记。

判据要**严格**（`re.fullmatch` / 数字边界），不要用「子串包含」——
子串判据会把 `47031` 也算成 `4703` 命中。

---

## 11. 记录 boot 身份（做同 boot 对照的前提）

```bash
docker inspect <容器名> --format '{{.State.StartedAt}} restarts={{.RestartCount}}'
```

**规则**：任何「改动前 / 改动后」的对照，两个读数的 `StartedAt` 必须**完全相同**。
若不同，说明中间经历了重启 ⇒ **不是同 boot ⇒ 不可直比**（[`docs/11`](11-measurement-notes.md)）。

建议把这一行**写进每一份测量记录的头部**。

---

## 12. 验收检查清单

- [ ] 四台容器 `Up`
- [ ] `/health` 200 **且** `/v1/models` 200
- [ ] **最小请求**返回 200 且内容非空
- [ ] 本次改动的补丁：host ↔ 容器 sha256 一致
- [ ] KV 池 = 期望值（并已核容器**实际** argv）
- [ ] Engram 行对拍四台全 MATCH
- [ ] 前缀复用计数器有增量
- [ ] 并发阶梯已测，报了**中位 / max / min**，且用 `decode-agg` 口径
- [ ] 冷 prefill 分档已测，报的是**实测 token 数**
- [ ] 长上下文四条判据全过（或已明确标 `LOWHEAD` 为「未验收」）
- [ ] 本 boot 击杀增量 = 0
- [ ] `StartedAt` / `RestartCount` 已记录
- [ ] 所有数字已标来源等级（[`docs/11`](11-measurement-notes.md)）
