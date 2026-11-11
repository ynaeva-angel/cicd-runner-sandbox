using Microsoft.SqlServer.TransactSql.ScriptDom;

// Parses every .sql file under the given folder with the SQL Server 2022 grammar.
// Syntax only: nothing is executed and no database is needed.
// Exit code 0 = all files parse, 1 = at least one syntax error, 2 = bad arguments.

if (args.Length != 1 || !Directory.Exists(args[0]))
{
    Console.Error.WriteLine("usage: SqlSyntaxChecker <folder with .sql files>");
    return 2;
}

var root = Path.GetFullPath(args[0]);
var files = Directory.GetFiles(root, "*.sql", SearchOption.AllDirectories);
Array.Sort(files, StringComparer.OrdinalIgnoreCase);

var failedFiles = 0;
var errorCount = 0;

foreach (var file in files)
{
    var parser = new TSql160Parser(initialQuotedIdentifiers: true);
    IList<ParseError> errors;
    using (var reader = new StreamReader(file, detectEncodingFromByteOrderMarks: true))
    {
        parser.Parse(reader, out errors);
    }

    var relative = Path.GetRelativePath(root, file).Replace('\\', '/');
    if (errors.Count == 0)
    {
        Console.WriteLine($"ok    {relative}");
        continue;
    }

    failedFiles++;
    errorCount += errors.Count;
    foreach (var e in errors)
    {
        // "SQLERROR" lines are what the worker lifts into the PR comment.
        Console.WriteLine($"SQLERROR {relative}({e.Line},{e.Column}): {e.Message}");
    }
}

Console.WriteLine(failedFiles == 0
    ? $"sql check: {files.Length} file(s) parsed, no syntax errors"
    : $"sql check: {errorCount} syntax error(s) in {failedFiles} of {files.Length} file(s)");
return failedFiles == 0 ? 0 : 1;
