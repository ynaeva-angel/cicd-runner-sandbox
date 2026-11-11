namespace Sandbox.Web;

public static class Greeter
{
    public static string Greet(string? name)
    {
        return string.IsNullOrWhiteSpace(name) ? "Hello, guest" : $"Hello, {name.Trim()}";
    }
}
