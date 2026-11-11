CREATE OR ALTER PROCEDURE dbo.usp_AddGreeting
    @CustomerId INT,
    @Message    NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Customer WHERE CustomerId = @CustomerId)
    BEGIN
        THROW 50001, N'Customer does not exist.', 1;
    END

    INSERT INTO dbo.Greeting (CustomerId, Message, SentAtUtc)
    VALUES (@CustomerId, @Message, SYSUTCDATETIME());

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS GreetingId;
END
GO
