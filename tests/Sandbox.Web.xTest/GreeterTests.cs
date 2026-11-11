using Sandbox.Web;

namespace Sandbox.Web.xTest;

public class GreeterTests
{
    [Fact]
    public void Greet_uses_the_trimmed_name()
    {
        Assert.Equal("Hello, Ada", Greeter.Greet("  Ada "));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void Greet_falls_back_to_guest(string? name)
    {
        Assert.Equal("Hello, guest", Greeter.Greet(name));
    }
}
