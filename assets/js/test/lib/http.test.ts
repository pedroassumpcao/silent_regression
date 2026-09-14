import axios from "axios"
import { describe, expect, it } from "vitest"

import "@/lib/http"

describe("the shared HTTP client", () => {
  it("uses Phoenix's CSRF header for Inertia mutations", () => {
    expect(axios.defaults.xsrfHeaderName).toBe("x-csrf-token")
  })
})
