# Facilitator-only protocol and rubric

Protocol v1. Do not send this file, the product walkthrough or the implementation explanation before
the first attempt. Give the participant only [card A](TASK_CARDS.md). This is observation, not training.

## Before the session

1. Rehearse the sandbox once; pin build commit/protocol. Use a fresh pseudonymous participant account.
2. Confirm no prior product use, build involvement or detailed walkthrough. Record relevant LLM/API
   experience, usual input method and requested accommodations without identifying employer details.
3. Explain who sees the research and agree a retention/deletion date for notes and optional recordings.
   Ask separately for participation/note consent and recording consent. Default to notes only; no
   automatic recording. A suggested raw-material retention is 30 days, to be agreed before collecting.
   Keep raw notes/consent/recordings in private research storage, not Git. Explain how to withdraw.
4. Read the task-card prebrief. State that the connection is preconfigured and all provider responses
   are fake. Do not explain recipes, checks, proof, baseline, button order or what “Finish” means.
5. Sign in before timing. Start at the empty Monitors page. Verify the participant operates the UI.

## Main task: 15 active-minute observation window

Start the timer after the participant has read card A and says they are ready, before their first click.
Let them work, including mistakes. Pause active time only for measurable system waits, interruptions,
facilitator-only setup, and post-task questions. Thinking, reading UI, typing and recovering count as
active interaction. Separately record task-card reading time and any inline comprehension probes.

Use “Please keep thinking aloud” when necessary. If asked “What do I click?”, first ask “What would
you try if I weren't here?” Do not confirm the correct choice through praise, hints or screen pointing.
When safety/spend confusion is apparent, stop and clarify immediately; mark the attempt assisted.
The fake environment is safe, but we still need to learn whether real authorization is understood.

At a prolonged stall (roughly 60 seconds with no progress), ask what is unclear. If they request help,
offer it and record the exact words/time. At 15 active minutes, offer to stop or proceed with assistance.
Never erase the original unsuccessful attempt when the assisted continuation later finishes.

### Assistance codes

| Code | Meaning | Counts as unaided? |
| --- | --- | --- |
| H0 | Task read verbatim, neutral think-aloud reminder or question without UI/answer hints | Yes; note probes separately |
| H1 | Reworded product concept, pointed to a section, suggested where to look | No |
| H2 | Named a control, supplied a value beyond the card, explained the correct judgment | No |
| H3 | Facilitator took over or pre-completed part of the measured flow | No |

Participant-discovered in-product help counts as product use. An external guide/helpful chatbot
changes the condition: record assisted completion. Record requests for help even if no answer was given.
Correct data supplied in the card is not assistance; translating it into a particular control is.

### Stop the main clock

At the first explicit claim of completion, ask “Show me what tells you that.” If not actually finished,
resume timing while they continue. Record separate moments for result first visible, result examined,
and setup finished with scheduling off. After they finish or stop, ask the rubric questions below
without teaching the answers. Do not retroactively include post-task explanations in unaided understanding.

## Comprehension rubric (record their words first)

Score each `understood`, `partial`, `not understood`, or `not observed`; do not infer understanding
from clicking the confirmation box. Probe generically once (“What makes you say that?”), then score.

| Question | Required evidence / answer key |
| --- | --- |
| What does the result for the deny input mean? | `rejected` is the correct business answer; it passes the declared check, not a quality failure. |
| If the allow input returned rejected, what would you expect? | Allowed label/shared validity can pass while the input-specific expectation fails; it is a wrong route. |
| Where did the earlier test outputs come from? | Synthetic check examples, not previous live provider evidence; confirming them does not prove the provider will behave. |
| Which action would contact a real provider outside this sandbox, and what is the most it authorizes? | Points to capture authorization, reads the displayed planned/maximum calls and retry allowance; metadata/access verification is separate; not a dollar quote or unlimited consent. |
| What is ready now; what will happen if you leave? | Reviewed reference and on-demand operation; no recurring calls until explicitly scheduled. On-demand is not synonymous with free/simulated. |

For the supplied two-case flow the expected completion envelope is 2 planned, up to 4 including
one retry per input. Verify against the displayed preview; if the build differs, update the protocol
before the study rather than scoring against a stale number. The seeded model proof means no additional
metadata call is needed in the main task. Approval of checks/reference is distinct from execution consent.

Main **learning-threshold success** requires: correct two-case configuration, no H1–H3/external help,
reviewed result plus normal Finish, scheduling off, ≤10 active minutes, and all five rubric items
understood. Also report raw task completion without the comprehension/time composite. Do not hide which
part failed. Fewer than five eligible observations means insufficient evidence, not a zero or 100% rate.

## Follow-up tasks (outside the main completion clock)

Give card B. Observe incomplete save/exit → refresh → resume in the real persisted draft. Ask what
survived; the answer is explicitly saved text, not a promise of background autosave or recovery of
every unsaved keystroke. Leave this second monitor unrun. Record assistance and recovery time.

For card C, after the main score is locked, the facilitator may prepare a **separate** monitor while
the participant pauses. These are deliberately assisted fixture setups, never added to the unaided
numerator. Use the supplied routing policy and existing walkthrough to prepare an example:

- Wrong output: create a fictional OpenAI credential named `FAKE wrong-route fixture`, secret
  `sk-usability-wrong-route`, and validate it in this sandbox. Use it in the separate routing monitor.
  Review the correct synthetic proof and authorize its fake capture. Both actual outputs are rejected:
  deny passes; allow shared-pass/case-fail. Give the participant the result page without naming the cause.
- Execution failure (optional): repeat separately with `FAKE provider-failure fixture`, secret
  `sk-usability-failure`. Validation succeeds; fake completions fail with no quality judgment.
- Wrong expectation: after identifying a mismatch, ask “Suppose the documented policy really changed;
  where would you correct the setup?” Observe discovery of a corrected draft, copied values, cleared
  proof and preserved old result. Do not actually weaken the policy in card A to excuse a bad output.

The fixed fake cannot be “repaired” by editing prompt prose. Stop at discovery of the appropriate
recovery path; do not pretend a prompt change fixed a model. A corrected draft creates a separate
monitor; it is not an in-place rewrite or cancellation of old capture history. Reject/prepare retry
does not itself call the provider; another authorization is required. Correct expectations should
not be changed to match a wrong answer. A provider failure has no valid output to approve.

If a facilitator-prepared fixture cannot be obtained reliably, mark that task `not observed` and
fix the harness first; do not replace it with the historical preview and silently pool results.

Give one of cards D/E/F matching the participant's domain. Observe mapping of requirements into the
editor and understanding of proof, not another claimed first-time activation. No capture is required.
Rotate recipes across participants; do not let them read answers before declaring their understanding.

- JSON: shape/type does not prove value; wrong numeric target can be shared-pass/case-fail; extra keys
  are allowed and only the declared top-level scalar fields are checked.
- Sources: IDs and configured literal placement are checked, not truth, entailment or retrieval.
- Text: normalized literal alternatives are checked, not every paraphrase, negation or semantic answer.

## Debrief and synthesis

Ask “Where did you first lose confidence?”, “Which decision was hardest?”, “What would you expect
to happen next?”, and “What part of your own workflow would not fit?” Avoid “Was that easy?” or selling
the redesign. Read back ambiguous observations without putting the desired answer in their mouth.

After each session, separate observed action/quote, interpretation, proposed fix and severity. Link
each finding to pseudonym/task/build and a timestamp. Count affected people, not repeated clicks.
Prioritize: S0 safety/spend/history misunderstanding; S1 cannot finish or recover; S2 significant
friction; S3 wording/polish. S0/S1 must be resolved/retested or explicitly keep self-guided onboarding
closed. Record a fix's commit and retest evidence; automated regression tests complement, not replace,
human retests. Do not redesign on hypothetical observations or claim participants who have not attended.
