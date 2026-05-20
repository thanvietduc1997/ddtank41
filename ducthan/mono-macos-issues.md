# Mono / macOS Issues — DDTank Services

**Last updated:** 2026-05-19  
**Environment:** macOS (arm64), .NET SDK 10.0.107, Mono 6.14.1, SQL Server in Docker (`ddtank-mssql`)

---

## Recent Commits Summary (last 4)

| Commit | Change | Why |
|--------|--------|-----|
| `016fff7` | **App.config overhaul for macOS** — pointed connection strings at Docker SQL Server (`localhost,1433`), added `Enlist=False`, fixed `Languages\…` backslash path separators to forward slashes | Original config pointed at `KHANHDUY\SQLEXPRESS` (Windows-only); `Enlist=False` eliminates Mono's unimplemented MSDTC code path that crashed background timers |
| `4db621b` | **`immediateFlush=true` in GameServer log appender** | Buffered file writes made startup logs invisible during `tail -f` on macOS — log output only appeared after flush intervals |
| `a8ed932` | **Replace `ColoredConsoleAppender` with `ConsoleAppender`** | `ColoredConsoleAppender` internally calls `GetConsoleOutputCP`, a Windows-only Win32 API, causing `System.EntryPointNotFoundException` on Mono at startup |
| `ecb9c43` | **Runbook update** — marked the two issues above as fixed, removed the now-unnecessary manual config patch instructions | Housekeeping after the source-level fixes landed |

---

## Known Issues on Mono / macOS

These issues were found while getting `Center.Service` running. All three apply equally to `Fighting.Service` and `Road.Service` since they share the same config patterns.

---

### Issue 1 — `ColoredConsoleAppender` → `EntryPointNotFoundException`

**Error:**
```
System.EntryPointNotFoundException: GetConsoleOutputCP
  at (wrapper managed-to-native) log4net.Appender.ColoredConsoleAppender.GetConsoleOutputCP()
```

**Root cause:** `log4net.Appender.ColoredConsoleAppender` P/Invokes `GetConsoleOutputCP` from `kernel32.dll` to detect the Windows console code page. That symbol does not exist on macOS/Linux.

**Fix:** In each service's `logconfig.xml`, change the appender type:
```xml
<!-- BEFORE -->
<appender name="ColoredConsoleAppender" type="log4net.Appender.ColoredConsoleAppender">

<!-- AFTER -->
<appender name="ColoredConsoleAppender" type="log4net.Appender.ConsoleAppender">
```
Also remove all `<mapping>` children (color level mappings — ignored by `ConsoleAppender`).

**Status by service:**
| Service | Fixed? |
|---------|--------|
| Center.Service | ✅ Fixed in `a8ed932` |
| Fighting.Service | ✅ Fixed |
| Road.Service | ✅ Fixed |

---

### Issue 2 — `TransactionScope` / MSDTC → `NotImplementedException`

**Error (in `Error.log`, from background timer threads):**
```
System.NotImplementedException: System.Transactions.TransactionInterop.GetExportCookie
  at System.Data.SqlClient.SqlConnection.Open()
```

**Root cause:** Mono's `SqlClient` auto-enlists `SqlConnection` objects into any ambient `TransactionScope` on the thread. Background timers in the game server create implicit ambient transactions (e.g., for retry logic). Mono 6.x does not implement the MSDTC-based distributed transaction promotion path, so any `Open()` call under an ambient transaction throws.

**Fix:** Add `Enlist=False` to every connection string. This disables auto-enlistment. There are no explicit `TransactionScope` usages in the codebase, so there is no functional cost.
```xml
<!-- BEFORE -->
<add key="conString" value="Data Source=KHANHDUY\SQLEXPRESS;Initial Catalog=Project_Player34;...;Password=abc@123" />

<!-- AFTER -->
<add key="conString" value="Data Source=localhost,1433;Initial Catalog=Player34;...;Password=DDTank41@Strong;TrustServerCertificate=True;Enlist=False" />
```

**Status by service:**
| Service | Fixed? |
|---------|--------|
| Center.Service | ✅ Fixed in `016fff7` |
| Fighting.Service | ✅ Fixed |
| Road.Service | ✅ Fixed |

---

### Issue 3 — Buffered log writes invisible during startup (`immediateFlush=false`)

**Symptom:** `tail -f logs/GameServer.log` shows nothing for the first 30–60 seconds of startup. The process appears to hang but is working fine.

**Root cause:** `RollingFileAppender` defaults to buffered I/O. On macOS the OS buffer isn't flushed until it fills or the process flushes. The buffer is large enough to swallow the entire startup log sequence.

**Fix:**
```xml
<!-- In each logconfig.xml, on the GameServerLogFile appender: -->
<immediateFlush value="true"/>
```

**Status by service:**
| Service | Fixed? |
|---------|--------|
| Center.Service | ✅ Fixed in `4db621b` |
| Fighting.Service | ✅ Fixed |
| Road.Service | ✅ Fixed |

---

### Issue 4 — Windows backslash path separators

**Symptom:** Language file not loaded; silent failure (no crash, but localization strings missing).

**Root cause:** `App.config` uses `Languages\Language-vn.txt` with a Windows backslash. Mono on macOS does not normalize path separators, so the file is not found.

**Fix:**
```xml
<!-- BEFORE -->
<add key="LanguagePath" value="Languages\Language-vn.txt" />

<!-- AFTER -->
<add key="LanguagePath" value="Languages/Language-vn.txt" />
```

**Status by service:**
| Service | Fixed? |
|---------|--------|
| Center.Service | ✅ Fixed in `016fff7` |
| Fighting.Service | ❌ Still uses backslash (`Languages\Language-vn.txt`) |
| Road.Service | ❌ Still uses backslash (`Languages\Language-vn.txt`) |

---

### Issue 5 — WCF `netTcpBinding` (net.tcp://) not supported on Mono

**Symptom:** Port 2009 never opens / `net.tcp://` client connections fail silently.

**Root cause:** Mono 6.x's WCF implementation does not support the `net.tcp://` transport. This affects:
- **Center.Service as server:** exposes a `netTcpBinding` listener on port 2009 — it never binds. The `basicHttpBinding` on port 2008 still works.
- **Road.Service as client:** `App.config` has a WCF client endpoint pointing at `net.tcp://127.0.0.1:2009/` (Center.Service). This connection will always fail on Mono.

**Workaround:** Road.Service (and any other client) must be updated to use the `basicHttpBinding` endpoint (`http://127.0.0.1:2008/CenterService/`) instead of the `net.tcp://` endpoint.

**Status:** ❌ Not yet fixed in any service. Requires both config and potentially code changes on the WCF client side.

---

### Issue 6 — `kernel32` P/Invoke for `macrodrop/macroDrop.ini` (Center.Service only)

**Symptom:** Macro-drop feature silently disabled on macOS. No crash, no error log.

**Root cause:** `IniReader` ([Bussiness/IniReader.cs:22](../Bussiness/IniReader.cs)) wraps `GetPrivateProfileString` via `[DllImport("kernel32")]` — a Windows-only API for reading `.ini` files. However, the P/Invoke is **never actually reached** on macOS:

1. `MacroDropMgr.Init()` builds the path as `Directory.GetCurrentDirectory() + "\\macrodrop\\macroDrop.ini"` (hardcoded backslash).
2. On macOS, `\\` is not a path separator — the result is a single filename containing a literal backslash, which does not exist.
3. `LoadDropInfo()` checks `File.Exists(FilePath)` first. It returns `false`, the method returns `null`, and `IniReader` is never instantiated.
4. `Reload()` returns `true` with an empty dictionary. `InitComponent(MacroDropMgr.Init(), "Init MacroDropMgr")` logs success and the server continues normally.
5. The 5-minute timer (`MacroDropSync` / `MacroDropReset`) fires but operates on an empty dictionary — a no-op.

**What the feature does:** Macro-drop is a global item-drop rate limiter designed to counter macro farming (bots grinding for specific items). Each entry in `macroDrop.ini` specifies an item template ID, a `Count` (max drops allowed), and a `Time` (reset interval in 5-minute ticks — e.g. `Time=12` means reset every hour). When an item drops anywhere in the game, game servers report it to Center.Service via `DropNotice`, which decrements that item's remaining count. Every 5 minutes, Center.Service broadcasts current counts to all connected game servers (packet `0xB2`); game servers suppress drops for any item whose count has reached zero. `MacroDropReset` restores counts when their time interval elapses. Net effect: you can cap a rare item to e.g. 50 drops per hour across the entire server, regardless of how many players or bots are farming it. If `macroDrop.ini` is absent or empty, no items are rate-limited and drops work normally — which is the case in this repo.

**Severity:** Non-critical. The kernel32 P/Invoke is dead code on macOS. No crash, no functional regression unless `macroDrop.ini` was actively populated.

**Fix if needed:** Replace `IniReader` with a cross-platform INI parser and fix the path separator in `MacroDropMgr.Init()`.
