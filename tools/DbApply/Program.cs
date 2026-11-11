using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

// Applies every .sql file under a folder to a throwaway database, then drops it.
// Catches what a syntax check cannot: wrong order, missing objects, bad references.
//
//   DbApply <folder> <server> [<server> ...]
//
// The first server that accepts a Windows-authenticated connection is used.
// Exit code 0 = all scripts applied, 1 = a script failed, 2 = bad arguments,
// 3 = no SQL Server reachable.

if (args.Length < 2 || !Directory.Exists(args[0]))
{
    Console.Error.WriteLine("usage: DbApply <folder with .sql files> <server> [<server> ...]");
    return 2;
}

var root = Path.GetFullPath(args[0]);

// CI_SQL_PASSWORD set = SQL authentication (the throwaway container); otherwise Windows authentication.
var sqlPassword = Environment.GetEnvironmentVariable("CI_SQL_PASSWORD");
var sqlUser = Environment.GetEnvironmentVariable("CI_SQL_USER") ?? "sa";
// A container needs a while before it accepts logins: keep retrying this long.
_ = int.TryParse(Environment.GetEnvironmentVariable("CI_SQL_WAIT_SECONDS"), out var waitSeconds);

string ConnectionString(string server, string database)
{
    var b = new SqlConnectionStringBuilder
    {
        DataSource = server,
        InitialCatalog = database,
        TrustServerCertificate = true,
        Encrypt = false,
        ConnectTimeout = 8,
        Pooling = false,
    };
    if (string.IsNullOrEmpty(sqlPassword)) { b.IntegratedSecurity = true; }
    else { b.UserID = sqlUser; b.Password = sqlPassword; }
    return b.ConnectionString;
}

string? server = null;
foreach (var candidate in args.Skip(1).Where(a => !string.IsNullOrWhiteSpace(a)))
{
    var deadline = DateTime.UtcNow.AddSeconds(waitSeconds);
    retry:
    try
    {
        using var probe = new SqlConnection(ConnectionString(candidate, "master"));
        probe.Open();
        using var cmd = new SqlCommand(
            "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS nvarchar(10)) + N' / ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(100))", probe);
        var version = (string?)cmd.ExecuteScalar() ?? "?";
        Console.WriteLine($"db apply: using {candidate} (major version / edition: {version})");
        if (!version.StartsWith("16 "))
        {
            Console.WriteLine("db apply: note - this is not SQL Server 2022 (major version 16)");
        }
        server = candidate;
        break;
    }
    catch (Exception e)
    {
        if (DateTime.UtcNow < deadline)
        {
            Thread.Sleep(3000);
            goto retry;
        }
        Console.WriteLine($"db apply: {candidate} not usable - {e.Message.Split('\n')[0].Trim()}");
    }
}

if (server is null)
{
    Console.WriteLine("DBERROR no SQL Server instance accepted a connection from this account.");
    Console.WriteLine("db apply: install SQL Server Express or LocalDB on this machine, give the build account");
    Console.WriteLine("db apply: the dbcreator role, or name the instance in the CI_SQL_SERVER environment variable.");
    return 3;
}

// Tables first, then everything else; inside a folder, by file name.
var files = Directory.GetFiles(root, "*.sql", SearchOption.AllDirectories)
    .Select(f => new { Full = f, Rel = Path.GetRelativePath(root, f).Replace('\\', '/') })
    .OrderBy(f => f.Rel.StartsWith("Tables/", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
    .ThenBy(f => f.Rel, StringComparer.OrdinalIgnoreCase)
    .ToList();

var database = $"ci_apply_{DateTime.UtcNow:yyyyMMdd_HHmmss}_{Environment.ProcessId}";
var batchSeparator = new Regex(@"^\s*GO\s*(--.*)?$", RegexOptions.IgnoreCase);
var failed = false;

using (var master = new SqlConnection(ConnectionString(server, "master")))
{
    master.Open();
    using (var create = new SqlCommand($"CREATE DATABASE [{database}]", master)) { create.CommandTimeout = 120; create.ExecuteNonQuery(); }
    Console.WriteLine($"db apply: created throwaway database {database}");

    try
    {
        using var db = new SqlConnection(ConnectionString(server, database));
        db.Open();

        foreach (var file in files)
        {
            var lines = File.ReadAllLines(file.Full);
            var batch = new List<string>();
            var batchStart = 1;

            bool Run()
            {
                var sql = string.Join("\n", batch);
                if (string.IsNullOrWhiteSpace(sql)) { return true; }
                try
                {
                    using var cmd = new SqlCommand(sql, db) { CommandTimeout = 120 };
                    cmd.ExecuteNonQuery();
                    return true;
                }
                catch (SqlException e)
                {
                    // "DBERROR" lines are what the PR comment and the job summary pick up.
                    Console.WriteLine($"DBERROR {file.Rel}({batchStart + Math.Max(e.LineNumber, 1) - 1}): {e.Message.Split('\n')[0].Trim()}");
                    return false;
                }
            }

            var ok = true;
            for (var i = 0; i < lines.Length && ok; i++)
            {
                if (batchSeparator.IsMatch(lines[i]))
                {
                    ok = Run();
                    batch.Clear();
                    batchStart = i + 2;
                }
                else
                {
                    batch.Add(lines[i]);
                }
            }
            if (ok) { ok = Run(); }

            if (!ok) { failed = true; break; }   // stop at the first error, like an install would
            Console.WriteLine($"applied  {file.Rel}");
        }
    }
    finally
    {
        SqlConnection.ClearAllPools();
        using var drop = new SqlCommand(
            $"ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{database}]", master) { CommandTimeout = 120 };
        drop.ExecuteNonQuery();
        Console.WriteLine($"db apply: dropped {database}");
    }
}

Console.WriteLine(failed
    ? "db apply: FAILED - a script did not apply"
    : $"db apply: {files.Count} script(s) applied in order, no errors");
return failed ? 1 : 0;
