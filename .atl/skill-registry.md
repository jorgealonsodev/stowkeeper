# Skill Registry

**Delegator use only.** Any agent that launches sub-agents reads this registry to resolve compact rules, then injects them directly into sub-agent prompts. Sub-agents do NOT read this registry or individual SKILL.md files.

See `_shared/skill-resolver.md` for the full resolution protocol.

## User Skills

| Trigger | Skill | Path |
|---------|-------|------|
| When building AI chat features - breaking changes from v4. | ai-sdk-5 | /home/jorge/.config/opencode/skills/ai-sdk-5/SKILL.md |
| When writing Angular components, services, templates, or making architectural decisions about component placement. | scope-rule-architect-angular | /home/jorge/.config/opencode/skills/angular/SKILL.md |
| When creating a pull request, opening a PR, or preparing changes for review. | branch-pr | /home/jorge/.config/opencode/skills/branch-pr/SKILL.md |
| When implementing CDP-based network capture, debugging, or tracing in a Chrome Extension. | cdp-chrome-debugger | /home/jorge/.config/opencode/skills/cdp-chrome-debugger/SKILL.md |
| When building Chrome/Edge extensions, writing manifest.json V3, service workers, content scripts, DevTools panels, or using chrome.* APIs. | chrome-extension-mv3 | /home/jorge/.config/opencode/skills/chrome-extension-mv3/SKILL.md |
| When building REST APIs with Django - ViewSets, Serializers, Filters. | django-drf | /home/jorge/.config/opencode/skills/django-drf/SKILL.md |
| When writing C# code, .NET APIs, or Entity Framework models. | dotnet | /home/jorge/.config/opencode/skills/dotnet/SKILL.md |
| When writing Go tests, using teatest, or adding test coverage. | go-testing | /home/jorge/.config/opencode/skills/go-testing/SKILL.md |
| When user asks to release, bump version, update homebrew, or publish a new version. | homebrew-release | /home/jorge/.config/opencode/skills/homebrew-release/SKILL.md |
| When creating a GitHub issue, reporting a bug, or requesting a feature. | issue-creation | /home/jorge/.config/opencode/skills/issue-creation/SKILL.md |
| When user asks to create an epic, large feature, or multi-task initiative. | jira-epic | /home/jorge/.config/opencode/skills/jira-epic/SKILL.md |
| When user asks to create a Jira task, ticket, or issue. | jira-task | /home/jorge/.config/opencode/skills/jira-task/SKILL.md |
| When user says "judgment day", "judgment-day", "review adversarial", "dual review", "doble review", "juzgar", "que lo juzguen". | judgment-day | /home/jorge/.config/opencode/skills/judgment-day/SKILL.md |
| When working with Next.js - routing, Server Actions, data fetching. | nextjs-15 | /home/jorge/.config/opencode/skills/nextjs-15/SKILL.md |
| When writing E2E tests - Page Objects, selectors, MCP workflow. | playwright | /home/jorge/.config/opencode/skills/playwright/SKILL.md |
| When user wants to review PRs, analyze issues, or audit PR/issue backlog. | pr-review | /home/jorge/.config/opencode/skills/pr-review/SKILL.md |
| When writing Python tests - fixtures, mocking, markers. | pytest | /home/jorge/.config/opencode/skills/pytest/SKILL.md |
| When writing React components - no useMemo/useCallback needed. | react-19 | /home/jorge/.config/opencode/skills/react-19/SKILL.md |
| When user asks to create a new skill, add agent instructions, or document patterns for AI. | skill-creator | /home/jorge/.config/opencode/skills/skill-creator/SKILL.md |
| When building a presentation, slide deck, course material, stream web, or talk slides. | stream-deck | /home/jorge/.config/opencode/skills/stream-deck/SKILL.md |
| When styling with Tailwind - cn(), theme variables, no var() in className. | tailwind-4 | /home/jorge/.config/opencode/skills/tailwind-4/SKILL.md |
| When reviewing technical exercises, code assessments, candidate submissions, or take-home tests. | technical-review | /home/jorge/.config/opencode/skills/technical-review/SKILL.md |
| When writing TypeScript code - types, interfaces, generics. | typescript | /home/jorge/.config/opencode/skills/typescript/SKILL.md |
| When using Zod for validation - breaking changes from v3. | zod-4 | /home/jorge/.config/opencode/skills/zod-4/SKILL.md |
| When managing React state with Zustand. | zustand-5 | /home/jorge/.config/opencode/skills/zustand-5/SKILL.md |

## Compact Rules

Pre-digested rules per skill. Delegators copy matching blocks into sub-agent prompts as `## Project Standards (auto-resolved)`.

### ai-sdk-5
- useChat moved from `ai` to `@ai-sdk/react`; use `sendMessage` not `handleSubmit`
- Always use `transport: new DefaultChatTransport(...)` (v5 requires explicit transport)
- Server-side: `generateText`, `streamText`, `generateObject`, `streamObject` from `ai`
- Tool calling: `tool` from `ai/create-tool` or `ai` with `zod` schema
- Use `@ai-sdk/openai`, `@ai-sdk/anthropic`, etc. for model providers
- Never import `useChat` from `ai` directly — that's v4

### scope-rule-architect-angular
- ALL components standalone by default (Angular 20+), no `standalone: true` needed
- Use `input()`/`output()` functions, never `@Input()`/`@Output()` decorators
- Use `inject()` instead of constructor DI
- Use `@if`/`@for`/`@switch` control flow, never `*ngIf`/`*ngFor`/`*ngSwitch`
- Signals: `signal()`, `computed()`, `effect()` — avoid lifecycle hooks
- Screaming Architecture: folder structure reveals intent (e.g., `products/`, `cart/`)
- Scope Rule: a component's files live in its own folder

### branch-pr
- EVERY PR MUST link an approved issue — no exceptions
- EVERY PR MUST have exactly one `type:*` label
- Automated checks MUST pass before merge
- Blank PRs without issue linkage blocked by GitHub Actions
- Never skip hooks (`--no-verify`), never force-push to main

### cdp-chrome-debugger
- ALWAYS check `chrome.debugger.isAttached` before attaching to avoid double-attach
- Service worker may terminate: persist state, reconnect on wake
- Use `Network.enable`, `Network.requestWillBeSent`, `Network.responseReceived` for capture
- Filter by URL pattern early to avoid memory leaks
- Detach in `onSuspend` listener: `chrome.debugger.detach({ tabId })`
- Never attach without a matching detach path

### chrome-extension-mv3
- Service Worker is EPHEMERAL — no global state, use `chrome.storage` for persistence
- Use `chrome.alarms` + `chrome.storage.session` for wake-up and state recovery
- Messaging: runtime.sendMessage (SW↔content script), runtime.connect (long-lived)
- content scripts are isolated — use `world: "MAIN"` only for DOM injection
- `chrome.scripting.executeScript` for dynamic injection
- Manifest V3: service worker replaces background page; `host_permissions` required
- DevTools panel: `chrome.devtools.panels.create`, separate HTML page

### django-drf
- Use `viewsets.ModelViewSet` for CRUD endpoints, override `get_serializer_class()` per action
- Use `@action(detail=true/false)` for custom endpoints
- Serializers: `ModelSerializer` with explicit fields, validation in `validate_<field>()`
- Filters: `django-filter` with `filterset_class` on the ViewSet
- Permissions: `permission_classes` at class level, `check_permissions` for custom logic
- Nested routers via `@extend_schema` for OpenAPI docs

### dotnet
- Use Minimal APIs for all new endpoints (no controllers)
- TypedResults over IResult: `TypedResults.Ok`, `TypedResults.NotFound`, etc.
- Groups for route organization: `app.MapGroup("/api/orders")`
- EF Core: use compiled queries for hot paths, `AsNoTracking` for reads
- Clean Architecture: Domain → Application (CQRS) → Infrastructure → API
- Use `Guid` as primary key type, `Ulid` for ordered GUID alternative

### go-testing
- Table-driven tests: `tests []struct{ name string; args ...; want ... }` pattern
- Bubbletea TUI: use `teatest.NewTestModel` + `teatest.Verify` for model testing
- Golden files: `testdata/*.golden` with `flag.Update()` for snapshot updates
- Use `t.Cleanup()` over `defer` in tests for cleanup ordering
- Subtests: `t.Run(name, fn)` for grouped test cases
- Mock interfaces via test implementations, not mock libraries

### homebrew-release
- GGA: tag format `V{version}` (e.g., `V2.6.2`), tarball from source
- Gentleman.Dots: tag format `v{version}` (e.g., `v2.5.1`), pre-built binaries
- Update formula SHA256 after build; bump `version` string in `.rb`
- Test formula: `brew install --build-from-source <formula>`
- Create GitHub release with binaries attached after tag push

### issue-creation
- MUST use template (bug report or feature request) — blank issues disabled
- Every issue gets `status:needs-review` automatically
- Maintainer MUST add `status:approved` before PR can be opened
- Questions go to Discussions, not issues
- Provide reproduction steps for bugs, user value for features

### jira-epic
- Epic template: Feature Overview, Goals, Acceptance Criteria, Technical Notes, Risks
- Always link Figma designs when available
- Include affected components (API, UI, SDK) in technical notes
- Add labels: `epic`, relevant feature area
- Link related epics or dependencies

### jira-task
- Split multi-component work into separate tasks (API task, UI task, SDK task)
- Bug template: Steps to Reproduce, Expected vs Actual, Environment, Logs/Evidence
- Feature template: Description, Acceptance Criteria, Technical Notes
- Always link to parent epic if applicable
- Add component labels

### judgment-day
- Launch TWO independent blind judge sub-agents simultaneously (no collusion)
- Judges receive NO context about each other
- Synthesize findings after both complete; identify agreement vs disagreement
- Fix issues found by both (high confidence) and at least one (medium confidence)
- Iterate max 2 rounds: re-judge after fixes. If both don't pass → escalate
- Load skill registry before launching judges for context-aware review

### nextjs-15
- App Router file conventions: `layout.tsx`, `page.tsx`, `loading.tsx`, `error.tsx`, `not-found.tsx`
- Server Components by default — add `'use client'` only for interactivity/hooks
- Data fetching: `fetch` in Server Component (auto-dedup), no `getServerSideProps`
- Server Actions: `'use server'` in functions, form action prop
- `useRouter` from `next/navigation` (not `next/router`)
- Dynamic routes: `[param]` folder, `params` prop in page/layout

### playwright
- Use MCP tools FIRST: navigate → snapshot → interact → screenshot, THEN write test
- Accurately capture selectors from real DOM, never guess
- Page Object pattern: `class LoginPage { ... }` with locators and methods
- Use `data-testid` attributes over fragile CSS selectors
- Tests in `e2e/` directory, parallel by default
- `test.use({ storageState })` for authenticated sessions

### pr-review
- List open PRs first with `gh pr list`, then review each
- PR needs: linked issue, type label, automated checks passing
- Review: correctness, security, test coverage, conventions, performance
- For issues: check reproduction steps, priority, applicable labels
- All output in Markdown with actionable feedback

### pytest
- Fixtures for setup/teardown, `conftest.py` for shared fixtures
- Parametrize: `@pytest.mark.parametrize` for multiple test cases
- Mocking: `monkeypatch` for simple, `unittest.mock` (or `pytest-mock`) for complex
- Markers: `@pytest.mark.django_db`, `@pytest.mark.asyncio`, custom markers
- Class-based grouping: `class TestFeature:` for related tests
- Use `tmp_path` fixture for temp file tests

### react-19
- No `useMemo`/`useCallback` — React Compiler auto-memoizes
- Use `use()` hook for reading promises and context
- Actions: `useActionState` for form mutations, `useOptimistic` for optimistic UI
- `useTransition` for non-blocking state updates
- `ref` is regular prop — no `forwardRef` needed
- Metadata: export `metadata` object from page/layout

### skill-creator
- Frontmatter: name, description (with Trigger:), license, metadata
- Structured sections: When to Use, Critical Patterns, Rules
- Test triggers: worst case, false positive, case sensitivity
- Place in tool-specific skills directory (`~/.config/opencode/skills/<name>/SKILL.md`)
- One trigger per skill; if multiple, document in description
- Create complementary `.gitignore` if skill generates files

### stream-deck
- Single HTML file, vanilla JS/CSS, no frameworks, no build step
- 100dvh viewport, no scroll — everything fits in one screen
- All diagrams as inline SVG elements (no image files)
- Gentleman Kanagawa Blur theme: dark bg (#1a1b2e), cyan accent (#7fb4c8), wave (#7ec4a3)
- Vim-mode badges: Normal (blue), Insert (green), Visual (purple), Command (red)
- Slides grouped into modules with sidebar rail navigation
- Arrow keys + click navigation

### tailwind-4
- Never use `var()` in className — use `style` prop or theme variables
- Dynamic values → `style={{ width: \`${x}%\` }}`
- Conditional styles → `cn("base", condition && "variant")`
- Static-only → plain `className`, no `cn()` needed
- Use `@theme` directive in CSS for custom design tokens
- `@import "tailwindcss"` replaces `@tailwind` directives

### technical-review
- 6 evaluation factors: Architecture, Correctness, Testing, Code Quality, Security, Documentation
- Score each 0-10 with specific code evidence
- Red flags: security issues, leaked data, no error handling, no tests for senior roles
- Use Task + explore agent first to understand project layout
- Output as Markdown table with actionable feedback

### typescript
- Const Types pattern: `const X = { ... } as const` → `type X = (typeof X)[keyof typeof X]`
- Flat interfaces: prefer interfaces to type aliases for objects
- Use `satisfies` operator for type validation without widening
- Branded types for nominal typing: `type UserId = string & { __brand: "UserId" }`
- Strict mode: `strict: true` in tsconfig, no `any`, use `unknown` for dynamic values
- Prefer `Map`/`Set` generics over object-as-map pattern

### zod-4
- v4: top-level validators (`z.email()`, `z.uuid()`, `z.url()`) — no `.string().email()`
- v4: `.min(1)` replaces `.nonempty()`, `.max()` replaces `.maxLength()`
- Object errors: second arg `{ error: "message" }` replaces `.required_error()`
- Pipe for coercion: `z.pipe(z.string(), z.number())` replaces `.transform(Number)`
- `z.schema()` replaces `.parse()` for schema extraction
- Use `z.infer<typeof schema>` for type inference

### zustand-5
- Store: `create<Store>()((set, get) => ({...}))`
- Selectors: `useStore(s => s.field)` for reactive slices
- Immer middleware for nested state: `import { immer } from 'zustand/middleware/immer'`
- Persist middleware: `persist(storage, { name: 'store-key' })`
- Subscribe outside React: `useStore.getState()`, `useStore.subscribe(fn)`
- v5: no `createStore` export — use `create` for everything

## Project Conventions

No project convention files found. The project is in early planning stage with only RDP-Stowkeeper.md.

| File | Path | Notes |
|------|------|-------|
| RDP-Stowkeeper.md | /mnt/480GB/Proyectos/Personales/20260502_stowkeeper/20260502_stowkeeper_git/stowkeeper/RDP-Stowkeeper.md | Project design decision document |
