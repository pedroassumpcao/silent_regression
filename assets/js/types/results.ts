export type AlertCategory = "contract_failure" | "operational_anomaly"
export type AlertSeverity = "critical" | "warning"
export type AlertStatus = "open" | "acknowledged" | "resolved"

export type BoundedText = {
  text: string
  truncated: boolean
  originalBytes: number
}

export type ResultAlert = {
  id: string
  category: AlertCategory
  severity: AlertSeverity
  status: AlertStatus
  code: string
  title: string
  explanation: string
  evidence: unknown
  openedAt: string
  acknowledgedAt: string | null
  resolvedAt: string | null
  acknowledgedBy: string | null
  resolvedBy: string | null
  monitor: { id: string; name: string } | null
  run: {
    id: string
    kind: "baseline" | "manual" | "scheduled"
    status: string
    completedAt: string | null
  } | null
}

export type RunSummary = {
  id: string
  kind: "baseline" | "manual" | "scheduled"
  status: string
  provider: "openai" | "anthropic"
  requestedModel: string
  baselineSnapshotId: string | null
  provenanceCompatible: boolean
  provenanceMismatches: string[]
  plannedCallCount: number
  maximumCallCount: number
  actualCallCount: number
  observationCount: number
  observationCounts: Record<string, number>
  completionCounts: Record<string, number>
  evaluationCounts: Record<string, number>
  providerFailureCount: number
  modelMismatchCount: number
  inputTokens: number
  outputTokens: number
  latencyMs: number
  alertCounts: Record<string, number>
  criticalAlertCount: number
  warningAlertCount: number
  startedAt: string | null
  completedAt: string | null
  insertedAt: string
}

export type RuleResult = {
  id: string
  position: number
  ruleId: string
  ruleType: string
  severity: AlertSeverity
  status: "pass" | "fail" | "evaluator_error"
  code: string
  explanation: string
  evidence: unknown
  childRuleIds: string[]
}

export type Evaluation = {
  id: string
  status: "pass" | "fail" | "evaluator_error"
  rootRuleId: string
  contractFingerprint: string
  evaluatorEngineVersion: string
  evaluatedAt: string
  error: Record<string, unknown> | null
  ruleResults: RuleResult[]
}

export type Observation = {
  id: string
  sampleIndex: number
  status: string
  completionState: string | null
  requestedModel: string | null
  returnedModel: string | null
  finishReason: string | null
  inputTokens: number | null
  outputTokens: number | null
  latencyMs: number | null
  providerRequestId: string | null
  failureCategory: string | null
  failureMessage: BoundedText | null
  providerMetadata: Record<string, unknown>
  capturedAt: string | null
  terminalAt: string | null
  case: {
    id: string
    key: string
    name: string
    inputVariables: Record<string, unknown>
    context: BoundedText
    fingerprint: string
  }
  output: BoundedText | null
  attempts: Array<{
    id: string
    attemptNumber: number
    status: string
    providerRequestId: string | null
    retryable: boolean | null
    failureCategory: string | null
    failureMessage: BoundedText | null
    latencyMs: number | null
    startedAt: string
    finishedAt: string | null
  }>
  evaluations: Evaluation[]
}

export type RunDetail = {
  summary: RunSummary
  identityKey: string
  samplesPerCase: number
  retryLimit: number
  provenance: {
    compatible: boolean
    mismatches: string[]
    baseline: Provenance | null
    current: Provenance
  }
  configuration: {
    monitorVersion: number
    systemPrompt: BoundedText
    userPromptTemplate: BoundedText
    responseFormat: Record<string, unknown>
    generationConfig: Record<string, unknown>
  }
  alertPolicy: {
    latencyMultiplier: number
    latencyMinimumDeltaMs: number
    usageMultiplier: number
    usageMinimumDeltaTokens: number
  }
  alerts: ResultAlert[]
  observations: Observation[]
}

export type Provenance = {
  id: string
  status?: string
  approvalMode?: string
  approvedAt?: string
  provider: "openai" | "anthropic"
  requestedModel: string
  monitorVersionId: string
  contractVersionId: string
  providerCredentialId: string
  monitorFingerprint: string
  caseSetFingerprint: string
  contractFingerprint: string
  evaluatorEngineVersion: string
}

export type ResultMonitor = {
  id: string
  name: string
  description: string | null
  state: string
  cadence: string
  provider: "openai" | "anthropic" | null
  requestedModel: string | null
  version: number | null
}
