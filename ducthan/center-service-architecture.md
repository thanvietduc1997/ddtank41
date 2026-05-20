# Center.Service — Architecture Overview

## Purpose

**Center.Service** is the centralized coordination hub for the DDTank 3.0 game server infrastructure. It sits between the database layer and multiple Game.Server instances, acting as:

- The login authority (validates credentials, creates players)
- The inter-server message bus (routes chat, guild, item events across servers)
- A background task scheduler (auction, mail, guild, world events)
- An administrative control plane (console + WCF RPC interface)

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Center.Service.exe                    │
│                 (Windows Console Application)             │
│                                                           │
│  Program → IAction Registry → ConsoleStart               │
│                └─ Console REPL (notice/reload/exit/AAS)   │
│                                                           │
│  CenterServer (Singleton)                                 │
│    ├─ TCP Listener       127.0.0.1:9202  (game servers)  │
│    ├─ WCF netTcpBinding  127.0.0.1:2009  (RPC callers)   │
│    ├─ WCF basicHttpBinding               (HTTP callers)   │
│    ├─ Manager layer  (ServerMgr, LoginMgr, ConsortiaMgr) │
│    └─ Periodic timers (save, scan, world events)          │
└──────────────────────────────────────────────────────────┘
      │ TCP 9202        │ WCF 2009        │ ADO.NET (direct)
      ▼                 ▼                 ▼
Game.Server #1…#N  Login/Web svc   MSSQL Player34
                                   MSSQL Game34
                                   MSSQL Db_Membership
```

The topology is **hub-and-spoke**: Center.Service is the single hub; every Game.Server instance is a spoke that maintains a persistent TCP connection to it.

---

## Entry Point

### Program.cs

Parses command-line arguments in the form `--actionName -key=value …` and dispatches to a registered `IAction` implementation. Currently only one action is registered: `--start` → `ConsoleStart`.

```
args: --start -someKey=someValue
         │
   _actions lookup
         │
   ConsoleStart.OnAction(params)
```

### IAction Interface

```csharp
interface IAction {
    string Name        { get; }   // "--start"
    string Syntax      { get; }   // usage line
    string Description { get; }   // help text
    void   OnAction(Hashtable parameters);
}
```

---

## Core Components

### ConsoleStart (Actions/ConsoleStart.cs)

Bootstraps `CenterServer`, then runs an interactive loop reading stdin.

Built-in console commands:

| Command | Effect |
|---------|--------|
| `exit` | Stop server and process |
| `notice <msg>` | Broadcast system notice to all players |
| `reload <type>` | Reload a named configuration section |
| `shutdown` | Graceful server shutdown |
| `AAS TRUE\|FALSE` | Toggle anti-addiction system |
| `help` | Print the configured help string |
| `/anything` | Forward to `CommandMgr.HandleCommandNoPlvl()` |

---

### CenterServer

Inherits `BaseServer`. The singleton that owns everything.

**Startup sequence:**

1. Load `logconfig.xml` for log4net.
2. Parse `App.config` into `CenterServerConfig`.
3. Open database connections (`conString`, `crosszoneString`).
4. Call `ServerMgr.ReLoadServerList()` to populate server registry from DB.
5. Open WCF service endpoints.
6. Start TCP socket listener on configured IP:Port.
7. Arm all periodic timers.

**Key periodic timers:**

| Timer | Interval (config key) | Default | Job |
|-------|-----------------------|---------|-----|
| `m_saveDBTimer` | `SaveInterval` | 1 min | Persist server states to DB |
| `m_loginLapseTimer` | `LoginLapseInterval` | 1 min | Expire idle login sessions |
| `m_saveRecordTimer` | `SaveRecordInterval` | 1 min | Flush transaction logs |
| `m_scanAuction` | `ScanAuctionInterval` | 60 min | Process auction house |
| `m_scanMail` | `ScanMailInterval` | 120 min | Process mail expiry |
| `m_scanConsortia` | `ScanConsortiaInterval` | 1 min | Update guild state |
| `m_worldEvent` | (internal) | — | World events |
| `m_consortiaboss` | (internal) | — | Guild boss battles |

**Broadcast helpers:**

```csharp
SendToALL(GSPacketIn pkg, ServerClient sender)  // all except sender
SendSystemNotice(string msg)
SendReload(string type)
SendShutdown()
SendAAS(bool state)
```

---

### Network Layer (BaseServer / BaseClient)

`BaseServer` manages the TCP listener using `SocketAsyncEventArgs` (IOCP-based async I/O):

```
AcceptAsync()
  └─ AcceptAsyncCompleted()
       └─ GetNewClient()  → creates ServerClient
            └─ ReceiveAsync() loop
```

Buffer sizes:
- Receive per client: **8 KB**
- Send (server): **16 KB**

`BaseClient` holds the raw socket and a `StreamProcessor` that parses the wire stream into discrete `GSPacketIn` packets.

---

### ServerClient

One instance per connected Game.Server. Extends `BaseClient`.

**Packet structure (GSPacketIn):**

```
Offset  Size  Field
   0      2   Header magic (0x7A6B = 29099)
   2      4   ClientID (source server ID)
   6      2   Code (message type)
   8      4   Param1
  12      4   Param2
  16      2   Payload length
  18      N   Payload
```

**Routing logic:**  
`OnProcessPacket()` switches on `packet.Code` and calls the corresponding handler (`HandleChatScene`, `HandleConsortiaCreate`, `HandleBigBugle`, etc.). Most handlers call `_svr.SendToALL()` to broadcast the packet to all other connected servers.

Optional RSA encryption is negotiated per-connection via `RSACryptoServiceProvider` (controlled by `Encrypted` flag).

---

### WCF Service Layer (ICenterService / CenterService)

Exposes RPC operations to external callers (e.g., login web server, billing system).

**Endpoints:**

| Binding | URL | Purpose |
|---------|-----|---------|
| `netTcpBinding` | `net.tcp://127.0.0.1:2009/` | Primary binary RPC |
| `basicHttpBinding` | HTTP | Interop HTTP endpoint |
| Metadata | `http://127.0.0.1:2008/CenterService/` | WSDL / discovery |

Security mode is `None` — assumes trusted internal network.

**Key RPC methods:**

| Method | Description |
|--------|-------------|
| `ValidateLoginAndGetID()` | Authenticate player, return player ID |
| `CreatePlayer()` | Register new account |
| `GetServerList()` | Return active servers with load info |
| `ReLoadServerList()` | Refresh server registry from DB |
| `SystemNotice()` | Broadcast message |
| `KitoffUser()` | Force-disconnect a player |
| `ChargeMoney()` | Process payment |
| `AASUpdateState()` / `AASGetState()` | Anti-addiction system control |
| `GetConfigState()` / `UpdateConfigState()` | Live config query/update |
| `ExperienceRateUpdate()` | Change global EXP multiplier |

---

### Database Access

Center.Service connects to SQL Server **directly** — it does not proxy through Game.Server. The connection is owned by `Center.Server` components via the `Bussiness` project abstraction layer:

```
ServerMgr / CenterService / WorldMgr / ConsortiaBossMgr
  └─ new ServiceBussiness()          (Bussiness project)
       └─ BaseBussiness
            └─ Sql_DbObject("AppConfig", "conString")
                 └─ SqlConnection → SQL Server
```

**Which components query the DB directly:**

| Component | Operations |
|-----------|-----------|
| `ServerMgr` | Load server list on startup; persist server states on save timer |
| `CenterService` (WCF) | `ValidateLoginAndGetID`, `CreatePlayer`, `ChargeMoney`, `GetServerList` |
| `WorldMgr` | World event state |
| `ConsortiaBossMgr` | Guild boss battle persistence |

**Connection strings (App.config):**

| Key | Database | Used for |
|-----|----------|---------|
| `conString` | `Player34` | Player accounts, login, payments |
| `crosszoneString` | `Game34` | Game data, server registry |

Center.Service does **not** access `Db_Membership` directly — that database is used by the web/login layer.

---

### Manager Classes

| Class | Responsibility |
|-------|----------------|
| `ServerMgr` | Registry of Game.Server instances; maps ID → `ServerInfo`; calculates load state (1=offline/2=low/4=high/5=full) |
| `LoginMgr` | Tracks active player sessions; maps player → server |
| `ConsortiaMgr` | Guild operations and state |
| `ConsortiaBossMgr` | Guild boss battle lifecycle |
| `LogMgr` | Transaction/record logging |

---

### Configuration

`CenterServerConfig` maps `App.config` `<appSettings>` keys to typed fields via `[ConfigProperty]` attributes.

**Key settings:**

| Key | Default | Description |
|-----|---------|-------------|
| `IP` | `127.0.0.1` | Bind address for TCP listener |
| `Port` | `9202` | TCP listen port |
| `ServerID` | `4` | Unique ID of this center instance |
| `AreaID` | `1001` | Region/area code |
| `GameType` | `1` | Game mode |
| `LoginLapseInterval` | `1` | Login session timeout (min) |
| `SaveInterval` | `1` | DB save period (min) |
| `ScanAuctionInterval` | `60` | Auction scan period (min) |
| `ScanMailInterval` | `120` | Mail scan period (min) |
| `AAS` | `false` | Anti-addiction system on/off |
| `DailyAwardState` | `true` | Daily rewards on/off |
| `LanguagePath` | `Languages\Language-vn.txt` | Locale strings |
| `SystemNoticePath` | `Languages\SystemNotice.xml` | Rotating notice messages |
| `LogPath` | `RecordLog` | Transaction log directory |

---

### Logging (logconfig.xml / log4net)

Three appenders:

| Appender | Output | Level filter |
|----------|--------|-------------|
| `ColoredConsoleAppender` | stdout (color-coded) | All |
| `GameServerLogFile` | `./logs/GameServer.log` (rolling, max 100 MB) | All |
| `ErrorLogFile` | `./logs/Error.log` (rolling, max 1 MB × 10) | ERROR only |

---

## Request Flow Examples

### Game Server → Cross-Server Chat

```
Player types chat on Game.Server #2
  → Server #2 serialises GSPacketIn(code=Chat)
  → Sends to Center on TCP 9202
  → ServerClient.OnProcessPacket() → HandleChatScene()
  → CenterServer.SendToALL(pkg, clientFrom2)
  → All other ServerClients receive and forward to their local players
```

### Login Web → Player Validation

```
Web login page calls ICenterService.ValidateLoginAndGetID(user, pass)
  → WCF net.tcp 127.0.0.1:2009
  → CenterService.ValidateLoginAndGetID()
  → ServiceBussiness DB query on Player34
  → Returns playerID (or error code)
  → LoginMgr.AddSession(playerID)
  → Web redirects player to chosen Game.Server
```

### Console Operator → System Notice

```
Operator types: notice Server will restart in 10 minutes
  → ConsoleStart loop parses command
  → CenterServer.SendSystemNotice("Server will restart in 10 minutes")
  → SendToALL(notice packet)
  → Every connected Game.Server broadcasts to all online players
```

---

## Design Patterns

| Pattern | Where |
|---------|-------|
| Singleton | `CenterServer._instance` |
| Command / Strategy | `IAction` + action registry in `Program` |
| Factory | `BaseServer.GetNewClient()` |
| Observer / Event | `BaseClient.Disconnected` event |
| Hub-and-Spoke broadcast | `CenterServer.SendToALL()` |
| Timer-driven background jobs | `System.Threading.Timer` instances |
| Service Locator | `CenterServer.Instance` global access |

---

## Dependencies

| Dependency | Version / Notes |
|------------|-----------------|
| .NET Framework | 4.8 (legacy) |
| log4net | 2.0.14 |
| System.ServiceModel (WCF) | .NET built-in |
| System.Net.Sockets | .NET built-in |
| SQL Server | via `ServiceBussiness` ADO.NET wrapper |
| **Project refs** | `Center.Server`, `Game.Base`, `Bussiness` |

---

## Notable Limitations

- **No WCF authentication** — relies entirely on network-level trust (internal LAN only).
- **Plain-text credentials** in `App.config`.
- **Broadcast is O(n)** — every cross-server message iterates all connected servers.
- **Console loop blocks main thread** on `Console.ReadLine()`.
- Legacy `ArrayList` / `HybridDictionary` instead of generic collections.
- No packet batching — each event is sent individually.
