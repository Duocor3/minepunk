// MCPassthrough: lets the CET script add a collider to its block entities as they're created (Codeware's
// Entity/Initialize callback is only reachable from a scripted service; the Lua side observes OnInit).
public class MCPTColliderHook extends ScriptableService {
    private cb func OnLoad() {
        GameInstance.GetCallbackSystem().RegisterCallback(n"Entity/Initialize", this, n"OnInit");
    }

    private cb func OnInit(event: ref<EntityLifecycleEvent>) {}
}
