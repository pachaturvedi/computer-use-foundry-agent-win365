"use strict";
const id = location.pathname.split("/").pop();
const status = document.getElementById("status");
const buttons = [...document.querySelectorAll("button")];
let csrf, viewer, interactive = false;
async function api(operation) {
    const response = await fetch(`/api/${encodeURIComponent(id)}/${operation}`, {
        method: "POST", headers: { "X-CSRF-TOKEN": csrf }, credentials: "same-origin"
    });
    if (!response.ok) throw new Error(`Session operation failed (HTTP ${response.status}). Automation remains paused if control was requested.`);
    return response.json();
}
async function connect(control) {
    const data = await api(control ? "control" : "view");
    if (viewer) { await viewer.stop(); viewer = null; }
    interactive = control;
    viewer = new ScreenShareViewer({
        container: document.getElementById("viewer"), sessionLink: data.sessionLink,
        mode: control ? "interactive" : "viewOnly"
    });
    viewer.on("error", async (code) => {
        if (code === "TOKEN_EXPIRED") {
            try { await viewer.updateToken((await api(interactive ? "refresh-control" : "view")).token); }
            catch (error) { status.textContent = error.message; }
        } else status.textContent = `Viewer error: ${code}. Reconnect explicitly; no automatic resume.`;
    });
    await viewer.connect(data.token);
    if (control) await viewer.takeControl();
    status.textContent = control ? "You have control. Explicitly release and resume when finished." : "Watching live.";
}
async function action(fn) {
    buttons.forEach(b => b.disabled = true);
    try { await fn(); } catch (error) { status.textContent = error.message; }
    finally { buttons.forEach(b => b.disabled = false); }
}
document.getElementById("watch").onclick = () => action(() => connect(false));
document.getElementById("control").onclick = () => action(() => connect(true));
document.getElementById("resume").onclick = () => action(async () => {
    if (viewer) { if (interactive) await viewer.releaseControl(); await viewer.stop(); viewer = null; }
    await api("resume");
    interactive = false;
    status.textContent = "Automation resumed. Select Watch live to reconnect without control.";
});
(async () => {
    const response = await fetch(`/api/${encodeURIComponent(id)}`, { credentials: "same-origin" });
    if (!response.ok) throw new Error("Session unavailable, expired, or owned by another operator.");
    const metadata = await response.json();
    csrf = metadata.csrfToken;
    await new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = metadata.sdkUrl; script.onload = resolve;
        script.onerror = () => reject(new Error("Could not load the W365 SDK supplied during onboarding."));
        document.head.appendChild(script);
    });
    status.textContent = `Session ${metadata.phase}. Expires ${new Date(metadata.expiresAt).toLocaleTimeString()}.`;
    buttons.forEach(b => b.disabled = false);
    setTimeout(() => {
        if (viewer) viewer.stop();
        buttons.forEach(b => b.disabled = true);
        status.textContent = "Session expired.";
    }, Math.max(0, new Date(metadata.expiresAt).getTime() - Date.now()));
})().catch(error => { status.textContent = error.message; });
