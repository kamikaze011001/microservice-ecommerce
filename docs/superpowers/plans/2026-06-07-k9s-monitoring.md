# k9s Monitoring Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `make k9s [ENV=local|eks]` that opens a k9s terminal UI on the chosen cluster using a repo-committed config (skin + namespace hotkeys), so monitoring is one command and the same config serves both the local kind cluster and a future EKS cluster.

**Architecture:** k9s separates view config (skin/hotkeys/UI prefs — committed under `k8s/k9s/`, env-agnostic) from the target cluster (the kube *context* — selected by an `ENV` flag that maps to a context name). A `make k9s` recipe sets `K9S_CONFIG_DIR` to the repo dir and launches with `--context`. k9s's own per-cluster state (last namespace/view) is written under `k8s/k9s/clusters/**` and git-ignored.

**Tech Stack:** k9s (Homebrew), GNU Make, kubectl/kind contexts, YAML config.

> **Note on verification:** This is infra/config work with no unit-test framework. "Tests" here are concrete verification commands (`make -n`, launching k9s, observing the TUI) with expected results. Each task ends with a commit.

> **Schema caveat (read once):** k9s config schema varies by version. Config files below target current k9s (v0.32+) using `K9S_CONFIG_DIR`, root key `k9s:`, `k9s.ui.skin`, and `hotKeys:`. Task 1 pins the installed version and confirms these. If the installed k9s rejects/ignores a key, adjust to that version's schema (`k9s --help`, the in-repo `k8s/k9s/` files, and the k9s docs) — do not invent keys.

---

### Task 1: Install k9s and pin its config schema

**Files:** none (environment + discovery only)

- [ ] **Step 1: Verify k9s is absent (expected starting state)**

Run: `command -v k9s || echo "ABSENT"`
Expected: `ABSENT` (if already installed, skip Step 2).

- [ ] **Step 2: Install k9s**

Run: `brew install k9s`
Expected: k9s installed; `k9s version` prints a version (e.g. `v0.32.x`).

- [ ] **Step 3: Confirm the config-dir mechanism and schema for this version**

Run: `k9s version` and `k9s info`
Expected: `k9s info` prints a "Configuration:" path. Confirm k9s honors `K9S_CONFIG_DIR`:
```bash
K9S_CONFIG_DIR=/tmp/k9s-probe k9s info | grep -i config
```
Expected: the printed config dir is `/tmp/k9s-probe` (proves `K9S_CONFIG_DIR` is respected). If this version uses a different variable (older `K9SCONFIG`/`XDG_CONFIG_HOME`), note it — every later task's `K9S_CONFIG_DIR` reference must use the variable this step confirmed.

- [ ] **Step 4: Record findings (no commit — discovery task)**

Write the confirmed version + config-dir variable into the PR description / task notes. No file changes, nothing to commit.

---

### Task 2: Committed config dir — global prefs, skin, gitignore

**Files:**
- Create: `k8s/k9s/config.yaml`
- Create: `k8s/k9s/skins/microecom.yaml`
- Create: `k8s/k9s/.gitignore`

- [ ] **Step 1: Create the global config**

Create `k8s/k9s/config.yaml`:
```yaml
# k9s global config — committed, env-agnostic (skin + UI prefs only).
# Per-cluster runtime state (last namespace/view) is written by k9s under
# k8s/k9s/clusters/** and is git-ignored (see .gitignore in this dir).
k9s:
  liveViewAutoRefresh: true
  refreshRate: 2
  maxConnRetry: 5
  readOnly: false
  noExitOnCtrlC: false
  skipLatestRevCheck: true
  ui:
    skin: microecom
    enableMouse: false
    headless: false
    logoless: false
    crumbsless: false
    reactive: true
    noIcons: false
  logger:
    tail: 200
    buffer: 5000
    sinceSeconds: -1
```

- [ ] **Step 2: Create the skin (Nord palette, readable on dark terminals)**

Create `k8s/k9s/skins/microecom.yaml`:
```yaml
# microecom k9s skin (Nord palette). Selected via k9s.ui.skin: microecom.
k9s:
  body:
    fgColor: '#d8dee9'
    bgColor: default
    logoColor: '#88c0d0'
  prompt:
    fgColor: '#d8dee9'
    bgColor: default
    suggestColor: '#ebcb8b'
  info:
    fgColor: '#a3be8c'
    sectionColor: '#d8dee9'
  dialog:
    fgColor: '#d8dee9'
    bgColor: default
    buttonFgColor: '#d8dee9'
    buttonBgColor: '#81a1c1'
    buttonFocusFgColor: '#eceff4'
    buttonFocusBgColor: '#b48ead'
    labelFgColor: '#ebcb8b'
    fieldFgColor: '#d8dee9'
  frame:
    border:
      fgColor: '#4c566a'
      focusColor: '#88c0d0'
    menu:
      fgColor: '#d8dee9'
      keyColor: '#88c0d0'
      numKeyColor: '#88c0d0'
    crumbs:
      fgColor: '#eceff4'
      bgColor: '#4c566a'
      activeColor: '#b48ead'
    status:
      newColor: '#88c0d0'
      modifyColor: '#81a1c1'
      addColor: '#a3be8c'
      errorColor: '#bf616a'
      highlightColor: '#ebcb8b'
      killColor: '#d08770'
      completedColor: '#4c566a'
    title:
      fgColor: '#d8dee9'
      bgColor: default
      highlightColor: '#ebcb8b'
      counterColor: '#88c0d0'
      filterColor: '#b48ead'
  views:
    table:
      fgColor: '#d8dee9'
      bgColor: default
      header:
        fgColor: '#d8dee9'
        bgColor: default
        sorterColor: '#88c0d0'
    yaml:
      keyColor: '#88c0d0'
      colonColor: '#81a1c1'
      valueColor: '#d8dee9'
    logs:
      fgColor: '#d8dee9'
      bgColor: default
      indicator:
        fgColor: '#d8dee9'
        bgColor: '#4c566a'
```

- [ ] **Step 3: Git-ignore k9s runtime state**

Create `k8s/k9s/.gitignore`:
```gitignore
# k9s writes per-cluster state, logs, and dumps here at runtime.
# Keep only the curated config (config.yaml, skins/, hotkeys.yaml).
/clusters/
/*.log
/screen-dumps/
/benchmarks/
```

- [ ] **Step 4: Verify k9s loads the config without errors**

Run (cluster need not be up; we only check config parsing):
```bash
K9S_CONFIG_DIR="$(pwd)/k8s/k9s" k9s info
```
Expected: prints config paths rooted at `k8s/k9s`, no YAML parse errors. Then launch briefly against the local context if the cluster is up (`make k8s-start` first if needed):
```bash
K9S_CONFIG_DIR="$(pwd)/k8s/k9s" k9s --context kind-microecom
```
Expected: TUI opens with the Nord skin (blue logo, muted borders); press `:q` to quit. Confirm only curated files are tracked:
```bash
git status --porcelain k8s/k9s
```
Expected: shows `config.yaml`, `skins/microecom.yaml`, `.gitignore` as untracked — and NOT any `clusters/` dir (it's ignored).

- [ ] **Step 5: Commit**

```bash
git add k8s/k9s/config.yaml k8s/k9s/skins/microecom.yaml k8s/k9s/.gitignore
git commit -m "feat(k9s): committed config dir — global prefs, Nord skin, gitignore runtime state

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Namespace-jump hotkeys

**Files:**
- Create: `k8s/k9s/hotkeys.yaml`

- [ ] **Step 1: Create the hotkeys**

Create `k8s/k9s/hotkeys.yaml`:
```yaml
# Project hotkeys: jump straight to this cluster's namespaces. Works on any
# context using the same namespace names (kind + EKS) — a reason to keep
# apps/infra/bootstrap on EKS too.
hotKeys:
  shift-a:
    shortCut: Shift-A
    description: Pods in apps
    command: pods apps
  shift-i:
    shortCut: Shift-I
    description: Pods in infra
    command: pods infra
  shift-b:
    shortCut: Shift-B
    description: Jobs in bootstrap
    command: jobs bootstrap
```

- [ ] **Step 2: Verify the hotkeys load and work**

Run (cluster up — `make k8s-start` if needed):
```bash
K9S_CONFIG_DIR="$(pwd)/k8s/k9s" k9s --context kind-microecom -n apps
```
Expected: TUI opens. Press `Shift-A` → pods view scoped to `apps`; `Shift-I` → pods in `infra`; `Shift-B` → jobs in `bootstrap`. Press `?` to confirm the three hotkeys appear in the help overlay. Quit with `:q`.

**If a hotkey does nothing or errors:** this version's hotkey `command` syntax differs. Check the help overlay text and k9s docs for the namespace-scoping form for the installed version (e.g. some versions expect just `pods` and a separate `ns` selection). Adjust the `command:` values until all three jump correctly. Do not leave a non-working hotkey committed.

- [ ] **Step 3: Commit**

```bash
git add k8s/k9s/hotkeys.yaml
git commit -m "feat(k9s): namespace-jump hotkeys (Shift-A/I/B → apps/infra/bootstrap)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `make k9s` launcher with ENV switch

**Files:**
- Modify: `Makefile` (add `k9s` to the `.PHONY` at line 336; add the target after `k8s-payment-stress-logs` near line 398; add a help line in the Kubernetes block near line 47)

- [ ] **Step 1: Add `k9s` to the existing k8s `.PHONY` group**

In `Makefile`, line 336 currently reads:
```make
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-mysql-status k8s-payment-stress k8s-payment-stress-logs
```
Change it to:
```make
.PHONY: k8s-apps k8s-apps-down k8s-status k8s-mysql-status k8s-payment-stress k8s-payment-stress-logs k9s
```

- [ ] **Step 2: Add the target after `k8s-payment-stress-logs`**

`k8s-payment-stress-logs` ends with:
```make
k8s-payment-stress-logs:
	@kubectl -n apps logs -f -l app=k6-payment-stress --tail=-1
```
Immediately after it, add (recipe lines are TAB-indented, matching the file):
```make

# Launch k9s (terminal UI) on a chosen environment, using the repo's committed
# config (skin + namespace hotkeys). Switch contexts live inside k9s with :ctx.
#   make k9s            # ENV=local (default) → kind cluster
#   make k9s ENV=eks    # EKS (one-time: aws eks update-kubeconfig --alias microecom-eks)
k9s:
	@command -v k9s >/dev/null 2>&1 || { echo "k9s not installed — run: brew install k9s"; exit 1; }
	@case "$(ENV)" in \
	  ""|local) ctx=kind-microecom ;; \
	  eks)      ctx=microecom-eks ;; \
	  *) echo "Unknown ENV '$(ENV)' — use ENV=local or ENV=eks"; exit 1 ;; \
	 esac; \
	 echo "k9s → context $$ctx (ENV=$${ENV:-local}), namespace apps"; \
	 K9S_CONFIG_DIR="$(CURDIR)/k8s/k9s" k9s --context "$$ctx" -n apps
```

- [ ] **Step 3: Add a help line**

In the help target's Kubernetes block, after the line:
```make
	@echo "  make k8s-payment-stress-logs — tail k6 payment-stress output"
```
add:
```make
	@echo "  make k9s [ENV=local|eks]     — open k9s monitor on the chosen cluster"
```

- [ ] **Step 4: Verify Make parses and the ENV map resolves**

Run:
```bash
make -n k9s
make -n k9s ENV=eks
make -n k9s ENV=bogus; echo "exit=$?"
```
Expected:
- `make -n k9s` → shows the `command -v` guard and a recipe resolving `ctx=kind-microecom`.
- `ENV=eks` → resolves `ctx=microecom-eks`.
- `ENV=bogus` → the recipe will print `Unknown ENV 'bogus'` when run (with `-n` it just prints commands; run `make k9s ENV=bogus` to see it exit non-zero). Confirm: `make k9s ENV=bogus; echo "exit=$?"` prints the error and `exit=1`.
- `make help | grep k9s` → shows the new help line.

- [ ] **Step 5: Verify live launch (local)**

Run (cluster up — `make k8s-start` if needed): `make k9s`
Expected: prints `k9s → context kind-microecom (ENV=local), namespace apps`, TUI opens on `apps` with the skin + hotkeys. `:q` to quit.

- [ ] **Step 6: Commit**

```bash
git add Makefile
git commit -m "feat(k9s): make k9s [ENV=local|eks] launcher with committed config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Document in k8s/README.md

**Files:**
- Modify: `k8s/README.md` (add a `## Monitoring with k9s` section before `## AWS portability`)

- [ ] **Step 1: Add the docs section**

In `k8s/README.md`, immediately before the `## AWS portability` heading (line ~62), insert:
```markdown
## Monitoring with k9s

[k9s](https://k9scli.io) is a terminal UI for the cluster. Install once, then
launch with a repo-committed config (skin + namespace hotkeys):

```bash
brew install k9s          # one-time
make k9s                  # local kind cluster (ENV=local default)
make k9s ENV=eks          # EKS context (see below)
```

The config lives in `k8s/k9s/` (shared, version-controlled). k9s's own
per-cluster state is written under `k8s/k9s/clusters/**` and is git-ignored.

**Namespace hotkeys:** `Shift-A` → `apps`, `Shift-I` → `infra`,
`Shift-B` → `bootstrap` jobs. Switch clusters live with `:ctx`.

**EKS (future):** one-time, register the context under the alias the launcher
expects, then use `ENV=eks`:

```bash
aws eks update-kubeconfig --name <cluster-name> --alias microecom-eks
make k9s ENV=eks
```

The same committed config serves both clusters; keep the `apps`/`infra`/`bootstrap`
namespace names on EKS so the hotkeys carry over.
```

- [ ] **Step 2: Verify**

Run: `grep -n "Monitoring with k9s" k8s/README.md` and `grep -n "AWS portability" k8s/README.md`
Expected: the k9s section appears immediately before AWS portability. Eyeball the rendered section for correct fenced-code nesting.

- [ ] **Step 3: Commit**

```bash
git add k8s/README.md
git commit -m "docs(k9s): how to install + run make k9s (local + EKS)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Install (brew, explicit, guard) → Task 1 + Task 4 Step 1 guard. ✓
- Committed `k8s/k9s/` config.yaml / skin / hotkeys / .gitignore → Tasks 2, 3. ✓
- `make k9s` ENV=local|eks → context map → Task 4. ✓
- Docs in k8s/README.md + EKS `update-kubeconfig` note → Task 5. ✓
- Full control (readOnly:false) → Task 2 config.yaml. ✓
- Schema-version caveat verified against installed version → Task 1 + per-task adjust notes. ✓
- Out-of-scope (plugins, read-only, metrics stack, per-env dirs) → not included. ✓

**Placeholder scan:** No TBD/TODO; every file's full content is given; verification commands have expected output. The only conditional ("if a hotkey errors, adjust to the installed version's syntax") is a deliberate, spec-mandated version-reconciliation step, not a placeholder — the working target syntax is provided.

**Consistency:** `K9S_CONFIG_DIR` + `k8s/k9s/` path, the `microecom` skin name (config.yaml `ui.skin: microecom` ↔ `skins/microecom.yaml`), context names (`kind-microecom`, `microecom-eks`), and the `ENV=local|eks` flag are identical across Tasks 2–5 and the README.
