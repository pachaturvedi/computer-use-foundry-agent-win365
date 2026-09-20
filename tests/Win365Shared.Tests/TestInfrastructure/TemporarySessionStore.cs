using Win365Agent;

namespace Win365Shared.Tests;

internal sealed class TemporarySessionStore : IDisposable
{
    private readonly string _folder = Path.Combine(
        Path.GetTempPath(),
        "w365-shared-tests",
        Guid.NewGuid().ToString());

    internal FileSessionStore Create() =>
        new(Path.Combine(_folder, "session.json"));

    public void Dispose()
    {
        if (Directory.Exists(_folder))
        {
            Directory.Delete(_folder, true);
        }
    }
}
