IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Customer
    (
        CustomerId   INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
        DisplayName  NVARCHAR(100)      NOT NULL,
        CreatedAtUtc DATETIME2(3)       NOT NULL CONSTRAINT DF_Customer_CreatedAtUtc DEFAULT (SYSUTCDATETIME())
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Customer_DisplayName')
BEGIN
    CREATE INDEX IX_Customer_DisplayName ON dbo.Customer (DisplayName);
END
GO
