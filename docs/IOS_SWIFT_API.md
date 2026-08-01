# Swift-facing API snapshot

The exported surface is intentionally small. Review this list whenever Kotlin/Native framework
headers change; renaming or adding public generic types is an API change.

| Export | Ownership/threading contract |
|---|---|
| `OmniTermFacade()` | Swift owns one instance for the scene and calls `close()` at teardown. |
| `currentSnapshot()` | Synchronous immutable value; callable from the main thread. |
| `observe(observer:)` | Calls immediately on the caller thread; UI consumers marshal later events to main if needed. |
| `Observation.cancel()` | Idempotent; releases its callback and is called by the observer owner. |
| `retry()` | Synchronous event; exports no coroutine type. |
| `SwiftShellSnapshot` | Nongeneric DTO: `initializing`, `title`, `errorMessage`. |
| `MainViewController(facade:)` | UIKit root retaining the facade for the controller lifetime. |

Do not export repositories, Ktor clients, `StateFlow`, scopes/jobs, generic stores, secrets, or
internal sealed errors. Add a nongeneric facade DTO or callback instead.
