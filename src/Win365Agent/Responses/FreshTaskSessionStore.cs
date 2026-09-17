using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;

namespace Win365Agent;

// This sample intentionally supports fresh tasks, not persisted conversation history.
// Desktop ownership is durable separately; screenshots must not accumulate across requests.
#pragma warning disable MAAI001 // The public hosting SDK's session-store extension point is experimental.
/// <summary>
/// Creates a fresh agent session for every request and intentionally discards conversation session state.
/// </summary>
/// <remarks>Desktop ownership is persisted separately; model screenshots never carry across requests.</remarks>
public sealed class FreshTaskSessionStore : AgentSessionStore
{
    /// <summary>Creates a new agent session without loading prior conversation state.</summary>
    /// <inheritdoc/>
    public override async ValueTask<AgentSession> GetSessionAsync(AIAgent agent, string conversationId,
        string? userId, CancellationToken cancellationToken = default) =>
        await agent.CreateSessionAsync(cancellationToken);

    /// <summary>Completes without persisting the supplied agent session.</summary>
    /// <inheritdoc/>
    public override ValueTask SaveSessionAsync(AIAgent agent, string conversationId, AgentSession session,
        string? userId, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
}
#pragma warning restore MAAI001
