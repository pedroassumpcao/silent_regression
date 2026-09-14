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
    "phx:live_reload:attached": CustomEvent<{
      reloader: NonNullable<Window["liveReloader"]>
    }>
  }
}

export {}
