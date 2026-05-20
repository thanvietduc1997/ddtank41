# Center.Service — macOS Build & Run Runbook

**Last verified:** 2026-05-19 (updated: Enlist=False fix applied)  
**Environment:** macOS (arm64), .NET SDK 10.0.107, Mono 6.14.1

---

## What Was Proven

| Step | Result |
|------|--------|
| `dotnet build` (net48 target) | ✅ Builds with zero errors |
| Server startup sequence | ✅ Reaches "GameServer is now open for connections!" |
| TCP listener port 9202 | ✅ Accepts connections |
| WCF HTTP endpoint port 2008 | ✅ Responds |
| WCF netTcpBinding port 2009 | ❌ Not supported by Mono 6.x |
| DB connectivity (Player34, Game34) | ✅ Queries execute |
| Background timers (all) | ✅ All timers run cleanly (fixed with `Enlist=False` in connection strings) |

---

## Prerequisites

### 1. .NET SDK (for building)

```bash
# Already installed:
dotnet --version   # 10.0.107
```

### 2. Mono (for running net48 binary)

```bash
brew install mono
mono --version     # Mono JIT 6.14.1
```

### 3. SQL Server (Docker)

```bash
# Start the container and restore DBs:
bash ducthan/restore.sh

# Or if already restored, just start:
docker start ddtank-mssql

# Verify:
docker exec ddtank-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U SA -P 'DDTank41@Strong' -No \
  -Q "SELECT name FROM sys.databases WHERE name IN ('Player34','Game34')"
```

---

## Build

```bash
cd /path/to/DDTank41
dotnet build Center.Service/Center.Service.csproj
```

Output lands in: `Center.Service/bin/Debug/net48/`

---

## Run

```bash
cd Center.Service/bin/Debug/net48

# Interactive (recommended for development):
mono Center.Service.exe --start

# Background (for testing):
tail -f /dev/null | mono Center.Service.exe --start &
```

**Note on stdin:** The server's REPL loop calls `Console.ReadLine()`. Always provide a stdin source:
- Foreground terminal: just type commands normally
- Background: pipe `tail -f /dev/null` to keep the process alive without spinning

---

## Expected Startup Log

Successful startup produces this sequence in `logs/GameServer.log`:

```
[INFO] Bussiness.GameProperties        - Refreshing game properties!
[INFO] Center.Server.CenterServer      - Recompile Scripts: True
[INFO] Center.Server.CenterServer      - Script components: True
[INFO] Center.Server.CenterServer      - Check Server Edition:2612558: True
[INFO] Center.Server.CenterServer      - InitSocket Port:9202: True
[INFO] Center.Server.CenterService     - Center Service started!
[INFO] Center.Server.CenterServer      - Center Service: True
[INFO] Center.Server.ServerMgr         - Load server list from db.
[INFO] Center.Server.CenterServer      - Load serverlist: True
[INFO] Center.Server.CenterServer      - Init MacroDropMgr: True
[INFO] Center.Server.CenterServer      - LanguageMgr Init: True
[INFO] Center.Server.WorldMgr          - Total 8 syterm notice loaded.
[INFO] Center.Server.CenterServer      - WorldMgr Init: True
[INFO] Center.Server.CenterServer      - Init Global Timers: True
[INFO] Center.Server.CenterServer      - NewTitleMgr Init: True
[INFO] Center.Server.CenterServer      - WorldEventMgr Init: True
[INFO] Center.Server.CenterServer      - base.Start(): True
[INFO] Center.Server.CenterServer      - GameServer is now open for connections!
```

---

## Verification

After startup, verify from another terminal:

```bash
# TCP game server listener
nc -z 127.0.0.1 9202 && echo "TCP:9202 OK"

# WCF HTTP endpoint
nc -z 127.0.0.1 2008 && echo "WCF-HTTP:2008 OK"

# WCF SOAP call (GetServerList)
curl -s -X POST 'http://127.0.0.1:2008/CenterService/' \
  -H 'Content-Type: text/xml; charset=utf-8' \
  -H 'SOAPAction: "http://tempuri.org/ICenterService/GetServerList"' \
  -d '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body><GetServerList xmlns="http://tempuri.org/"/></s:Body>
      </s:Envelope>'
```

---

## Known Issues on macOS (Non-Blocking)

### 1. `ColoredConsoleAppender` fails (log4net)
```
System.EntryPointNotFoundException: GetConsoleOutputCP
```
`GetConsoleOutputCP` is a Windows-only console API. The colored console appender is skipped; the two file appenders (`GameServer.log`, `Error.log`) work normally. No action needed.

### 2. ~~`System.Transactions.TransactionInterop` — NotImplementedException~~ (Fixed)
**Fixed** by adding `Enlist=False` to both connection strings in the deployed config (`Center.Service.exe.config`). Mono's `SqlClient` auto-enlists connections into ambient transactions, which triggers unimplemented MSDTC code paths. `Enlist=False` disables auto-enlistment; there are no `TransactionScope` usages in the codebase so there is no functional cost.

### 3. WCF `netTcpBinding` (port 2009) not listening
Mono's WCF implementation does not fully support `net.tcp://` transport on macOS. The `basicHttpBinding` endpoint on port 2008 is available as a functional alternative for all WCF callers. If netTcp callers need to be supported, the service would need to run on Windows.

### 4. `macrodrop/macroDrop.ini` — P/Invoke to kernel32
`IniReader.GetPrivateProfileString` P/Invokes `kernel32`. The file exists, but the path is constructed with Windows backslashes and won't be found on macOS, so the P/Invoke is never reached. Macro-drop feature is silently disabled.

---

## Console Commands (while running interactively)

| Command | Effect |
|---------|--------|
| `exit` | Graceful shutdown |
| `notice&<msg>` | Broadcast system notice (note: delimiter is `&` not space) |
| `reload&<type>` | Reload config section |
| `shutdown` | Send shutdown packet to all game servers |
| `help` | Print configured help string |
