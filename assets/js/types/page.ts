export type SharedPageProps = {
  [key: string]: unknown
  auth: {
    user: { id: string; email: string } | null
    workspace: { id: string; name: string; slug: string } | null
    membership: { id: string; role: "owner" | "member" } | null
    workspaces: Array<{
      id: string
      name: string
      slug: string
      role: "owner" | "member"
      current: boolean
    }>
  }
  errors: Record<string, string>
  flash: { info?: string; error?: string }
}
