# Plan 005: A fractional `step` / `win_hours` no longer breaks the fleet assembler or the configurator

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- run_awr_fleet.sh run_awr_trend.sh`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

Both wrappers accept fractional values for `step` and `win_hours` (`0.25` =
15 minutes is a documented use) — the validator `v_posdec` allows them and
the SQL handles them. But two places feed those values to bash `$(( … ))`,
which is integer-only:

1. **Fleet** (`run_awr_fleet.sh`): with a fractional `step`, every per-DB
   extract runs to completion (minutes to hours of database work), then the
   assembler dies on an arithmetic error while drawing the "Compared windows"
   strip. No report is written and the script then aborts on an unset
   variable. All the work is lost.
2. **Single-DB configurator** (`run_awr_trend.sh --configure`): with a
   fractional `step` or `win_hours`, the arithmetic error aborts the whole
   dispatch `case` statement, and bash falls through into the positional
   path with the connect string set to the literal `--configure`, so it
   tries to run `sqlplus` against that.

Both were reproduced at the planned-at commit. A value with a leading zero
(`08`) fails the same way (bash reads it as invalid octal).

## Current state

### Fleet wrapper — `run_awr_fleet.sh`

Inside `do_assemble`, the window-strip loop (`run_awr_fleet.sh:1350-1358`):

```bash
            for (( woff2 = win_maxoff; woff2 >= 0; woff2-- )); do
                [[ -n "${WIN_BEGIN[$woff2]:-}" ]] || continue
                dowv="${WIN_DOW[$woff2]}"; beginv="${WIN_BEGIN[$woff2]}"; endv="${WIN_END[$woff2]}"
                if [[ "$woff2" -eq 0 ]]; then
                    label='current'
                else
                    wk=$(( woff2 * STEP ))
                    label="-${wk}${STEP_UNIT}"
                fi
```

`STEP` is validated as a positive decimal, not an integer (`run_awr_fleet.sh:1616`):

```bash
v_posdec    "$STEP"        2>/dev/null || _pos_die step       "$STEP"       "a positive number"
```

The validator (`run_awr_fleet.sh:312-313`):

```bash
v_posdec()    { { [[ "$1" =~ ^([0-9]+|[0-9]*\.[0-9]+|[0-9]+\.[0-9]*)$ ]] && [[ "$1" =~ [1-9] ]]; } \
                  && return 0; echo "  -> enter a positive number (e.g. 1, or 0.25 for 15 min)." >&2; return 1; }
```

After the failure, the main script continues past `do_assemble "$WORK"`
(line 1692) and dies at line 1708 on the unset `ASSEMBLE_ERR_COUNT`.

`woff2 * STEP` is the only arithmetic use of `STEP` in this file
(`grep -n 'STEP' run_awr_fleet.sh | grep '\$((' ` → only line 1356).

### Single-DB wrapper — `run_awr_trend.sh`

`print_span_hint`, called by the configurator (`run_awr_trend.sh:707-722`):

```bash
# Human-readable "what windows will I get" + AWR-retention nudge.
print_span_hint() {
    local mult=168
    case "$STEP_UNIT" in h) mult=1;; d) mult=24;; w) mult=168;; esac
    local step_hours=$(( STEP * mult ))
    local span_hours=$(( WEEKS_BACK * step_hours + WIN_HOURS ))
    local span_days=$(( span_hours / 24 ))
    local rem_hours=$(( span_hours % 24 ))
    local span_txt="${span_hours} h"
    [[ "$span_days" -gt 0 ]] && span_txt="${span_days} d ${rem_hours} h (${span_hours} h)"
    echo "Windows:   current window + ${WEEKS_BACK} prior, spaced ${STEP}${STEP_UNIT} apart."
    echo "Span:      reaches back ~${span_txt}; AWR retention must cover it."
    [[ "$span_days" -ge 8 ]] && \
        echo "           ${DIM}(default 19c retention is 8 days — check dba_hist_wr_control.)${RST}"
    return 0
}
```

The dispatch it aborts (`run_awr_trend.sh:854-858`, then `:879`):

```bash
case "${1:-}" in
    -c|--configure|-i|--interactive|configure)
        configure
        exit $?
        ;;
...
# ---- positional (non-interactive) path -------------------------------------
CONN="$1"
```

`WEEKS_BACK` is validated by `v_posint` (`^[1-9][0-9]*$`) so it is always a
safe integer; `STEP` and `WIN_HOURS` are validated by `v_posdec`.

### Conventions

- These wrappers run on AIX / Solaris database hosts with old userlands.
  **No GNU-only flags** (`grep -o`, `sed -E`, `find -maxdepth`, unguarded
  `date -d`); `./lint.sh` check 10 enforces it. The fixes below use only
  bash built-ins — do not introduce `awk`, `bc` or `python`.
- Project rule: a fleet fix goes in `run_awr_fleet.sh`, a single-DB fix in
  `run_awr_trend.sh`. They are separate files with deliberate copies; do not
  try to share a function between them (`run_awr_trend.sh` dispatches at
  parse time and can not be sourced).
- For whole-number inputs the output must stay **byte-identical** to today.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Shell syntax | `bash -n run_awr_fleet.sh && bash -n run_awr_trend.sh` | exit 0, no output |
| Lint (includes portability check) | `./lint.sh` | `lint: clean`, exit 0 |
| Function-level test of the span hint | see step 2 | exact expected text |

No database or `sqlplus` is available to you; none is needed for these checks.

## Scope

**In scope** (the only files you should modify):
- `run_awr_fleet.sh` (the label computation in `do_assemble`)
- `run_awr_trend.sh` (`print_span_hint` only)

**Out of scope** (do NOT touch):
- `v_posdec` — fractional values are a supported feature; do not tighten it.
- Any SQL file, `server/`, `docs/configurator.html` (the web configurator
  has its own JavaScript).
- Restructuring the dispatch `case` in `run_awr_trend.sh`.

## Git workflow

- Branch: `advisor/005-wrappers-fractional-step` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(wrappers): fractional step / win_hours no longer hit bash integer math`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Capture today's output for whole-number inputs (baseline)

Run and save the output:

```bash
for a in "1 w 4 1" "2 d 7 2" "1 h 4 1" "3 w 12 6"; do
  set -- $a
  STEP=$1 STEP_UNIT=$2 WEEKS_BACK=$3 WIN_HOURS=$4 DIM= RST= \
    bash -c "$(sed -n '/^print_span_hint() {/,/^}/p' run_awr_trend.sh); print_span_hint"
done > /tmp/span_before.txt
```

**Verify**: `wc -l < /tmp/span_before.txt` → 8 or more lines, and
`grep -c "syntax error" /tmp/span_before.txt` → `0`.

### Step 2: Make `print_span_hint` safe for fractional input

In `run_awr_trend.sh`, replace the whole `print_span_hint` function with:

```bash
# Human-readable "what windows will I get" + AWR-retention nudge.
print_span_hint() {
    local mult=168
    case "$STEP_UNIT" in h) mult=1;; d) mult=24;; w) mult=168;; esac
    echo "Windows:   current window + ${WEEKS_BACK} prior, spaced ${STEP}${STEP_UNIT} apart."
    # Bash arithmetic is integer-only: a fractional step / win_hours (0.25 =
    # 15 min, both accepted by v_posdec) or a leading zero must never reach
    # $(( )) -- the error would abort the dispatch case and fall through into
    # the positional path.
    if [[ "$STEP" =~ ^[1-9][0-9]*$ && "$WIN_HOURS" =~ ^[1-9][0-9]*$ ]]; then
        local step_hours=$(( STEP * mult ))
        local span_hours=$(( WEEKS_BACK * step_hours + WIN_HOURS ))
        local span_days=$(( span_hours / 24 ))
        local rem_hours=$(( span_hours % 24 ))
        local span_txt="${span_hours} h"
        [[ "$span_days" -gt 0 ]] && span_txt="${span_days} d ${rem_hours} h (${span_hours} h)"
        echo "Span:      reaches back ~${span_txt}; AWR retention must cover it."
        [[ "$span_days" -ge 8 ]] && \
            echo "           ${DIM}(default 19c retention is 8 days — check dba_hist_wr_control.)${RST}"
    else
        echo "Span:      reaches back ${WEEKS_BACK} x ${STEP}${STEP_UNIT} + ${WIN_HOURS} h; AWR retention must cover it."
    fi
    return 0
}
```

(The long dash in the retention line is copied from the existing code —
keep that line byte-for-byte as it is in the file today.)

**Verify**:

1. Byte-identity for whole numbers — rerun the loop from step 1 into
   `/tmp/span_after.txt`, then `diff /tmp/span_before.txt /tmp/span_after.txt`
   → no output.
2. Fractional and leading-zero input:

```bash
for a in "0.25 h 16 0.25" "1 w 4 0.5" "08 h 4 1"; do
  set -- $a
  STEP=$1 STEP_UNIT=$2 WEEKS_BACK=$3 WIN_HOURS=$4 DIM= RST= \
    bash -c "$(sed -n '/^print_span_hint() {/,/^}/p' run_awr_trend.sh); print_span_hint; echo rc=\$?"
done
```

   Expected output, exactly:

```
Windows:   current window + 16 prior, spaced 0.25h apart.
Span:      reaches back 16 x 0.25h + 0.25 h; AWR retention must cover it.
rc=0
Windows:   current window + 4 prior, spaced 1w apart.
Span:      reaches back 4 x 1w + 0.5 h; AWR retention must cover it.
rc=0
Windows:   current window + 4 prior, spaced 08h apart.
Span:      reaches back 4 x 08h + 1 h; AWR retention must cover it.
rc=0
```

3. `bash -n run_awr_trend.sh` → exit 0.

### Step 3: Make the fleet window label safe for fractional input

In `run_awr_fleet.sh`, in `do_assemble`'s window-strip loop, replace:

```bash
                    wk=$(( woff2 * STEP ))
                    label="-${wk}${STEP_UNIT}"
```

with:

```bash
                    # STEP may be fractional (0.25 = 15 min) or carry a
                    # leading zero; bash arithmetic is integer-only, and an
                    # error here would lose the whole assembled report.
                    if [[ "$STEP" =~ ^[1-9][0-9]*$ ]]; then
                        wk=$(( woff2 * STEP ))
                        label="-${wk}${STEP_UNIT}"
                    else
                        label="-${woff2}x${STEP}${STEP_UNIT}"
                    fi
```

Keep the indentation of the surrounding code (20 spaces for the `if`).

**Verify**:
- `bash -n run_awr_fleet.sh` → exit 0.
- `grep -n 'STEP' run_awr_fleet.sh | grep -c '\$(( woff2 \* STEP ))'` → `1`
  and that one line sits inside the new `if` (check with
  `grep -n -B1 '\$(( woff2 \* STEP ))' run_awr_fleet.sh` → the line above is
  the `if [[ "$STEP" =~ ^[1-9][0-9]*$ ]]; then`).
- Label logic in isolation:

```bash
for a in "3 1" "3 2" "3 0.25" "2 08"; do set -- $a; woff2=$1; STEP=$2; STEP_UNIT=h
  if [[ "$STEP" =~ ^[1-9][0-9]*$ ]]; then wk=$(( woff2 * STEP )); label="-${wk}${STEP_UNIT}"; else label="-${woff2}x${STEP}${STEP_UNIT}"; fi
  echo "$label"; done
```

  → prints `-3h`, `-6h`, `-3x0.25h`, `-2x08h`.

### Step 4: Make sure no other integer arithmetic sees a decimal value

Run: `grep -n '\$((' run_awr_fleet.sh run_awr_trend.sh | grep -E 'STEP|WIN_HOURS'`

**Verify**: every hit is either inside the two guarded `if` blocks you just
wrote or uses a different variable whose name merely contains the text
(for example `step_hours` computed inside the guarded block). Any other hit
that uses `$STEP` / `$WIN_HOURS` (or the bare names `STEP` / `WIN_HOURS`)
unguarded → STOP and report the line.

### Step 5: Lint

**Verify**: `./lint.sh` → `lint: clean`, exit 0.

## Test plan

- No test framework exists for the wrappers. The function-level checks in
  steps 2 and 3 are the tests (whole-number byte-identity + fractional +
  leading-zero inputs).
- If `tools/check.sh` exists (plan 003), run it → `check.sh: all checks passed`.

## Done criteria

- [ ] `bash -n run_awr_fleet.sh && bash -n run_awr_trend.sh` exits 0
- [ ] `./lint.sh` exits 0
- [ ] Step 2 verification 1 (`diff` of before/after) is empty
- [ ] Step 2 verification 2 output matches exactly
- [ ] `git status --short` shows only `run_awr_fleet.sh` and `run_awr_trend.sh`
- [ ] `plans/README.md` status row updated

## STOP conditions

- `print_span_hint` in the live file differs from the excerpt above
  (other than whitespace).
- Step 4 finds another unguarded arithmetic use of `STEP` or `WIN_HOURS`.
- `./lint.sh` flags the edit as a portability problem — do not "fix" it
  with a GNU-only construct; report.

## Maintenance notes

- Owner check on a real fleet (not possible for the executor): one fleet
  run with a 15-minute cadence, e.g. positional args `AUTO 0.25 8 10 0.25 h`,
  must end with a `Report:` line and the "Compared windows" strip must show
  labels like `-3x0.25h`.
- If a future change wants true fractional labels (`-0.75h`), compute them
  in the extract SQL (which has real arithmetic) and pass them through the
  existing `FLEET-WINDOW` comment, not in bash.
- Reviewer: confirm no `awk`/`bc` slipped in and that whole-number output
  is unchanged.
