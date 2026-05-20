-- DDTank41 database restore script
-- Dynamically reads logical file names from each backup, then restores.

DECLARE @sql NVARCHAR(MAX);

-- Temp table matching RESTORE FILELISTONLY output (SQL Server 2019: 22 columns)
CREATE TABLE #fl (
  LogicalName          NVARCHAR(128),
  PhysicalName         NVARCHAR(260),
  Type                 CHAR(1),
  FileGroupName        NVARCHAR(128),
  Size                 NUMERIC(20,0),
  MaxSize              NUMERIC(20,0),
  FileId               BIGINT,
  CreateLSN            NUMERIC(25,0),
  DropLSN              NUMERIC(25,0),
  UniqueId             UNIQUEIDENTIFIER,
  ReadOnlyLSN          NUMERIC(25,0),
  ReadWriteLSN         NUMERIC(25,0),
  BackupSizeInBytes    BIGINT,
  SourceBlockSize      INT,
  FileGroupId          INT,
  LogGroupGUID         UNIQUEIDENTIFIER,
  DifferentialBaseLSN  NUMERIC(25,0),
  DifferentialBaseGUID UNIQUEIDENTIFIER,
  IsReadOnly           BIT,
  IsPresent            BIT,
  TDEThumbprint        VARBINARY(32),
  SnapshotUrl          NVARCHAR(360)
);

-- ── Restore Player34 ─────────────────────────────────────────────────────────
PRINT '>>> Restoring Player34...';
TRUNCATE TABLE #fl;
INSERT INTO #fl EXEC('RESTORE FILELISTONLY FROM DISK = ''/var/opt/mssql/backup/Player34.bak''');

DECLARE @p_data NVARCHAR(128), @p_log NVARCHAR(128);
SELECT @p_data = LogicalName FROM #fl WHERE Type = 'D';
SELECT @p_log  = LogicalName FROM #fl WHERE Type = 'L';
PRINT '  Data file: ' + @p_data;
PRINT '  Log  file: ' + @p_log;

SET @sql = N'
RESTORE DATABASE [Player34]
FROM DISK = ''/var/opt/mssql/backup/Player34.bak''
WITH
  MOVE ''' + @p_data + ''' TO ''/var/opt/mssql/data/Player34.mdf'',
  MOVE ''' + @p_log  + ''' TO ''/var/opt/mssql/data/Player34_log.ldf'',
  REPLACE, STATS = 10;';
EXEC(@sql);
PRINT '>>> Player34 restored.';
GO

-- ── Restore Game34 ───────────────────────────────────────────────────────────
PRINT '>>> Restoring Game34...';
CREATE TABLE #fl2 (
  LogicalName NVARCHAR(128), PhysicalName NVARCHAR(260), Type CHAR(1),
  FileGroupName NVARCHAR(128), Size NUMERIC(20,0), MaxSize NUMERIC(20,0),
  FileId BIGINT, CreateLSN NUMERIC(25,0), DropLSN NUMERIC(25,0),
  UniqueId UNIQUEIDENTIFIER, ReadOnlyLSN NUMERIC(25,0), ReadWriteLSN NUMERIC(25,0),
  BackupSizeInBytes BIGINT, SourceBlockSize INT, FileGroupId INT,
  LogGroupGUID UNIQUEIDENTIFIER, DifferentialBaseLSN NUMERIC(25,0),
  DifferentialBaseGUID UNIQUEIDENTIFIER, IsReadOnly BIT, IsPresent BIT,
  TDEThumbprint VARBINARY(32), SnapshotUrl NVARCHAR(360)
);
INSERT INTO #fl2 EXEC('RESTORE FILELISTONLY FROM DISK = ''/var/opt/mssql/backup/Game34.bak''');

DECLARE @g_data NVARCHAR(128), @g_log NVARCHAR(128), @sql2 NVARCHAR(MAX);
SELECT @g_data = LogicalName FROM #fl2 WHERE Type = 'D';
SELECT @g_log  = LogicalName FROM #fl2 WHERE Type = 'L';
PRINT '  Data file: ' + @g_data;
PRINT '  Log  file: ' + @g_log;

SET @sql2 = N'
RESTORE DATABASE [Game34]
FROM DISK = ''/var/opt/mssql/backup/Game34.bak''
WITH
  MOVE ''' + @g_data + ''' TO ''/var/opt/mssql/data/Game34.mdf'',
  MOVE ''' + @g_log  + ''' TO ''/var/opt/mssql/data/Game34_log.ldf'',
  REPLACE, STATS = 10;';
EXEC(@sql2);
PRINT '>>> Game34 restored.';
GO

-- ── Restore Db_Membership ────────────────────────────────────────────────────
PRINT '>>> Restoring Db_Membership...';
CREATE TABLE #fl3 (
  LogicalName NVARCHAR(128), PhysicalName NVARCHAR(260), Type CHAR(1),
  FileGroupName NVARCHAR(128), Size NUMERIC(20,0), MaxSize NUMERIC(20,0),
  FileId BIGINT, CreateLSN NUMERIC(25,0), DropLSN NUMERIC(25,0),
  UniqueId UNIQUEIDENTIFIER, ReadOnlyLSN NUMERIC(25,0), ReadWriteLSN NUMERIC(25,0),
  BackupSizeInBytes BIGINT, SourceBlockSize INT, FileGroupId INT,
  LogGroupGUID UNIQUEIDENTIFIER, DifferentialBaseLSN NUMERIC(25,0),
  DifferentialBaseGUID UNIQUEIDENTIFIER, IsReadOnly BIT, IsPresent BIT,
  TDEThumbprint VARBINARY(32), SnapshotUrl NVARCHAR(360)
);
INSERT INTO #fl3 EXEC('RESTORE FILELISTONLY FROM DISK = ''/var/opt/mssql/backup/Db_Membership.bak''');

DECLARE @m_data NVARCHAR(128), @m_log NVARCHAR(128), @sql3 NVARCHAR(MAX);
SELECT @m_data = LogicalName FROM #fl3 WHERE Type = 'D';
SELECT @m_log  = LogicalName FROM #fl3 WHERE Type = 'L';
PRINT '  Data file: ' + @m_data;
PRINT '  Log  file: ' + @m_log;

SET @sql3 = N'
RESTORE DATABASE [Db_Membership]
FROM DISK = ''/var/opt/mssql/backup/Db_Membership.bak''
WITH
  MOVE ''' + @m_data + ''' TO ''/var/opt/mssql/data/Db_Membership.mdf'',
  MOVE ''' + @m_log  + ''' TO ''/var/opt/mssql/data/Db_Membership_log.ldf'',
  REPLACE, STATS = 10;';
EXEC(@sql3);
PRINT '>>> Db_Membership restored.';
GO

-- ── Summary ──────────────────────────────────────────────────────────────────
SELECT name, state_desc, create_date
FROM sys.databases
WHERE name IN ('Player34', 'Game34', 'Db_Membership')
ORDER BY name;
