import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react"
import { useUnsavedChanges } from "@/hooks/use-unsaved-changes"

const DraftEditorsContext = createContext({
  dirty: false,
  rulesDirty: false,
  proofDirty: false,
  invalidRules: false,
  report: (_id: string, _dirty: boolean) => {},
})

export function DraftEditorsProvider({ children }: { children: ReactNode }) {
  const [editors, setEditors] = useState<Record<string, boolean>>({})
  const report = useCallback((id: string, dirty: boolean) => {
    setEditors(current => current[id] === dirty ? current : { ...current, [id]: dirty })
  }, [])
  const state = useMemo(() => {
    const keys = Object.keys(editors).filter(key => editors[key])
    return {
      dirty: keys.length > 0,
      rulesDirty: keys.some(key => key.startsWith("rules")),
      proofDirty: keys.some(key => !key.startsWith("rules")),
      invalidRules: keys.some(key => key.startsWith("rules-invalid:")),
      report,
    }
  }, [editors, report])
  useUnsavedChanges(state.dirty)
  return <DraftEditorsContext.Provider value={state}>{children}</DraftEditorsContext.Provider>
}

export function useDraftEditors() {
  return useContext(DraftEditorsContext)
}

export function useDraftEditor(id: string, dirty: boolean) {
  const { report } = useDraftEditors()
  useEffect(() => { report(id, dirty) }, [id, dirty, report])
  useEffect(() => () => report(id, false), [id, report])
}
