IF OBJECT_ID(N'dbo.Greeting', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Greeting
    (
        GreetingId INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Greeting PRIMARY KEY,
        CustomerId INT                NOT NULL CONSTRAINT FK_Greeting_Customer REFERENCES dbo.Customer (CustomerId),
        Message    NVARCHAR(200)      NOT NULL,
        SentAtUtc  DATETIME2(3)       NOT NULL
    );
END
GO
