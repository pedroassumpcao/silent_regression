import "phoenix_html"

import { createInertiaApp, Head, router } from "@inertiajs/react"
import { Socket } from "phoenix"
import { hooks as colocatedHooks } from "phoenix-colocated/silent_regression"
import { LiveSocket } from "phoenix_live_view"
import React from "react"
import { createRoot } from "react-dom/client"

import topbar from "../vendor/topbar"

const csrfToken = document
  .querySelector<HTMLMetaElement>("meta[name='csrf-token']")
  ?.getAttribute("content")

if (csrfToken) {
  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: { ...colocatedHooks },
  })

  liveSocket.connect()
  window.liveSocket = liveSocket
}

topbar.config({
  barColors: { 0: "#6d5dfc" },
  shadowColor: "rgba(15, 23, 42, 0.16)",
})

window.addEventListener("phx:page-loading-start", () => topbar.show(250))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())
router.on("start", () => topbar.show(250))
router.on("finish", () => topbar.hide())

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", event => {
    const reloader = event.detail
    reloader.enableServerLogs()

    let keyDown: string | null = null
    window.addEventListener("keydown", keyboardEvent => (keyDown = keyboardEvent.key))
    window.addEventListener("keyup", () => (keyDown = null))
    window.addEventListener(
      "click",
      clickEvent => {
        if (keyDown === "c") {
          clickEvent.preventDefault()
          clickEvent.stopImmediatePropagation()
          reloader.openEditorAtCaller(clickEvent.target)
        } else if (keyDown === "d") {
          clickEvent.preventDefault()
          clickEvent.stopImmediatePropagation()
          reloader.openEditorAtDef(clickEvent.target)
        }
      },
      true,
    )

    window.liveReloader = reloader
  })
}

const inertiaRoot = document.getElementById("app")

if (inertiaRoot) {
  createInertiaApp({
    title: title => (title ? `${title} · Silent Regression` : "Silent Regression"),
    resolve: async name => (await import(`./pages/${name}.tsx`)).default,
    setup({ App, el, props }) {
      createRoot(el).render(
        <React.StrictMode>
          <App {...props} />
        </React.StrictMode>,
      )
    },
  })
}

export { Head }
