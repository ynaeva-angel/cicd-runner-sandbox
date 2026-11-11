namespace Sandbox.Web;

public static class Greeter
{
    public static string Greet(string? name)
    {
        return string.IsNullOrWhiteSpace(name) ? "Hi, guest" : $"Hello, {name.Trim()}";
    }
}
