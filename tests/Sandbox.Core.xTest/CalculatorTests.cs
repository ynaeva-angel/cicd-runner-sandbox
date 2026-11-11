using Sandbox.Core;

namespace Sandbox.Core.xTest;

public class CalculatorTests
{
    [Theory]
    [InlineData(1, 2, 3)]
    [InlineData(-4, 4, 0)]
    public void Add_returns_the_sum(int a, int b, int expected)
    {
        Assert.Equal(expected, Calculator.Add(a, b));
    }

    [Fact]
    public void Divide_returns_the_quotient()
    {
        Assert.Equal(5, Calculator.Divide(10, 2));
    }

    [Fact]
    public void Divide_by_zero_throws()
    {
        Assert.Throws<DivideByZeroException>(() => Calculator.Divide(1, 0));
    }
}
