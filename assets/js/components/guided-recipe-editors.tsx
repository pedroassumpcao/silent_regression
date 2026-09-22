import type { ReactNode } from "react"
import { Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"

export type Recipe = "routing" | "json" | "sources" | "text"
export type JsonField = { key: string; type: string }
export type RecipeSettings = { fields?: JsonField[]; allowedText?: string; requiredText?: string; prohibitedText?: string; factText?: string; factSourceId?: string; distance?: string }
export const recipeNames: Record<Recipe, string> = { routing: "Classification / routing", json: "Structured JSON", sources: "Answers with source IDs", text: "Required / prohibited text" }
export const recipeGuidance: Record<Recipe, string> = {
  routing: "Shared: the whole answer is an allowed label. Case: it is the correct label for this input. A wrong allowed label should pass shared checks and fail the case check.",
  json: "Shared: raw JSON with every declared field present and correctly typed. Case: each field matches your independently known value or inclusive numeric tolerance. Extra keys are allowed. No factual correctness is inferred.",
  sources: "Shared: allowed bracketed IDs, required IDs and any declared literal attribution. Case: the exact source-ID set you chose for this input. These are syntactic checks—not source retrieval, entailment, or general factual correctness.",
  text: "Shared: at least one required alternative (if configured), and none of the prohibited alternatives. Case: at least one literal answer alternative for this input. Unicode/case/punctuation/whitespace are normalized; paraphrases and contradictions are not understood.",
}

export function RecipeSettingsEditor({ recipe, settings, onChange }: { recipe: Exclude<Recipe, "routing">; settings: RecipeSettings; onChange: (value: RecipeSettings) => void }) {
  const update = (key: keyof RecipeSettings, value: string) => onChange({ ...settings, [key]: value })
  if (recipe === "json") {
    const fields = settings.fields || []
    const fieldChange = (index: number, values: Partial<JsonField>) => onChange({ fields: fields.map((field, i) => i === index ? { ...field, ...values } : field) })
    return <div className="space-y-4">
      <p className="text-sm leading-6">Which fields must every answer contain? Add 1–4 top-level fields, then enter the known values below. Renaming, removing or changing a field type clears only its affected example values and resets proof review.</p>
      {fields.map((field, index) => <fieldset key={index} className="space-y-3 rounded-lg border p-4"><legend className="px-1 text-sm font-medium">Required field {index + 1}</legend><div className="grid gap-3 sm:grid-cols-2">
        <Field id={`json-key-${index}`} label={`Field ${index + 1} name`}><Input id={`json-key-${index}`} maxLength={40} placeholder="total" value={field.key} onChange={event => fieldChange(index, { key: event.target.value })} /></Field>
        <Choice id={`json-type-${index}`} label={`Field ${index + 1} type`} value={field.type} options={["string", "number", "integer", "boolean"]} onChange={type => fieldChange(index, { type })} />
      </div><Button size="sm" variant="ghost" onClick={() => onChange({ fields: fields.filter((_, i) => i !== index) })}><Trash2 /> Remove field {index + 1}</Button></fieldset>)}
      <Button variant="outline" disabled={fields.length >= 4} onClick={() => onChange({ fields: [...fields, { key: "", type: "string" }] })}><Plus /> Add required field</Button>
      <p className="text-xs leading-5 text-muted-foreground">Not a JSON Schema editor. No nested paths, arrays/objects/null, optional fields, enums, regex, formats, or rejection of extra keys here. Some additional deterministic rules are available in advanced setup; unsupported schema features are not silently applied. Field names use letters, digits and underscores, starting with a letter or underscore. The request must already ask for JSON; we never modify it.</p>
      <Example title="Example: invoice extraction">Field <code>total</code>: number. For an invoice known to total 12.50, enter target 12.50 and tolerance 0.01 (12.49–12.51 inclusive). A string like <code>"12.50"</code> fails the type check. These are illustrations, not prefilled answers.</Example>
    </div>
  }
  if (recipe === "sources") return <div className="space-y-4">
    <TextField id="source-allowed" label="Allowed source IDs — one per line" value={settings.allowedText || ""} placeholder={"billing\nrefunds"} onChange={value => update("allowedText", value)} />
    <TextField id="source-required" label="Source IDs required in every answer (optional)" value={settings.requiredText || ""} onChange={value => update("requiredText", value)} />
    <p className="text-xs leading-5 text-muted-foreground">1–8 distinct IDs, up to 40 characters each. Letters/digits and . _ : - are supported. Outputs must cite IDs as [billing], not Markdown links. IDs are case-sensitive. Enter IDs without brackets in these fields.</p>
    <details open={Boolean(settings.factText || settings.factSourceId)} className="rounded-lg border p-4"><summary className="cursor-pointer text-sm font-medium">{settings.factText || settings.factSourceId ? "Configured attribution: declared phrase and source" : "Optional: attach a declared phrase to one source"}</summary><div className="mt-4 space-y-4">
      <TextField id="source-fact" label="Declared phrase alternatives — one per line" value={settings.factText || ""} placeholder="Refunds are available within 30 days" onChange={value => update("factText", value)} />
      <Field id="source-attribution" label="Source ID that must follow the phrase"><Input id="source-attribution" value={settings.factSourceId || ""} onChange={event => update("factSourceId", event.target.value)} /></Field>
      <Field id="source-distance" label="Trailing citation window (characters, 1–500)"><Input id="source-distance" inputMode="numeric" value={settings.distance || ""} onChange={event => update("distance", event.target.value)} /></Field>
      <p className="text-xs leading-5 text-muted-foreground">This is required in every answer if configured. The complete phrase must fit in the window before its trailing citation, without a sentence break (. ! ? or newline). It does not verify that the source supports the claim. Leave both phrase and source empty to omit attribution.</p>
    </div></details>
    <Example title="Example: support policy">Allowed IDs: billing and refunds. A refund question expects only refunds. <code>Refunds are available within 30 days [refunds]</code> has the expected syntax. A citation alone does not establish truth.</Example>
  </div>
  return <div className="space-y-4">
    <TextField id="text-required" label="Required phrase alternatives in every answer (optional)" value={settings.requiredText || ""} placeholder={"Consult a professional\nSeek professional advice"} onChange={value => update("requiredText", value)} />
    <TextField id="text-prohibited" label="Prohibited phrase alternatives in any answer (optional)" value={settings.prohibitedText || ""} placeholder="guaranteed outcome" onChange={value => update("prohibitedText", value)} />
    <p className="text-xs leading-5 text-muted-foreground">Configure at least one list. Up to 8 alternatives per list, 120 bytes each. Required means any one alternative is enough—not all lines. Prohibited means any matching alternative fails. Blank lines are ignored; duplicate normalized alternatives are rejected.</p>
    <Example title="Example: bounded support answers">Shared disclosure: “Consult a professional.” For a question without evidence, the case-specific answer alternatives could be “cannot determine” and “insufficient information.” “I cannot guarantee an outcome” is not automatically equivalent to either a required phrase or a prohibited claim.</Example>
  </div>
}

type Values = Record<string, { value: string; tolerance: string }>
export function jsonValues(raw: string): Values | null {
  if (!raw) return {}
  try { const result: unknown = JSON.parse(raw); return result && typeof result === "object" && !Array.isArray(result) && Object.values(result).every(value => value && typeof value === "object" && Object.keys(value).sort().join(",") === "tolerance,value" && typeof value.value === "string" && typeof value.tolerance === "string") ? result as Values : null } catch { return null }
}
export function reconcileJsonValues(expected: string, before: JsonField[], after: JsonField[]): string {
  const values = jsonValues(expected)
  if (!values) return expected // Never discard malformed imported/older raw text silently.
  return JSON.stringify(Object.fromEntries(after.filter(field => before.some(old => old.key === field.key && old.type === field.type) && Object.hasOwn(values, field.key)).map(field => [field.key, values[field.key]])))
}
export function RecipeExpectationEditor({ recipe, settings, expected, index, onChange }: { recipe: Exclude<Recipe, "routing">; settings: RecipeSettings; expected: string; index: number; onChange: (value: string) => void }) {
  if (recipe === "json") {
    const values = jsonValues(expected)
    if (!values) return <TextField id={`case-expected-${index}`} label={`Unfinished saved field values for example ${index + 1} — repair JSON to restore the editor`} value={expected} onChange={onChange} />
    return <div className="space-y-4">{(settings.fields || []).map((field, fieldIndex) => {
      const numeric = ["number", "integer"].includes(field.type)
      const value = Object.hasOwn(values, field.key) ? values[field.key] : { value: "", tolerance: numeric ? "0" : "" }
      const update = (change: Partial<typeof value>) => onChange(JSON.stringify({ ...values, [field.key]: { ...value, ...change } }))
      const id = `case-${index}-field-${fieldIndex}`
      const label = `${field.key || `Field ${fieldIndex + 1}`} expected ${numeric ? "target" : "value"} for example ${index + 1}`
      return <div key={fieldIndex} className="grid gap-3 sm:grid-cols-2">{field.type === "boolean" ? <Choice id={id} label={label} value={value.value} options={["true", "false"]} onChange={value => update({ value })} /> : <Field id={id} label={label}><Input id={id} inputMode={numeric ? "decimal" : "text"} value={value.value} onChange={event => update({ value: event.target.value })} /></Field>}
        {field.type === "string" && <div className="self-end"><Button variant="ghost" size="sm" onClick={() => update({ value: "" })}>Use empty string for {field.key || "this field"}</Button>{Object.hasOwn(values, field.key) && values[field.key].value === "" && <p className="text-xs text-muted-foreground">Empty string explicitly selected.</p>}</div>}
        {numeric && <Field id={`${id}-tolerance`} label={`${field.key} tolerance for example ${index + 1}`}><Input id={`${id}-tolerance`} inputMode="decimal" value={value.tolerance} onChange={event => update({ tolerance: event.target.value })} /></Field>}
      </div>
    })}<p className="text-xs leading-5 text-muted-foreground">Numeric tolerance 0 means exact numeric equality (12 and 12.0 are equivalent). An integer field still requires an integer representation. Bounds are inclusive. Targets/tolerances: magnitude ≤1,000,000; strings: ≤120 bytes, compared exactly without normalization. Empty string is a valid string value once explicitly entered/saved.</p></div>
  }
  return <TextField id={`case-expected-${index}`} label={recipe === "sources" ? `Exact source IDs for example ${index + 1} — one per line` : `Literal answer alternatives for example ${index + 1} — one per line`} value={expected} onChange={onChange} hint={recipe === "sources" ? "Every listed ID is required; other IDs fail this case. Include any shared required or attributed ID. This checks the set, not the factual answer." : "At least one listed alternative must appear for this input. Choose from independent requirements, not from a failed model answer. No paraphrase or negation inference."} />
}
function Example({ title, children }: { title: string; children: ReactNode }) { return <aside className="rounded-lg bg-muted/40 p-4 text-sm leading-6"><p className="font-medium">{title}</p><p className="text-muted-foreground">{children}</p></aside> }
function Field({ id, label, children }: { id: string; label: string; children: ReactNode }) { return <div className="space-y-2"><Label htmlFor={id}>{label}</Label>{children}</div> }
function TextField({ id, label, value, onChange, hint, placeholder }: { id: string; label: string; value: string; onChange: (value: string) => void; hint?: string; placeholder?: string }) { return <Field id={id} label={label}><Textarea id={id} value={value} placeholder={placeholder} onChange={event => onChange(event.target.value)} />{hint && <p className="text-xs leading-5 text-muted-foreground">{hint}</p>}</Field> }
function Choice({ id, label, value, options, onChange }: { id: string; label: string; value: string; options: string[]; onChange: (value: string) => void }) { return <Field id={id} label={label}><Select value={value} onValueChange={onChange}><SelectTrigger id={id} className="w-full"><SelectValue placeholder="Choose…" /></SelectTrigger><SelectContent>{options.map(value => <SelectItem key={value} value={value}>{value}</SelectItem>)}</SelectContent></Select></Field> }
