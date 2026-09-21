import { useEffect } from "react"
import { router } from "@inertiajs/react"

// Inertia's before event covers link visits, not the browser's back/forward popstate.
// Do not intercept form submissions: their validation response must preserve the editor.
export function useUnsavedChanges(dirty: boolean) {
  useEffect(() => {
    if (!dirty) return

    const removeListener = router.on("before", event => {
      if (event.detail.visit.method === "get" && !window.confirm("You have unsaved changes. Leave without saving them?")) {
        event.preventDefault()
      }
    })
    const beforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", beforeUnload)

    return () => {
      removeListener()
      window.removeEventListener("beforeunload", beforeUnload)
    }
  }, [dirty])
}
