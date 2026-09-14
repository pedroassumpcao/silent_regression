import axios from "axios"

// Inertia's Phoenix adapter exposes the CSRF token through the XSRF-TOKEN
// cookie. Axios must use Phoenix's expected header name for every mutation.
axios.defaults.xsrfHeaderName = "x-csrf-token"

export { axios }
