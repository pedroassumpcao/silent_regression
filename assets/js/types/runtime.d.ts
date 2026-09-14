import type { LiveSocket } from "phoenix_live_view"

declare global {
  interface Window {
    liveReloader?: {
      enableServerLogs(): void
      openEditorAtCaller(target: EventTarget | null): void
      openEditorAtDef(target: EventTarget | null): void
    }
    liveSocket?: LiveSocket
  }

  interface WindowEventMap {
    "phx:live_reload:attached": CustomEvent<NonNullable<Window["liveReloader"]>>
  }
}

export {}
