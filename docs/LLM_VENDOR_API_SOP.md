# LLM vendor API SOP (Cloudflare Workers AI + NVIDIA NIM)

**Permanent (owner 2026-09-11).** Recurring failure: agents wing Workers AI / NIM calls, then blame the vendor. Millions of callers use these APIs successfully — treat empty/`null`/hang/404 as **our call shape or account entitlement** until disproven.

## Before ANY inference call

1. **Read this SOP** and the project notes if present (`clients/translations/docs/LLM_API_SETUP.md` for Fathers bake).
2. **Read the live model card / infer schema** for that exact model ID (not a sibling SKU).
   - CF: model page + `GET /accounts/{id}/ai/models/schema?model=@cf/...`
   - NVIDIA: `https://docs.api.nvidia.com/nim/reference/<model>-infer` + smoke
3. **Write a research receipt** via the gate (below) naming model, sources, and the exact kwargs you will send.
4. **Smoke** `{"ok":true}` with a hard client timeout **before** any fixture/bake/batch.
5. Prefer the **profiled harness** `clients/translations/scripts/llm_bakeoff.py` (or extend it) over one-off curl/python.

Do **not** invent `temperature: 0`, skip thinking flags, or assume Llama-shaped responses.

## Mechanical gate

Shell PreToolUse (`sane_llm_api_guard.rb` via `sane_bash_guards.rb`) **blocks** posts to:

- `integrate.api.nvidia.com` chat/completions
- `api.cloudflare.com/.../ai/run/...`
- `api.cloudflare.com/.../ai/v1/chat/completions` and `.../ai/v1/responses`

**Allowed without owner override:**

| Path | Why |
|------|-----|
| `scripts/llm_bakeoff.py` | Profiles already encode researched kwargs |
| `scripts/llm_api_research_gate.rb` | Creates the research receipt (schema/docs fetch) |
| Read-only schema/docs GETs | Research only — no chat body |
| Command includes a fresh receipt (`SANE_LLM_API_RECEIPT=…` or `--llm-api-receipt …`) | Proves research landed |
| `SANE_LLM_API_RESEARCH_OK='MR. SANE APPROVES LLM VENDOR API CALL'` | Explicit owner override in that command |

Receipt TTL: **4 hours**. Receipt must list every model ID the command will call.

## Known call-shape facts (do not rediscover the hard way)

| Vendor / model | Required | Common false failure |
|----------------|----------|----------------------|
| CF Gemma / GLM | `chat_template_kwargs.enable_thinking: false` (schema default **true**) | Thinking prose / `null` / “empty” |
| CF gpt-oss | Schema default `max_tokens: 256`, `temperature: 0.6`; do not invent thinking kwargs | Truncation / parse miss |
| NV Nemotron Super | `reasoning_effort: "none"`, temp 1.0, top_p 0.95, client timeout ≥180s | Hang / empty with thinking on |
| NV DeepSeek V4 Flash | **`stream: true`** + `reasoning_effort: "none"` | Non-stream hangs; extra `enable_thinking: false` can hang |
| Catalog 404 Function not found | Account “Public API Endpoints” entitlement | Treated as “API broken” when model not enabled |

## Failure policy

1. Prefer “our request is wrong” over “Cloudflare/NVIDIA is down.”
2. After one bad response, dump **full** JSON (or first SSE events) before changing models.
3. Search vendor docs + forums/GitHub for the **exact** error/`null` shape.
4. Only after a docs-correct smoke still fails with the same shape may you report a vendor/account outage — cite the smoke receipt.

## Canonical files

- This SOP: `infra/SaneProcess/docs/LLM_VENDOR_API_SOP.md`
- Gate: `infra/SaneProcess/scripts/llm_api_research_gate.rb`
- Guard: `infra/SaneProcess/scripts/hooks/sane_llm_api_guard.rb`
- Fathers bake harness: `clients/translations/scripts/llm_bakeoff.py`
- Fathers bake notes: `clients/translations/docs/LLM_API_SETUP.md`
