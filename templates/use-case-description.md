# Use Case: [Use Case Name]

**Use Case ID:** `UC-[PROJECT]-[NUMBER]` (e.g., `UC-ADMIRAL-001`)
**Version:** 1.0.0
**Created:** YYYY-MM-DD
**Last Updated:** YYYY-MM-DD
**Status:** Draft | Review | Approved | Implemented

---

## Template Purpose
The goal of this template is to provide high-level requirements, not
implementation details. No code examples should be included in this document; it
defines the acceptance criteria, constraints, and product-level requirements
that feed into the detailed implementation spec.

## Overview

### Business Goal
Brief description of what this use case accomplishes from a business perspective. This should be 2-3 sentences describing the user need or business value that this use case fulfills.

**Example:**
```
Enable users to execute AI integration steps with runtime context, allowing them to dynamically generate content based on pre-configured prompts and real-time data. This supports flexible workflow automation where users can define reusable AI operations and invoke them with different inputs.
```

---

## Open Questions

Track unresolved questions that need answers:

- [ ] [Question text]
  - **Impact:** [What's blocked or affected]
  - **Owner:** [Who should answer]
  - **Target Date:** [When answer needed]
  - **Options:** [Possible solutions being considered]

**Example:**
```
Open Questions:
- [ ] Should execution history be stored permanently or just logged?
  - Impact: Determines if we need ExecutionHistory aggregate
  - Owner: Product team
  - Target Date: Before implementation
  - Options:
    1. Store in database (enables execution history UI)
    2. Log only (simpler, cheaper)
    3. Store for 30 days then archive (balanced approach)

- [ ] What happens when user exceeds LLM rate limit?
  - Impact: Error handling and user experience
  - Owner: Product + Engineering
  - Target Date: Before implementation
  - Options:
    1. Return error immediately
    2. Queue for retry
    3. Switch to alternative provider automatically
```

---

## Acceptance Criteria

Concrete, testable requirements that define "done":

### Functional Requirements
- [ ] [Specific functional behavior]
- [ ] [Expected output or state change]
- [ ] [User-visible feature]

**Example:**
```
Functional Requirements:
- User can execute integration step with custom context text
- System combines pre-context + user context + post-context into prompt
- LLM generates response based on composed prompt
- User receives generated text in UI
- Execution works with 0, 1, or 2 prompts configured
- Generated text response is non-empty string
- Operation completes within timeout period
```

### Authorization Requirements
- [ ] [Each role's access verified]
- [ ] [Permission checks enforced]
- [ ] [Unauthorized access blocked]

**Example:**
```
Authorization Requirements:
- Owner can execute integration step
- Editor can execute integration step
- Viewer cannot execute (gets :not_found)
- User with no role cannot execute (gets :not_found)
- Soft-deleted steps return :not_found to all users
```

### Error Handling Requirements
- [ ] [Each error condition handled gracefully]
- [ ] [User-friendly error messages]
- [ ] [No system crashes or undefined states]

**Example:**
```
Error Handling Requirements:
- LLM API timeout returns clear error message
- Missing prompt version returns configuration error
- Unauthorized access returns :not_found (not :unauthorized)
- All errors include user recovery instructions
- External service failures handled gracefully with retry options
```

### Data Quality Requirements
- [ ] [Data validation rules enforced]
- [ ] [Data integrity maintained]
- [ ] [No data corruption scenarios]

**Example:**
```
Data Quality Requirements:
- Integration step configuration validated before execution
- Prompt content properly encoded (UTF-8)
- Special characters handled correctly (quotes, newlines)
- Very large contexts (>1MB) handled gracefully
```

---

## Aggregate

**Aggregate:** `[AppName].[Context].[Aggregate]` (e.g., `Admiral.Workflows.IntegrationStep`)

An aggregate is a set of one or more entities that are updated in the same transaction. This defines the transactional boundary for the use case.

**Entities in this Aggregate:**
- **Primary Entity:** [EntityName] - [Purpose]
- **Related Entities:** [EntityName] - [Relationship and role]

**Example:**
```
Aggregate: Admiral.Workflows.IntegrationStep

Entities in this Aggregate:
- Primary Entity: IntegrationStep - The step being executed
- Related Entities:
  - Prompt (pre_context_prompt) - Optional system instruction
  - Prompt (post_context_prompt) - Optional output formatting
  - PromptVersion - Current version of each prompt

Note: This is a read-only operation. While the aggregate includes multiple entities,
no database writes occur during execution. The transactional boundary ensures
consistent reads of the step configuration and related prompts.
```

---

## Trigger

**Trigger Type:** API Call | Cron Job | Event | Background Job | WebSocket

**When Triggered:**
- **User Action:** [Description of user-initiated action]
- **System Event:** [Description of automated trigger]
- **Schedule:** [Cron expression if scheduled]
- **External Event:** [Third-party webhook or event]

**Example:**
```
Trigger Type: API Call

When Triggered:
- User clicks "Execute" button on integration step in workflow builder
- API receives POST request to /api/workflows/integration-steps/:id/trigger
- User provides runtime context string to customize AI generation
```

---

## Actors

**Primary Actor:** [User Role/System Component] - The entity that initiates the use case

**Secondary Actors:** (if applicable)
- [Other stakeholders, users, or systems affected by this operation]

**Example:**
```
Primary Actor: Workflow Owner - User who created and owns the workflow

Secondary Actors:
- Integration Step Owner - May be different from workflow owner if delegated
- LLM Provider - External AI service that processes the request
- Audit System - Logs execution for compliance
```

---

## Preconditions

State that must be true before this use case can execute:

- [ ] **Authentication:** [Authentication requirements]
- [ ] **Authorization:** [Permission requirements]
- [ ] **Data Requirements:** [Required entities or relationships]
- [ ] **System State:** [Required system configuration or conditions]
- [ ] **Business Rules:** [Domain-specific prerequisites]

**Example:**
```
- User must be authenticated with valid session
- User must have :trigger permission on the Integration Step (or inherited via workflow)
- Integration Step must exist and not be deleted
- At least one of pre_context_prompt or post_context_prompt must be configured
- If prompts are configured, they must have a current version
- LLM provider API credentials must be configured in system settings
```

### Entity State Requirements

**Primary Entity:**
- Must exist in database
- Must NOT be soft-deleted (unless explicitly handling deleted entities)
- [Any state-specific conditions]

**Related Entities:**
- [Entity Name]: [Required state or relationship]

**Example:**
```
Primary Entity (Integration Step):
- Must exist and not be soft-deleted
- Must have valid provider and model specified

Related Entities:
- Pre-context Prompt (optional): If present, must have current_version
- Post-context Prompt (optional): If present, must have current_version
- Workflow (parent): Must exist and not be soft-deleted for permission delegation
```

---

## Authorization Requirements

### Required Permissions

**Permission:** `:[permission_name]` on `[ResourceType]`

The use case requires checking authorization using the GenSaas RBAC pattern:

```elixir
GenSaas.Auth.RBAC.Roles.can?(repo, user, :permission_name, entity)
```

**Example:**
```
Permission: :trigger on IntegrationStep

Authorization Check:
GenSaas.Auth.RBAC.Roles.can?(repo, user, :trigger, integration_step)
```

### Roles with Required Permission

Document which roles have the required permission to execute this operation:

**Roles:**
- **`:role_name`** - [How this role obtains the permission]

**Example:**
```
Roles:
- :owner - User who created the integration step (default role on creation)
- :editor - User granted edit access by owner or admin
- :admin - Workspace administrator (has all permissions)

Note: Permission can be granted either:
1. Directly on the IntegrationStep entity
2. Inherited from parent Workflow (via permission delegation)
```

### Permission Inheritance

If this aggregate uses permission delegation from parent entities:

**Delegation Chain:**
```
[Parent] → [This Aggregate] → [Child]
```

**Inheritance Rules:**
- [Describe how permissions flow through hierarchy]

**Example:**
```
Delegation Chain:
Workflow → IntegrationStep

Inheritance Rules:
- Users with :trigger permission on Workflow automatically have :trigger on all child IntegrationSteps
- Direct role assignment on IntegrationStep also grants permission
- Either inheritance OR direct assignment is sufficient
```

### Security Requirements

**Information Leakage Prevention:**
- Return `{:error, :not_found}` for BOTH missing entities and unauthorized access
- Never distinguish between "doesn't exist" and "no permission"
- Never reveal entity IDs or existence to unauthorized users

**Example:**
```
Security Requirements:
- Unauthorized user gets same :not_found error as non-existent entity
- Soft-deleted entities return :not_found (treated as non-existent)
- Error messages never reveal whether entity exists
```

---

## Main Flow

Describe the normal, successful execution path from the user's perspective:

### User Interaction
1. [First user action or system event]
2. [System response or state change]
3. [Next user action or system processing]
4. [Final outcome visible to user]

**Example:**
```
User Interaction:
1. User navigates to workflow and selects integration step
2. User enters runtime context text in input field
3. User clicks "Execute" button
4. System shows loading indicator
5. LLM processes request with pre-context + user context + post-context
6. System displays generated response text
7. User can copy, edit, or re-execute with different context
```

### Data Requirements

**Input Data:**

| Field Name    | Type     | Required | Constraints           | Description                    |
|---------------|----------|----------|-----------------------|--------------------------------|
| param_name    | type     | Yes/No   | [Validation rules]    | [Business purpose]             |

**Example:**

| Field Name    | Type     | Required | Constraints           | Description                    |
|---------------|----------|----------|-----------------------|--------------------------------|
| user          | User     | Yes      | Must be authenticated | User executing the step        |
| id            | UUID     | Yes      | Valid UUID format     | Integration step identifier    |
| context       | String   | Yes      | No length limit       | Runtime context for AI         |

**Output Data:**

Describe what the successful operation returns:

**Example:**
```
Output Data:
- Generated text string from LLM
- No persistent state changes (read-only operation)
- Response typically 100-5000 characters depending on model
```

### Business Logic Steps

High-level business operations (no implementation details):

1. [Verify user authorization]
2. [Validate business rules]
3. [Perform core business operation]
4. [Update state or trigger side effects]
5. [Return result to user]

**Example:**
```
Business Logic Steps:
1. Verify user has permission to trigger this integration step
2. Retrieve integration step configuration (prompts, model, provider)
3. Compose three-part prompt: pre-context + runtime context + post-context
4. Send composed prompt to configured LLM provider
5. Receive and return generated text
6. No database changes (read-only operation)
```

---

## Alternative Flows

### Alternative Flow 1: [Scenario Name]
**Trigger:** [What causes this alternative path]

**User Experience:**
1. [How flow differs from main path]
2. [Alternative steps or outcomes]

**Success Criteria:**
- [What defines success for this alternative]

**Example:**
```
Alternative Flow: No Prompts Configured

Trigger: Both pre_context_prompt and post_context_prompt are unset (NULL)

User Experience:
1. User provides runtime context as normal
2. System sends only the user's context to LLM (no system prompts)
3. LLM responds based solely on user input
4. User receives response as normal

Success Criteria:
- Operation succeeds with empty prompt sections
- User gets valid LLM response
- System doesn't fail validation
```

---

## Error Conditions

### Error Categories

For each error condition, specify:
- **User-Facing Message:** What the user sees
- **Trigger Condition:** What causes this error
- **User Recovery:** How user can fix or work around

#### Authorization Failures
**User-Facing Message:** "Integration step not found or access denied"

**Trigger Conditions:**
- User lacks required permission
- Entity doesn't exist
- Entity is soft-deleted

**User Recovery:**
- Request access from owner
- Verify entity ID is correct
- Contact administrator

**Example:**
```
Authorization Failure Examples:
- User is viewer (read-only): "You don't have permission to execute this step"
- Integration step deleted: "Integration step not found"
- Wrong ID provided: "Integration step not found"
(All return same message to prevent information leakage)
```

#### Validation Failures
**User-Facing Message:** [Specific validation error messages]

**Trigger Conditions:**
- [Invalid input conditions]

**User Recovery:**
- [How to correct input]

**Example:**
```
Validation Failures:
- Context too large (>1MB): "Context input too large. Maximum 1MB."
  Recovery: Reduce context size or split into multiple executions

- Invalid characters in context: "Context contains invalid characters"
  Recovery: Remove or escape problematic characters
```

#### Data Integrity Issues
**User-Facing Message:** [Error message shown to user]

**Trigger Conditions:**
- [What data state causes this]

**User Recovery:**
- [How user or admin fixes data]

**Example:**
```
Data Integrity Issues:
- Prompt missing current version: "Integration step configuration is incomplete. Please reconfigure prompts."
  Trigger: Prompt exists but current_version_id is NULL (data corruption)
  Recovery: Admin must fix data or user must reconfigure step

- LLM provider credentials missing: "LLM provider not configured. Contact administrator."
  Trigger: No API key configured for selected provider
  Recovery: Administrator must add API credentials in settings
```

#### External Service Failures
**User-Facing Message:** [Error message for service failures]

**Trigger Conditions:**
- [When external services fail]

**User Recovery:**
- [What user should do]

**Retry Strategy:**
- Retry: Yes/No
- User-initiated retry: Yes/No

**Example:**
```
External Service Failures:
- LLM API timeout: "Request timed out. Please try again."
  Trigger: LLM API doesn't respond within 30 seconds
  Recovery: User clicks "Execute" again
  Retry: Yes, automatic retry 3 times, then user must retry manually

- LLM API rate limit: "Too many requests. Please wait and try again."
  Trigger: Exceeded LLM provider rate limits
  Recovery: Wait 60 seconds and retry
  Retry: No automatic retry (would exceed limits)

- Network error: "Unable to connect to AI service. Check your connection."
  Trigger: Network connectivity issue
  Recovery: Check internet connection, retry when restored
  Retry: No automatic retry
```

#### Business Rule Violations
**User-Facing Message:** [Error for business rule violations]

**Trigger Conditions:**
- [What business rules can be violated]

**User Recovery:**
- [How to satisfy business rules]

**Example:**
```
Business Rule Violations:
- Insufficient credits: "Insufficient credits to execute. Purchase more credits."
  Trigger: User's credit balance < estimated cost
  Recovery: Purchase additional credits or upgrade plan

- Workflow archived: "This workflow is archived and cannot be executed."
  Trigger: Parent workflow is in archived state
  Recovery: Unarchive workflow or create new active workflow
```

---

## Side Effects

### Internal Effects

Document changes within the system:

**State Changes:**
- [What application state changes]
- [What database records are created/updated/deleted]

**Events Published:**
- [Domain events emitted]
- [Who consumes these events]

**Example:**
```
Internal Effects:
- No persistent state changes (read-only operation)
- Cache hit/miss may occur for prompt content

Events Published:
- IntegrationStepExecuted event published to event bus
  - Consumers: Analytics, Audit Log, Webhook Dispatcher
  - Payload: {step_id, user_id, execution_time, success/failure}
```

### External Effects

Document changes outside the system:

**External API Calls:**
- [Which external services are called]
- [What operations are performed]
- [Costs or rate limits]

**Notifications:**
- [Who gets notified]
- [When notifications are sent]

**Third-Party Systems:**
- [What external systems are affected]

**Example:**
```
External Effects:
- LLM Provider API call (Anthropic Claude or OpenAI GPT)
  - One API request per execution
  - Cost: ~$0.01-0.50 depending on model and context size
  - Rate limits apply (varies by provider)

- Webhook triggered (if configured):
  - POST to user-configured URL
  - Payload: {event: "integration_step.executed", result: "..."}
  - Sent asynchronously after successful execution

- Analytics event logged:
  - Provider: Segment/Mixpanel
  - Event: "ai_integration_executed"
  - Used for usage tracking and billing
```

### Idempotency

**Is this operation idempotent?** Yes / No

**If No:**
- What prevents idempotency?
- What are the risks of duplicate operations?
- How are duplicates prevented?

**If Yes:**
- What makes it idempotent?
- Can it be safely retried?

**Example:**
```
Idempotent: No

Reasons:
- Each execution calls external LLM API (costs money)
- LLM responses are non-deterministic (different output each time)
- No idempotency key mechanism

Risks:
- Double-click triggers twice and charges twice
- Network retry causes duplicate execution
- Accidental re-execution wastes credits

Prevention:
- UI disables execute button after click
- Display confirmation before execution
- Show cost estimate before execution
- No server-side deduplication (each request treated as new)
```

---

## Data Requirements

### Primary Data

**Entity:** [Main entity name]

**Fields Needed:**
- [Field name]: [Purpose for this use case]

**Example:**
```
Entity: IntegrationStep

Fields Needed:
- id: Identify which step to execute
- provider: Determine which LLM API to call (anthropic, openai)
- model: Specify which model to use (claude-3-5-sonnet, gpt-4)
- pre_context_prompt_id: Reference to system prompt (if configured)
- post_context_prompt_id: Reference to formatting prompt (if configured)
```

### Related Data

**Entity:** [Related entity name]
**Relationship:** [How it relates to primary entity]
**Data Needed:** [What fields are required]

**Example:**
```
Entity: Prompt
Relationship: Integration step references 0-2 prompts (pre and post context)
Data Needed:
- id: Link from integration step
- current_version_id: Points to active version

Entity: PromptVersion
Relationship: Prompt has current version
Data Needed:
- content: Actual prompt text to send to LLM
```

---

## Data Loading Strategy

**Required Associations:**
- [Association name]: [Why it's needed]

**Optional Associations:**
- [Association name]: [When it's needed]

**Example:**
```
Required Associations:
- pre_context_prompt: Needed if configured (to get prompt content)
- post_context_prompt: Needed if configured (to get prompt content)
- pre_context_prompt.current_version: Get actual prompt text
- post_context_prompt.current_version: Get actual prompt text

Optional Associations:
- workflow: Only needed for permission delegation check
- execution_history: Not needed for execution, only for audit views
```

---

## Test Scenarios

### Happy Path Tests
- [ ] [Test case 1: Normal operation]
- [ ] [Test case 2: Alternative valid path]

**Example:**
```
Happy Path Tests:
- Execute with both pre and post prompts configured
- Execute with only pre-context prompt
- Execute with only post-context prompt
- Execute with no prompts (context-only)
- Execute with empty context string
- Execute with large context (100KB+)
```

### Authorization Test Matrix

Test all role combinations with explicit assertions:

| Role          | Operation | Expected Result | Assertions                                    |
|---------------|-----------|-----------------|-----------------------------------------------|
| :role_name    | operation | Success/:not_found | - [Assertion 1]<br>- [Assertion 2]         |

**Example:**

| Role          | Operation | Expected Result | Assertions                                           |
|---------------|-----------|-----------------|------------------------------------------------------|
| :owner        | execute   | Success         | - Returns `{:ok, response}`<br>- Response is non-empty string<br>- No errors raised |
| :editor       | execute   | Success         | - Returns `{:ok, response}`<br>- Response is non-empty string<br>- No errors raised |
| :viewer       | execute   | :not_found      | - Returns `{:error, :not_found}`<br>- No response data returned<br>- No information leakage |
| (no role)     | execute   | :not_found      | - Returns `{:error, :not_found}`<br>- No response data returned<br>- No information leakage |

### Edge Case Tests
- [ ] [Boundary condition 1]
- [ ] [Unusual but valid scenario]

**Example:**
```
Edge Case Tests:
- Very large context (1MB+)
- Empty context string
- Unicode and emoji in context
- Special JSON characters (quotes, backslashes)
- Soft-deleted integration step
- Deleted parent workflow
- Missing prompt current_version (data corruption)
- Concurrent executions of same step
```

### Error Condition Tests
- [ ] [Error scenario 1]
- [ ] [Error scenario 2]

**Example:**
```
Error Condition Tests:
- Unauthorized user attempts execution → :not_found
- Non-existent integration step ID → :not_found
- LLM API timeout → timeout error message
- LLM API rate limit → rate limit error message
- Invalid API credentials → configuration error
- Network failure → network error message
```

### Integration Tests
- [ ] [End-to-end scenario 1]
- [ ] [Multi-step workflow test]

**Example:**
```
Integration Tests:
- Create integration step → Configure prompts → Execute → Verify response
- Execute step → Verify webhook triggered → Check audit log
- Execute step → Verify analytics event → Check billing record
```

---

## Dependencies

### External Dependencies

**Services:**
- [Service Name]: [What it provides, failure impact]

**Example:**
```
Services:
- Anthropic Claude API: LLM text generation
  - Failure Impact: Cannot execute integration steps with Anthropic provider
  - Fallback: Switch to alternative provider if configured

- OpenAI GPT API: Alternative LLM provider
  - Failure Impact: Cannot use OpenAI models
  - Fallback: Use Anthropic or other configured provider

- PostgreSQL: Data storage
  - Failure Impact: Cannot retrieve integration step configuration
  - Fallback: None (critical dependency)
```

### Configuration Requirements

**System Configuration:**

Document environment variables, application config, defaults, and requirements:

**Environment Variable Naming Pattern:**
- `[SERVICE]_[PURPOSE]` (e.g., `ANTHROPIC_API_KEY`, `LLM_TIMEOUT`)

**Application Config Mapping:**
- `Application.get_env(:app_name, :config_key, default_value)`

**Configuration Requirement Levels:**
- **Required:** Must be set, no default value
- **Optional:** Has default value, can be overridden

**Configuration Locations:**
- `config/runtime.exs` - Runtime environment variables
- `config/dev.exs` - Development overrides
- `config/prod.exs` - Production overrides
- `config/test.exs` - Test environment settings

**Example:**
```
System Configuration:

LLM Provider API Keys:
- Environment Variable: `ANTHROPIC_API_KEY`
- Application Config: `Application.get_env(:admiral, :anthropic_api_key)`
- Required: Yes (no default)
- Must be set in: config/runtime.exs or environment
- Purpose: Authenticate with Anthropic Claude API

- Environment Variable: `OPENAI_API_KEY`
- Application Config: `Application.get_env(:admiral, :openai_api_key)`
- Required: Yes (no default)
- Must be set in: config/runtime.exs or environment
- Purpose: Authenticate with OpenAI GPT API

Request Timeout:
- Environment Variable: `LLM_TIMEOUT` (optional)
- Application Config: `Application.get_env(:admiral, :llm_timeout, 30_000)`
- Default: 30000 (30 seconds)
- Can override in: config/dev.exs (increase for debugging), config/prod.exs
- Purpose: Maximum time to wait for LLM API response

Rate Limiting:
- Environment Variable: `LLM_MAX_REQUESTS_PER_MINUTE` (optional)
- Application Config: `Application.get_env(:admiral, :llm_max_requests_per_minute, 60)`
- Default: 60 requests per minute
- Can override in: config/prod.exs based on provider tier
- Purpose: Prevent exceeding provider rate limits
```

---

## Data Migration Requirements

**Data Migration:** Yes / No

**If Yes:**
- [What data needs migration]
- [Migration script location or strategy]
- [Rollback procedure]

**Example:**
```
Data Migration: Yes
- Rename prompt_id column to pre_context_prompt_id
- Migration script: [timestamp]_add_three_part_prompts.exs
- Rollback: Migration is reversible, run mix ecto.rollback

Migration Details:
- Existing prompt_id values copied to pre_context_prompt_id
- post_context_prompt_id added as nullable column
- No data loss on rollback
```

---

## Related Use Cases

*(Optional section - include only if there are directly related use cases)*

**Related Use Cases:**
- **UC-[ID]:** [Name] - [Relationship type: Prerequisite | Dependent | Composes | Alternative]

**Example:**
```
Related Use Cases:
- UC-ADMIRAL-001: Create Integration Step
  - Relationship: Prerequisite (must create before triggering)

- UC-ADMIRAL-002: Update Prompt Content
  - Relationship: Composes (configure prompts used by step)

- UC-ADMIRAL-003: List Integration Step Executions
  - Relationship: Dependent (views results of triggers)

- UC-ADMIRAL-004: Execute Workflow
  - Relationship: Composes (workflows execute multiple steps)
```

---

## Change History

| Version | Date       | Author        | Changes                                      |
|---------|------------|---------------|----------------------------------------------|
| 1.0.0   | YYYY-MM-DD | [Name]        | Initial use case creation                    |

**Example:**
```
| Version | Date       | Author        | Changes                                      |
|---------|------------|---------------|----------------------------------------------|
| 1.0.0   | 2025-01-15 | Athena        | Initial use case creation                    |
| 1.1.0   | 2025-01-20 | Athena        | Added edge case for missing prompt versions  |
| 2.0.0   | 2025-02-01 | Athena        | Breaking: Added required context parameter   |
```

---

## Appendix

<Put things here on an as-needed basis>

---

**END OF TEMPLATE**

## Template Usage Guide

### When to Use This Template

Use for:
- New features or user-facing operations
- Changes to business logic or workflows
- Operations that require authorization
- Any operation that modifies business state

Skip for:
- Pure implementation details (use implementation specs instead)
- Infrastructure setup (migrations, config)
- Private helper functions

### How to Fill Out

1. **Start with Overview:** Clearly define business goal and who benefits
2. **Address Open Questions:** Identify and track unresolved decisions early
3. **Define Acceptance Criteria:** Establish concrete, testable "done" conditions
4. **Specify Aggregate:** Define transactional boundary and included entities
5. **Define Preconditions:** What must be true before execution
6. **Specify Authorization:** Required permission and roles that have it
7. **Describe Main Flow:** User perspective, not implementation
8. **List Alternatives:** Valid variations from main flow
9. **Document Errors:** What can go wrong and user recovery
10. **Create Test Matrix:** Cover all roles × operations with assertions
11. **Document Configuration:** Environment variables and application config mapping

### Completeness Checklist

Before marking "Approved":

- [ ] Business goal clearly stated
- [ ] Open questions tracked with owners and dates
- [ ] Acceptance criteria are concrete and testable
- [ ] Aggregate defines transactional boundary correctly
- [ ] Required permission and roles documented
- [ ] Authorization uses GenSaas.Auth.RBAC.Roles.can?/4 pattern
- [ ] Error conditions include user recovery
- [ ] Test matrix includes explicit assertions
- [ ] Configuration requirements document env vars and defaults
- [ ] Test scenarios cover happy path and errors
- [ ] Dependencies identified (external only)
- [ ] Data migration requirements specified (if applicable)
