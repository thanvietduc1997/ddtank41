# Center.Service — macOS Feasibility Assessment

**Date:** 2026-05-19  
**Binary targets:** `net48` (Center.Service), `net472` (Center.Server, Bussiness, Game.Base, SqlDataProvider)  
**Build result:** ✅ Builds successfully with .NET 10 SDK (warnings only, no errors)

---

## Executive Summary

Running Center.Service on macOS is **feasible via Mono**, with a few configuration changes required. It is **not runnable with the `dotnet` CLI alone** because the output is a `.NET Framework 4.8` PE32 Windows executable — the modern .NET runtime cannot host it. The path of least resistance is installing Mono and patching the connection strings.

---

## Why `dotnet run` / `dotnet Center.Service.exe` Does Not Work

```
file Center.Service.exe
→ PE32 executable (console) Intel 80386 Mono/.Net assembly, for MS Windows
```

The .NET 10 SDK cross-compiled a `.NET Framework 4.8` assembly (IL bytecode in a PE32 container). On macOS:
- **`dotnet` CLI** can only execute `netcoreapp` / `net5+` binaries with a `runtimeconfig.json`. It cannot host `net48`.
- **`wine`** would run it as a Windows process, but requires a full Wine + .NET Framework install.
- **Mono** is the native cross-platform host for `.NET Framework` binaries and is the correct tool.

---

## Blockers & Their Severity

### 1. Runtime — Mono required (CRITICAL, easy fix)

| | |
|---|---|
| **Problem** | No .NET Framework runtime on macOS by default |
| **Solution** | `brew install mono` |
| **Risk** | Mono 6.x has good .NET 4.8 coverage, but some Windows-specific BCL APIs are stubs |

### 2. WCF ServiceHost with `netTcpBinding` (HIGH risk, Mono-specific)

`CenterService.Start()` calls `new ServiceHost(typeof(CenterService))` and reads the `<system.serviceModel>` section from `App.config`, which configures:
- `net.tcp://127.0.0.1:2009/` (binary RPC)
- `http://127.0.0.1:2008/CenterService/` (metadata)
- `basicHttpBinding` (HTTP endpoint)

Mono has its own WCF implementation that supports `ServiceHost`. In practice:
- `basicHttpBinding` and metadata endpoints work reliably in Mono.
- `netTcpBinding` works in Mono but has known rough edges (binary framing, security negotiation).
- If `netTcpBinding` fails at `host.Open()`, the entire `CenterService.Start()` returns false and the server aborts.

**Mitigation:** Comment out the `netTcpBinding` endpoint in `App.config` if it causes issues; only the login web layer calls this, and `basicHttpBinding` can serve as a fallback.

### 3. `IniReader` P/Invoke to `kernel32.dll` (LOW risk)

```csharp
// Bussiness/IniReader.cs
[DllImport("kernel32")]
private static extern int GetPrivateProfileString(...)
```

Used by `MacroDropMgr.Init()` which reads `macrodrop/macroDrop.ini`. The file **exists** in the build output. However, the path is built with hardcoded backslashes:

```csharp
FilePath = Directory.GetCurrentDirectory() + "\\macrodrop\\macroDrop.ini";
```

On macOS, `File.Exists()` will return **false** for this path (backslashes are not path separators on POSIX). So `LoadDropInfo()` returns null, `Reload()` returns true — `MacroDropMgr.Init()` succeeds silently without ever calling the P/Invoke. The macro-drop feature is effectively disabled.

Mono also partially emulates `GetPrivateProfileString` via its Win32 layer, so the P/Invoke would not crash even if called.

### 4. Database connection strings (REQUIRED config change)

`App.config` hardcodes:
```xml
<add key="conString" value="Data Source=KHANHDUY\SQLEXPRESS;Initial Catalog=Project_Player34;..." />
<add key="crosszoneString" value="Data Source=KHANHDUY\SQLEXPRESS;Initial Catalog=Project_Game34;..." />
```

The Docker container is at `localhost,1433` with databases `Player34` and `Game34`. These must be updated.

### 5. Path separators in config (MINOR, affects Language loading)

`LanguagePath` is `Languages\Language-vn.txt` and `SystemNoticePath` is `Languages\SystemNotice.xml`. Both files exist in the build output. On macOS, the `\` path separator in a config string will cause `File.Exists()` checks to fail. However, Mono often normalizes these via its Path APIs. If `LanguageMgr.Setup("")` fails, the server aborts.

**Mitigation:** Update `App.config` to use forward slashes: `Languages/Language-vn.txt`.

### 6. `System.Web.Security` in `Bussiness/Interface/BaseInterface.cs` (NOT a blocker)

`BaseInterface` uses `System.Web.Security`. However, Center.Server and Center.Service never instantiate any `BaseInterface` subclass — the class is compiled into `Bussiness.dll` but is dead code for this service. No runtime impact.

### 7. `System.CodeDom.Compiler.CSharpCodeProvider` in `ScriptMgr` (NOT a blocker)

`CompileScripts()` scans for `.cs` files in a `scripts/` subdirectory. If empty (which it is), it returns `true` immediately without invoking the compiler. No runtime impact.

---

## Startup Sequence Risk Map

```
CenterServer.Start()
  ├─ GameProperties.Refresh()         → DB query (requires SQL connection) ⚠️
  ├─ RecompileScripts()               → scans scripts/ (empty → OK) ✅
  ├─ StartScriptComponents()          → reflection, no OS calls ✅
  ├─ GameProperties.EDITION == "2612558" → default value matches ✅
  ├─ InitSocket(127.0.0.1:9202)       → TCP listen, IOCP → works in Mono ✅
  ├─ CenterService.Start()            → WCF ServiceHost.Open() ⚠️ (netTcp risk)
  ├─ ServerMgr.Start() → ReLoadServerList() → DB query ⚠️
  ├─ MacroDropMgr.Init()              → IniReader path issue (silent fail) ✅
  ├─ LanguageMgr.Setup("")            → loads Languages\Language-vn.txt ⚠️ (path sep)
  ├─ WorldMgr.Start()                 → DB query ⚠️
  └─ InitGlobalTimers()               → System.Threading.Timer ✅
```

---

## Steps to Run on macOS

### 1. Install Mono

```bash
brew install mono
mono --version   # expect 6.x
```

### 2. Update `App.config` connection strings

Edit `Center.Service/bin/Debug/net48/Center.Service.exe.config` (the deployed copy):

```xml
<add key="conString"
     value="Data Source=localhost,1433;Initial Catalog=Player34;
            Persist Security Info=True;User ID=sa;Password=DDTank41@Strong;
            TrustServerCertificate=True" />
<add key="crosszoneString"
     value="Data Source=localhost,1433;Initial Catalog=Game34;
            Persist Security Info=True;User ID=sa;Password=DDTank41@Strong;
            TrustServerCertificate=True" />
```

Also fix the path separators:
```xml
<add key="LanguagePath" value="Languages/Language-vn.txt" />
<add key="SystemNoticePath" value="Languages/SystemNotice.xml" />
```

### 3. Start SQL Server Docker container

```bash
# If not already running:
bash ducthan/restore.sh

# Verify databases exist:
docker exec -it ddtank-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U SA -P 'DDTank41@Strong' -No \
  -Q "SELECT name FROM sys.databases WHERE name IN ('Player34','Game34','Db_Membership')"
```

### 4. Run the service

```bash
cd /Users/dthan/GithubRepos/pnkl1999/DDTank41/Center.Service/bin/Debug/net48
mono Center.Service.exe --start
```

### 5. Expected output (if successful)

```
[INFO] Recompile Scripts: True
[INFO] Script components: True
[INFO] Check Server Edition:2612558: True
[INFO] InitSocket Port:9202: True
[INFO] Center Service started!
[INFO] Load serverlist: True
[INFO] Init MacroDropMgr: True
[INFO] LanguageMgr Init: True
[INFO] WorldMgr Init: True
[INFO] Init Global Timers: True
[INFO] GameServer is now open for connections!
```

---

## Verification Tests

Once running, verify each layer:

### TCP listener (port 9202)
```bash
nc -z 127.0.0.1 9202 && echo "TCP OK" || echo "TCP FAIL"
```

### WCF HTTP metadata
```bash
curl -s http://127.0.0.1:2008/CenterService/ | grep -i wsdl && echo "WCF HTTP OK"
```

### WCF operation (requires a WCF client or soapui)
```bash
# Simple SOAP test for SystemNotice
curl -s -X POST http://127.0.0.1:2008/CenterService/ \
  -H 'Content-Type: text/xml' \
  -d '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body>
          <SystemNotice xmlns="http://tempuri.org/">
            <msg>test</msg>
          </SystemNotice>
        </s:Body>
      </s:Envelope>' | grep -i "SystemNoticeResult"
```

---

## Alternative: Retarget to .NET 8 (Harder, More Correct Long-Term)

If Mono proves unstable, the service can be retargeted to `net8.0`. Required changes:

| Issue | Change required |
|-------|----------------|
| WCF `ServiceHost` server hosting | Replace with ASP.NET Core + gRPC or REST endpoints |
| `System.Web.Security` in `BaseInterface` | Remove the `using` (dead code for Center.Service) |
| `IniReader` kernel32 P/Invoke | Replace with a pure .NET INI parser |
| `Microsoft.CSharp.CSharpCodeProvider` | Add `Microsoft.CodeDom.Providers.DotNetCompilerPlatform` NuGet package |
| Hardcoded `\\` path separators | Replace with `Path.DirectorySeparatorChar` or forward slashes |

Estimated effort: **2-3 days** (WCF replacement dominates).

---

## Conclusion

| Path | Effort | Risk |
|------|--------|------|
| **Mono** (recommended) | ~1 hour | WCF `netTcpBinding` may need fallback to `basicHttpBinding` |
| **.NET 8 retarget** | 2-3 days | WCF server hosting replacement is the main work |
| **Wine** | ~2 hours setup | Full Windows binary compatibility, heavier runtime |

**Recommended immediate action:** Install Mono, patch `App.config`, run. If `netTcpBinding` fails in Mono, remove that endpoint from `App.config` and rely on `basicHttpBinding` for WCF callers.
