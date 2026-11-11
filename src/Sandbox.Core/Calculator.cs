namespace Sandbox.Core;

public static class Calculator
{
    public static int Add(int a, int b) => a + b;

    public static int Divide(int a, int b)
    {
        if (b == 0)
        {
            throw new DivideByZeroException("Divisor must not be zero.");
        }

        return a / b;
    }
}
