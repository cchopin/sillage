/*
  Carte des flux SQL Server : extraction depuis le Query Store
  -----------------------------------------------------------
  Produit un seul document JSON (une ligne, une colonne) à charger dans index.html.
  Lecture seule : uniquement des SELECT sur les vues système, des tables temporaires
  et la lecture du fuseau horaire du serveur.

  Prérequis : SQL Server 2016 ou plus récent, Query Store activé sur les bases à cartographier.
  Droits    : VIEW SERVER STATE et VIEW DATABASE STATE (ou sysadmin).
  Les attentes de verrou ne sont remontées qu'à partir de SQL Server 2017.
*/
SET NOCOUNT ON;
-- Options exigées par la lecture des plans XML. sqlcmd et les travaux de l'Agent SQL désactivent QUOTED_IDENTIFIER par défaut.
SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

-- Réglages -------------------------------------------------------------------
DECLARE @Jours        int           = 7;     -- profondeur d'historique analysée
DECLARE @TopRequetes  int           = 60;    -- requêtes détaillées par base, pour chacun des 3 classements (CPU, lignes, lectures)
DECLARE @TopTables    int           = 200;   -- tables décrites par base (les plus volumineuses)
DECLARE @TexteMax     int           = 300;   -- longueur du texte de requête exporté, 0 pour ne rien exporter
DECLARE @TailleMinMo  int           = 0;     -- ignorer les bases plus petites que ce seuil
DECLARE @Bases        nvarchar(max) = N'';   -- liste de bases séparées par des virgules, vide pour toutes
-------------------------------------------------------------------------------

-- Liste de bases : seuls les espaces autour des virgules sont retirés, pas ceux des noms
WHILE CHARINDEX(N', ', @Bases) > 0 SET @Bases = REPLACE(@Bases, N', ', N',');
WHILE CHARINDEX(N' ,', @Bases) > 0 SET @Bases = REPLACE(@Bases, N' ,', N',');
SET @Bases = LTRIM(RTRIM(@Bases));

-- Fuseau horaire du serveur, pour convertir chaque intervalle avec le décalage en vigueur à sa date
-- (heure d'été ou d'hiver). S'il ne peut pas être déterminé, le décalage actuel est appliqué à tout l'historique.
DECLARE @Fuseau nvarchar(128) = NULL;
BEGIN TRY   -- SQL Server 2022 et plus récent
    EXEC sys.sp_executesql N'SELECT @z = CURRENT_TIMEZONE_ID();', N'@z nvarchar(128) OUTPUT', @z = @Fuseau OUTPUT;
END TRY
BEGIN CATCH
    SET @Fuseau = NULL;
END CATCH;
IF @Fuseau IS NULL
BEGIN TRY   -- versions antérieures, sous Windows : lecture seule dans le registre
    EXEC master.sys.xp_regread N'HKEY_LOCAL_MACHINE', N'SYSTEM\CurrentControlSet\Control\TimeZoneInformation',
                               N'TimeZoneKeyName', @Fuseau OUTPUT;
END TRY
BEGIN CATCH
    SET @Fuseau = NULL;
END CATCH;
IF @Fuseau IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @Fuseau) SET @Fuseau = NULL;

IF OBJECT_ID('tempdb..#bases')  IS NOT NULL DROP TABLE #bases;
IF OBJECT_ID('tempdb..#tables') IS NOT NULL DROP TABLE #tables;
IF OBJECT_ID('tempdb..#req')    IS NOT NULL DROP TABLE #req;
IF OBJECT_ID('tempdb..#obj')    IS NOT NULL DROP TABLE #obj;
IF OBJECT_ID('tempdb..#h')      IS NOT NULL DROP TABLE #h;
IF OBJECT_ID('tempdb..#clients') IS NOT NULL DROP TABLE #clients;

CREATE TABLE #bases  (db sysname NOT NULL, mo bigint NULL, data_mo bigint NULL, log_mo bigint NULL,
                      qs_min int NULL, qs_etat nvarchar(60) NULL, debut datetime2(0) NULL, fin datetime2(0) NULL,
                      erreur nvarchar(1000) NULL);
CREATE TABLE #tables (db sysname NOT NULL, t nvarchar(300) NOT NULL, lignes bigint NULL, mo decimal(18,1) NULL);
CREATE TABLE #req    (db sysname NOT NULL, q bigint NOT NULL, txt nvarchar(max) NULL, obj nvarchar(300) NULL);
CREATE TABLE #obj    (db sysname NOT NULL, q bigint NOT NULL, odb nvarchar(300) NOT NULL, ot nvarchar(600) NOT NULL, w int NOT NULL);
CREATE TABLE #h      (db sysname NOT NULL, q bigint NOT NULL, s int NOT NULL,
                      e float NULL, r float NULL, c float NULL, d float NULL, lr float NULL, lw float NULL, lk float NULL);

INSERT #bases (db, mo, data_mo, log_mo)
SELECT d.name,
       SUM(CONVERT(bigint, mf.size)) * 8 / 1024,
       SUM(CASE WHEN mf.type = 0 THEN CONVERT(bigint, mf.size) ELSE 0 END) * 8 / 1024,
       SUM(CASE WHEN mf.type = 1 THEN CONVERT(bigint, mf.size) ELSE 0 END) * 8 / 1024
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id > 4
  AND d.state = 0
  AND d.is_query_store_on = 1
  AND (@Bases = N'' OR CHARINDEX(N',' + d.name + N',', N',' + @Bases + N',') > 0)
GROUP BY d.name
HAVING SUM(CONVERT(bigint, mf.size)) * 8 / 1024 >= @TailleMinMo;

-- Photo des sessions ouvertes au moment de l'extraction, par base et par login
CREATE TABLE #clients (db sysname NOT NULL, [login] nvarchar(128) NOT NULL, prog nvarchar(128) NULL,
                       hotes int NULL, sessions int NULL, cpu_ms bigint NULL, lr bigint NULL, ecr bigint NULL);
INSERT #clients (db, [login], prog, hotes, sessions, cpu_ms, lr, ecr)
SELECT DB_NAME(s.database_id), s.login_name, MAX(NULLIF(s.program_name, N'')),
       COUNT(DISTINCT s.host_name), COUNT(*),
       SUM(CONVERT(bigint, s.cpu_time)), SUM(CONVERT(bigint, s.logical_reads)), SUM(CONVERT(bigint, s.writes))
FROM sys.dm_exec_sessions s
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
  AND DB_NAME(s.database_id) IN (SELECT db FROM #bases)
GROUP BY s.database_id, s.login_name;

-- Traitement exécuté dans le contexte de chaque base ---------------------------
DECLARE @sql nvarchar(max) = N'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @depuis datetimeoffset = DATEADD(day, -@Jours, SYSDATETIMEOFFSET());
DECLARE @tz varchar(6) = DATENAME(TZOFFSET, SYSDATETIMEOFFSET());

-- Chaque instruction porte la marque /*sillage*/ : le Query Store enregistre aussi les requêtes de l''extraction,
-- et cette marque permet de les écarter aux passages suivants.

-- Début de chaque intervalle en heure locale du serveur
SELECT /*sillage*/ i.runtime_stats_interval_id,
       CASE WHEN @Fuseau IS NOT NULL THEN i.start_time AT TIME ZONE @Fuseau
            ELSE SWITCHOFFSET(i.start_time, @tz) END AS t
INTO #iv
FROM sys.query_store_runtime_stats_interval i
WHERE i.start_time >= @depuis;

-- Statistiques par intervalle, ramenées à un créneau jour x heure (0 = lundi 0 h, 167 = dimanche 23 h), en heure locale du serveur
SELECT /*sillage*/ p.query_id, rs.plan_id, rs.runtime_stats_interval_id,
       (DATEDIFF(day, CONVERT(date, ''19000101''), CONVERT(date, loc.t)) % 7) * 24 + DATEPART(hour, loc.t) AS s,
       CONVERT(float, rs.count_executions)                              AS e,
       rs.avg_rowcount          * rs.count_executions                   AS lig,
       rs.avg_cpu_time          * rs.count_executions / 1000.0          AS cpu_ms,
       rs.avg_duration          * rs.count_executions / 1000.0          AS dur_ms,
       rs.avg_logical_io_reads  * rs.count_executions                   AS lr,
       rs.avg_logical_io_writes * rs.count_executions                   AS lw,
       loc.t                                                            AS t
INTO #rs
FROM sys.query_store_runtime_stats rs
JOIN #iv loc ON loc.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query qq ON qq.query_id = p.query_id
JOIN sys.query_store_query_text qqt ON qqt.query_text_id = qq.query_text_id
WHERE qqt.query_sql_text NOT LIKE N''%/*sillage*/%'';

UPDATE /*sillage*/ b SET qs_min  = o.interval_length_minutes,
             qs_etat = o.actual_state_desc,
             debut   = (SELECT CONVERT(datetime2(0), MIN(t)) FROM #rs),
             fin     = (SELECT CONVERT(datetime2(0), MAX(t)) FROM #rs)
FROM #bases b CROSS JOIN sys.database_query_store_options o
WHERE b.db = DB_NAME();

-- Requêtes retenues : les premières par CPU, par lignes et par lectures logiques
;WITH /*sillage*/ t AS (SELECT query_id, SUM(cpu_ms) AS c, SUM(lig) AS l, SUM(lr) AS lr FROM #rs GROUP BY query_id),
      k AS (SELECT query_id,
                   ROW_NUMBER() OVER (ORDER BY c  DESC) AS rc,
                   ROW_NUMBER() OVER (ORDER BY l  DESC) AS rl,
                   ROW_NUMBER() OVER (ORDER BY lr DESC) AS rr
            FROM t)
SELECT query_id INTO #top FROM k WHERE rc <= @TopRequetes OR rl <= @TopRequetes OR rr <= @TopRequetes;

INSERT /*sillage*/ #req (db, q, txt, obj)
SELECT DB_NAME(), q.query_id,
       CASE WHEN @TexteMax > 0
            THEN LEFT(REPLACE(REPLACE(REPLACE(qt.query_sql_text, CHAR(13), '' ''), CHAR(10), '' ''), CHAR(9), '' ''), @TexteMax) END,
       OBJECT_SCHEMA_NAME(q.object_id) + ''.'' + OBJECT_NAME(q.object_id)
FROM #top t
JOIN sys.query_store_query q ON q.query_id = t.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id;

-- Volumes par requête et par créneau ; les requêtes non retenues sont regroupées sous l''identifiant 0
INSERT /*sillage*/ #h (db, q, s, e, r, c, d, lr, lw, lk)
SELECT DB_NAME(), CASE WHEN t.query_id IS NULL THEN 0 ELSE r.query_id END, r.s,
       SUM(r.e), SUM(r.lig), SUM(r.cpu_ms), SUM(r.dur_ms), SUM(r.lr), SUM(r.lw), 0
FROM #rs r LEFT JOIN #top t ON t.query_id = r.query_id
GROUP BY CASE WHEN t.query_id IS NULL THEN 0 ELSE r.query_id END, r.s;

-- Attentes de verrou (catégorie 3), disponibles à partir de SQL Server 2017
IF OBJECT_ID(''sys.query_store_wait_stats'') IS NOT NULL
    EXEC (N''UPDATE /*sillage*/ h SET lk = w.ms
            FROM #h h
            JOIN (SELECT CASE WHEN t.query_id IS NULL THEN 0 ELSE r.query_id END AS q, r.s,
                         SUM(ws.total_query_wait_time_ms) AS ms
                  FROM (SELECT DISTINCT query_id, plan_id, runtime_stats_interval_id, s FROM #rs) r
                  JOIN sys.query_store_wait_stats ws
                    ON ws.plan_id = r.plan_id AND ws.runtime_stats_interval_id = r.runtime_stats_interval_id
                  LEFT JOIN #top t ON t.query_id = r.query_id
                  WHERE ws.wait_category = 3
                  GROUP BY CASE WHEN t.query_id IS NULL THEN 0 ELSE r.query_id END, r.s) w ON w.q = h.q AND w.s = h.s
            WHERE h.db = DB_NAME();'');

-- Objets touchés par chaque requête retenue, lus dans le plan le plus exécuté
;WITH /*sillage*/ pl AS (SELECT x.query_id, x.plan_id, ROW_NUMBER() OVER (PARTITION BY x.query_id ORDER BY x.e DESC) AS rn
             FROM (SELECT r.query_id, r.plan_id, SUM(r.e) AS e
                   FROM #rs r JOIN #top t ON t.query_id = r.query_id
                   GROUP BY r.query_id, r.plan_id) x)
SELECT pl.query_id, TRY_CONVERT(xml, p.query_plan) AS px
INTO #px
FROM pl JOIN sys.query_store_plan p ON p.plan_id = pl.plan_id
WHERE pl.rn = 1;

INSERT /*sillage*/ #obj (db, q, odb, ot, w)
SELECT DB_NAME(), u.query_id, u.odb, u.osch + ''.'' + u.otbl, MAX(u.w)
FROM (
    SELECT x.query_id,
           REPLACE(REPLACE(o.n.value(''@Database'', ''nvarchar(300)''), ''['', ''''), '']'', '''') AS odb,
           REPLACE(REPLACE(o.n.value(''@Schema'',   ''nvarchar(300)''), ''['', ''''), '']'', '''') AS osch,
           REPLACE(REPLACE(o.n.value(''@Table'',    ''nvarchar(300)''), ''['', ''''), '']'', '''') AS otbl,
           0 AS w
    FROM #px x
    CROSS APPLY x.px.nodes(''//*:Object[@Database and @Schema and @Table]'') o(n)
    WHERE x.px IS NOT NULL
    UNION ALL
    SELECT x.query_id,
           REPLACE(REPLACE(o.n.value(''@Database'', ''nvarchar(300)''), ''['', ''''), '']'', ''''),
           REPLACE(REPLACE(o.n.value(''@Schema'',   ''nvarchar(300)''), ''['', ''''), '']'', ''''),
           REPLACE(REPLACE(o.n.value(''@Table'',    ''nvarchar(300)''), ''['', ''''), '']'', ''''),
           1
    FROM #px x
    CROSS APPLY x.px.nodes(''//*:RelOp[@LogicalOp="Insert" or @LogicalOp="Update" or @LogicalOp="Delete" or @LogicalOp="Merge"]/*/*:Object[@Database and @Schema and @Table]'') o(n)
    WHERE x.px IS NOT NULL
) u
WHERE u.odb NOT IN (''tempdb'', ''mssqlsystemresource'') AND u.osch <> ''sys''
GROUP BY u.query_id, u.odb, u.osch, u.otbl;

-- Volumétrie des tables
INSERT /*sillage*/ #tables (db, t, lignes, mo)
SELECT TOP (@TopTables) DB_NAME(), s.name + ''.'' + t.name,
       SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END),
       SUM(ps.reserved_page_count) * 8 / 1024.0
FROM sys.dm_db_partition_stats ps
JOIN sys.tables  t ON t.object_id = ps.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
GROUP BY s.name, t.name
ORDER BY SUM(ps.reserved_page_count) DESC;
';

DECLARE @db sysname, @exec nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT db FROM #bases ORDER BY db;
OPEN c;
FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @exec = QUOTENAME(@db) + N'.sys.sp_executesql';
        EXEC @exec @sql,
             N'@Jours int, @TopRequetes int, @TopTables int, @TexteMax int, @Fuseau nvarchar(128)',
             @Jours = @Jours, @TopRequetes = @TopRequetes, @TopTables = @TopTables, @TexteMax = @TexteMax, @Fuseau = @Fuseau;
    END TRY
    BEGIN CATCH
        UPDATE #bases SET erreur = LEFT(ERROR_MESSAGE(), 1000) WHERE db = @db;
    END CATCH;
    FETCH NEXT FROM c INTO @db;
END
CLOSE c;
DEALLOCATE c;

-- Document JSON final ------------------------------------------------------------
DECLARE @json nvarchar(max) = (
    SELECT
        @@SERVERNAME                                            AS [meta.serveur],
        CONVERT(nvarchar(40), SERVERPROPERTY('ProductVersion')) AS [meta.version],
        CONVERT(varchar(19), SYSDATETIME(), 126)                AS [meta.extrait_le],
        @Jours                                                  AS [meta.jours],
        @TopRequetes                                            AS [meta.top_requetes],
        ISNULL(@Fuseau, N'décalage actuel ' + DATENAME(TZOFFSET, SYSDATETIMEOFFSET())) AS [meta.fuseau],
        (SELECT db, mo, data_mo, log_mo, qs_min, qs_etat,
                CONVERT(varchar(19), debut, 126) AS debut, CONVERT(varchar(19), fin, 126) AS fin, erreur
         FROM #bases ORDER BY db FOR JSON PATH)                 AS bases,
        (SELECT db, t, lignes, mo FROM #tables FOR JSON PATH)   AS tables,
        (SELECT db, q, txt, obj FROM #req FOR JSON PATH)        AS requetes,
        (SELECT db, q, odb, ot, w FROM #obj FOR JSON PATH)      AS objets,
        (SELECT db, [login], prog, hotes, sessions, cpu_ms, lr, ecr FROM #clients FOR JSON PATH) AS clients,
        (SELECT db, q, s,
                NULLIF(ROUND(e, 0), 0)  AS e,  NULLIF(ROUND(r, 0), 0)  AS r,
                NULLIF(ROUND(c, 0), 0)  AS c,  NULLIF(ROUND(d, 0), 0)  AS d,
                NULLIF(ROUND(lr, 0), 0) AS lr, NULLIF(ROUND(lw, 0), 0) AS lw,
                NULLIF(ROUND(lk, 0), 0) AS lk
         FROM #h FOR JSON PATH)                                 AS horaire
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);

SELECT @json AS json;
