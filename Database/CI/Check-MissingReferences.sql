SET NOCOUNT ON;
DECLARE @problems TABLE (module sysname, problem nvarchar(4000));

INSERT INTO @problems
SELECT DISTINCT OBJECT_NAME(d.referencing_id), N'references missing object ' + d.referenced_entity_name
FROM sys.sql_expression_dependencies d
WHERE d.referenced_id IS NULL
  AND d.referenced_database_name IS NULL
  AND d.referenced_server_name IS NULL
  AND d.referenced_entity_name NOT LIKE N'#%'
  AND d.referenced_entity_name NOT LIKE N'@%'
  AND d.referenced_entity_name NOT IN (N'INSERTED', N'DELETED')
  AND OBJECT_ID(ISNULL(d.referenced_schema_name, N'dbo') + N'.' + d.referenced_entity_name) IS NULL
  AND TYPE_ID(ISNULL(d.referenced_schema_name, N'dbo') + N'.' + d.referenced_entity_name) IS NULL;

DECLARE @name nvarchar(517);
DECLARE m CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name)
    FROM sys.sql_modules sm JOIN sys.objects o ON o.object_id = sm.object_id
    WHERE o.is_ms_shipped = 0 AND o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'TR');
OPEN m;
FETCH NEXT FROM m INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sys.sp_refreshsqlmodule @name; END TRY
    BEGIN CATCH INSERT INTO @problems VALUES (@name, N'does not recompile: ' + ERROR_MESSAGE()); END CATCH
    FETCH NEXT FROM m INTO @name;
END

SELECT module, problem FROM @problems ORDER BY module, problem;
IF EXISTS (SELECT 1 FROM @problems)
BEGIN
    DECLARE @n int = (SELECT COUNT(*) FROM @problems);
    RAISERROR('%d missing reference(s)', 16, 1, @n);
END
