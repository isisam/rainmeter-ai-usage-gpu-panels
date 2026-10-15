# Rainmeter AI 用量 ＆ GPU 面板

兩個 Windows 桌面用的 Rainmeter 面板，配色和尺寸跟 [Win10 Widgets](https://win10widgets.com) 一致（深灰半透明、寬 361px），可以直接疊在一起。

| 面板 | 尺寸 | 內容 |
| --- | --- | --- |
| **AI Usage** | 361 × 165 | 三個圓環：Codex 週額度、Claude 5 小時、Claude 本週 |
| **GPU Monitor** | 361 × 112 | NVIDIA 顯卡：負載、顯存、功耗、溫度四條進度條＋時脈／熱點／風扇 |

*English summary below.*

---

## AI Usage

- **外圈**：剩餘額度。≥50% 品牌色，20–50% 琥珀，<20% 紅。
- **內圈細白線**：距離重置還剩多少時間。外圈比白線長，代表額度撐得到重置。
- 底下顯示重置時間（Asia/Taipei）與倒數。
- 每 60 秒更新一次；右鍵選單有「立即更新」。

### 資料來源

| 項目 | 來源 |
| --- | --- |
| Codex 週額度 | Codex CLI 的官方 app-server RPC `account/rateLimits/read`（唯讀，不會開對話、不消耗額度） |
| Claude 5H / 週 | **優先**：Claude Code 登入後的官方用量 API（`/api/oauth/usage`，與 CLI 的 `/usage` 同一支）<br>**備援**：Claude Desktop 本機快取的用量樣本（只在 App 更新用量卡時才會變） |

收集器只用 Python 標準函式庫，不會輸出 token、帳號 ID 或上游錯誤訊息。
Claude 存取權杖過期時會用 refresh token 自動續期，並寫回 `~/.claude/.credentials.json`（跟 Claude Code 本身的行為一樣）。

### 需求

- [Rainmeter](https://www.rainmeter.net/) 4.5+
- Python 3.9+（在 PATH 上，或在 `AIUsage.ini` 的 `PythonExe` 填完整路徑）
- Codex：`npm i -g @openai/codex` 並登入過一次
- Claude（要每分鐘即時資料的話）：`npm i -g @anthropic-ai/claude-code`，執行 `claude` 後輸入 `/login`

### 選用設定

把 `@Resources/*.example.json` 複製成同名去掉 `.example` 的檔案：

- `config.json` → `codex_executable`：Codex 執行檔位置找不到時才需要填。
- `manual.json` → `claude_weekly_anchor`：沒有登入 Claude Code 時，用來推算 Claude 每週重置時間的 Unix 秒數（任何一次過去的重置時間都可以，會自動往後推 7 天）。

---

## GPU Monitor

- 負載、顯存、功耗（以功耗上限為 100%）、溫度四條進度條；70% / 70°C 以上琥珀色，90% / 83°C 以上紅色。
- 最下面一行：核心／顯存時脈、熱點溫度、顯存溫度、風扇。
- 點右上角切換更新頻率 1s / 2s / 5s。

資料由 `GPUZ-Reader.ps1` 產生：用驅動內建的 `nvidia-smi`，再透過 NVAPI 讀熱點溫度和顯存結點溫度。**不需要 GPU-Z。**
NVAPI 的溫度感測器需要系統管理員權限，所以腳本會自動提權（第一次會跳 UAC）。不給權限的話，其他數值照常顯示，只少熱點和顯存溫度。

需求：NVIDIA 顯示卡與驅動（`C:\Windows\System32\nvidia-smi.exe`）。

---

## 安裝

1. 把 `AI Usage`、`GPU Monitor` 兩個資料夾複製到 `文件\Rainmeter\Skins\`。
2. Rainmeter → 管理 → 重新整理全部 → 載入 `AI Usage\AIUsage.ini` 與 `GPU Monitor\GPU.ini`。
3. 拖曳到想要的位置。

---

## English summary

Two Rainmeter skins styled to match Win10 Widgets (361 px wide, dark translucent):

- **AI Usage** (361×165) — ring gauges for Codex weekly quota and Claude 5-hour / weekly plan usage.
  Outer ring = quota left, inner ring = time left until reset. Data comes from the Codex CLI's
  read-only `account/rateLimits/read` RPC and Claude's official `/api/oauth/usage` endpoint
  (requires `claude` + `/login` once), falling back to Claude Desktop's local usage cache.
  Refreshes every 60 s; nothing here starts a model turn.
- **GPU Monitor** (361×112) — NVIDIA load / VRAM / power / temperature bars plus clocks,
  hot-spot, memory-junction temperature and fan, via `nvidia-smi` + NVAPI (no GPU-Z).

Requirements: Rainmeter 4.5+, Python 3.9+, Codex CLI and/or Claude Code CLI, NVIDIA driver.

## License

[MIT](LICENSE)
