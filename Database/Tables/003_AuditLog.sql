CREATE TABLE dbo.AuditLog (
    AuditLogId INT IDENTITY(1, 1) NOT NULL,
    Detail     NVARCHAR(400) NOT NUL
);
GO
