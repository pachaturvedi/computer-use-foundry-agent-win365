using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;

namespace Win365Agent;

// This sample intentionally supports fresh tasks, not persisted conversation history.
// Desktop ownership is durable separately; screenshots must not accumulate across requests.
#pragma warning disable MAAI001 // The public hosting SDK's session-store extension point is experimental.
public sealed class FreshTaskSessionStore : AgentSessionStore
{
    public override async ValueTask<AgentSession> GetSessionAsync(AIAgent agent, string conversationId,
        string? userId, CancellationToken cancellationToken = default) =>
        await agent.CreateSessionAsync(cancellationToken);
    public override ValueTask SaveSessionAsync(AIAgent agent, string conversationId, AgentSession session,
        string? userId, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
}
#pragma warning restore MAAI001
