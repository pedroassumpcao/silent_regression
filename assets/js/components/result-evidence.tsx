import type { ReactNode } from "react"

import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import type { AlertCategory, AlertSeverity, AlertStatus, BoundedText } from "@/types/results"

export function SeverityBadge({ severity }: { severity: AlertSeverity }) {
  return (
    <Badge
      variant={severity === "critical" ? "destructive" : "outline"}
      className={severity === "warning" ? "border-amber-500/35 bg-amber-500/10 text-amber-800 dark:text-amber-300" : ""}
    >
      {severity}
    </Badge>
  )
}

export function AlertStatusBadge({ status }: { status: AlertStatus }) {
  const className = status === "resolved"
    ? "border-success/30 bg-success/10 text-success"
    : status === "acknowledged"
      ? "border-primary/25 bg-primary/10 text-primary"
      : ""

  return <Badge variant="outline" className={className}>{label(status)}</Badge>
}

export function CategoryBadge({ category }: { category: AlertCategory }) {
  return (
    <Badge variant="secondary">
      {category === "contract_failure" ? "Contract failure" : "Operational anomaly"}
    </Badge>
  )
}

export function RunStatusBadge({ status }: { status: string }) {
  const good = status === "succeeded"
  const active = ["planned", "queued", "running"].includes(status)

  return (
    <Badge
      variant="outline"
      className={cn(
        good && "border-success/30 bg-success/10 text-success",
        active && "border-primary/25 bg-primary/10 text-primary",
        !good && !active && status !== "cancelled" && "border-amber-500/35 bg-amber-500/10 text-amber-800 dark:text-amber-300",
      )}
    >
      {label(status)}
    </Badge>
  )
}

export function Metric({ label: metricLabel, value, detail, tone = "default" }: {
  label: string
  value: ReactNode
  detail?: ReactNode
  tone?: "default" | "success" | "warning" | "danger"
}) {
  return (
    <div className="min-w-0 rounded-xl border bg-background/70 p-4">
      <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted-foreground">{metricLabel}</p>
      <p className={cn(
        "mt-2 break-words text-xl font-semibold tabular-nums",
        tone === "success" && "text-success",
        tone === "warning" && "text-amber-700 dark:text-amber-300",
        tone === "danger" && "text-destructive",
      )}>{value}</p>
      {detail && <div className="mt-1 break-words text-xs leading-5 text-muted-foreground">{detail}</div>}
    </div>
  )
}

export function BoundedTextBlock({ value, empty = "Not available" }: {
  value: BoundedText | null
  empty?: string
}) {
  if (!value) return <p className="text-sm text-muted-foreground">{empty}</p>

  return (
    <div className="space-y-2">
      <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-xl border bg-muted/35 p-4 font-mono text-xs leading-6 [overflow-wrap:anywhere]">{value.text}</pre>
      {value.truncated && (
        <p className="text-xs text-muted-foreground">
          Browser preview truncated from {formatNumber(value.originalBytes)} bytes. The immutable stored evidence is unchanged.
        </p>
      )}
    </div>
  )
}

export function StructuredEvidence({ value }: { value: unknown }) {
  return (
    <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-xl border bg-muted/35 p-4 font-mono text-xs leading-6 [overflow-wrap:anywhere]">
      {JSON.stringify(value ?? {}, null, 2)}
    </pre>
  )
}

export function label(value: string) {
  return value.replaceAll("_", " ").replace(/\b\w/g, character => character.toUpperCase())
}

export function formatUtc(value: string | null) {
  if (!value) return "Not finished"
  return new Intl.DateTimeFormat("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "UTC",
  }).format(new Date(value)) + " UTC"
}

export function formatNumber(value: number) {
  return new Intl.NumberFormat("en-US").format(value)
}

export function shortId(value: string | null | undefined) {
  if (!value) return "—"
  return `${value.slice(0, 8)}…${value.slice(-6)}`
}
