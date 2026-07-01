# AWR Timeline Comparison — An Introduction

## Executive summary

In the middle of this month we are releasing a new version of our application. Any
significant change to an application carries a risk: the system may become slower,
or behave differently in ways that users notice before we do. This project gives us
a simple, reliable way to answer the question *"is the database behaving the same
way it did before the release?"* — at a glance, in a single report, without
installing anything or putting the production system at any risk. It lets the team
confirm quickly after the release that everything is healthy, and if something has
changed, it points directly at what changed, when, and by how much — turning what
is usually hours of manual investigation into minutes.

## What problem it solves

Oracle databases continuously record detailed performance statistics (a built-in
facility called AWR — the Automatic Workload Repository). The raw data is all
there, but comparing "this Monday morning" against "the last four Monday mornings"
normally means pulling several separate reports and eyeballing them side by side.
That is slow, error-prone, and easy to skip under release pressure.

This toolkit automates exactly that comparison. It looks at the **same time window
across several weeks** — for example, Monday 09:00–10:00 today versus the same hour
on the four previous Mondays — so that normal weekly rhythm (batch jobs, business
hours, quiet weekends) doesn't get mistaken for a problem. Like-for-like windows
make a real change stand out.

## How it works, briefly

- **It only reads.** The entire report is produced by read-only queries against
  Oracle's own performance history. Nothing is installed, created, or modified in
  the database — it is safe to run against production at any time.
- **It compares aligned windows.** The default is "same hour of the week, last
  four weeks", but the cadence is configurable (hour by hour, day by day, etc.).
- **It flags what's unusual, statistically.** Instead of relying on someone
  noticing a number that "looks high", it scores each metric against its own
  recent history and highlights only genuinely unusual movement, graded as
  OK / Warning / Critical.
- **It produces one self-contained HTML file.** Headline health cards, trend
  charts, top SQL statements, wait analysis, and a findings summary — all in a
  single page that can be mailed or attached to a ticket and opened anywhere.
- **Milestones can be drawn on the timeline.** The release itself (or a patch, a
  config change) can be annotated as a vertical marker on the charts, so "before
  vs. after the release" is visible directly in the pictures.

## How it supports the release

1. **Before the release** — run the report to capture what "normal" looks like for
   the hours that matter most (peak business hours, batch windows).
2. **Immediately after go-live** — run it again with the release annotated as a
   timeline marker. Hour-by-hour mode can compare the first hours after the
   release against the hours just before it.
3. **The days and weeks after** — the standard weekly comparison shows whether the
   post-release Mondays look like the pre-release Mondays. Anything drifting shows
   up as a Warning or Critical finding with the exact metric and time window.

For developers, a dedicated **"dev" view** of the report focuses on what the
application itself drives — transaction throughput, query work, parsing, locking —
so application teams can self-check their release without wading through
database-administration internals.

## What it needs

An Oracle 19c database with the Diagnostic + Tuning Pack licensed, and a user
account that can read the performance-history views (any DBA account qualifies).
One command produces the report; there is nothing to deploy and nothing to clean up.
