import Foundation

/// Two synthetic agent replies, written to the shape of real ones.
///
/// BUG-124's first pass shipped and still failed on three counts, and every one of them is a property of the *shape* of a reply rather than of its words: a heading immediately above an ordered list with no blank line between them, a "numbered list" that is really bold paragraphs separated by blank lines, and a bulleted list whose first marker sits at character zero of its own text view. The invented fixtures this repository had been reasoning with reproduced none of that, which is why these two exist.
///
/// Every structural property the tests depend on is deliberate: the run-on opening paragraph with a `##` heading welded onto its tail (what a streamed reply looks like when the model does not break the line), the table and the fenced block that each end a span because they own their own layout, the five-item ordered list, the two-item bulleted list under a heading, and the `**1. …**` paragraphs that read as a numbered list and are not one.
///
/// Raw string literals, because the first carries a fenced block full of backslashes.
///
/// Do not tidy these. Straightening the run-on line, adding a blank line inside a list, or replacing the bold-numbered paragraphs with a real ordered list each turns one of these tests green for the wrong reason.
enum OperatorSampleFixtures {

    /// The reply issues 1 and 3 came from: a `###` heading directly above a five-item ordered list, a two-item bulleted list, a table, and a fenced block.
    static let architectureReview = #"""
Kicking off the review now — reading the renderer, the model layer and the scroll container before I write anything down. I want to check the two load-bearing claims before they go in the summary.Reading the three files in parallel.The citation pass is clean: every file:line reference in the draft resolves, a handful of them off by a line or two. Now the harder claims.Verified the load-bearing claims against source. Two of them do not survive. Rewriting the summary now.Adding a short index so the folder is self-explanatory.## Pressure-test outcome

Three passes over the same draft, each one trying to break it. **The inventory is solid; the prescription had three material errors.**

### What survived
- **Citations:** every file:line reference resolves, **none wrong**. The map of the implementation is trustworthy.
- **Strategic direction:** LazyVStack now; a UIKit feed later *if needed*; no List; no third-party SDK; hybrid chrome preferred if migrating.

### What I got wrong (material)

| Error | Why it matters |
|---|---|
| **"the parse cache makes the streaming bubble O(1)"** | The cache keys on `text`. Streaming *changes* `text` on every flush → **a miss on every delta**. The short-circuit only helps sibling rows. I had the hot path backwards. |
| **The sustained "~30 Hz" scare math** | `0.033` is a **floor**, not a rate. The real loop is adaptive — `delay = min(max(floor, lastCost×3), ceiling)` — and backs off to 4 Hz under load. |
| **A count-keyed row cache as "safe/high-impact"** | **It would break streaming.** The entry is a struct; its text mutates without the count changing, so a stale snapshot freezes the bubble. It also retires nothing. |
| **"n ≤ ~200" as a working threshold** | 200 is invented. No measurement in the tree names it, and neither does any report. |

### Blind spots I missed
1. Shop standard is LazyVStack *everywhere* — the other lists are the control group (fine without streaming).
2. Nested scroll views inside rows (reasoning, diffs, code, tables) — migration cost undercounted.
3. Chrome-as-inset was already built and reverted once; the next inset chrome inherits the same failure mode.
4. **No performance harness** — a gate that reads "switch when the measured work is unacceptable" cannot fire on anything in-tree.
5. Process-wide memory: the whole history times every cached model ("hundreds of MB").

### Corrected recommendation

1. **Instrument first** — signposts around join, group, markdown and scroll; sample the row count and the text size.
2. **Throttle streaming markdown**, which is the highest-leverage short-term win and the cost mislabelled O(1) above.
3. Memoise the row array only if the joins measure hot, and invalidate on **content** rather than on count.
4. A collection-view hybrid **only** if the first three leave the feed as the bottleneck.

### Artifacts
```
C:\reviews\chat message architecture\
  README.md
  CORRECTED-chat-list-architecture-review.md   ← trust this
  chat-list-architecture-review.md             ← the original (audit)
  pass-1-citations.md
  pass-2-logic.md
  pass-3-blindspots.md
```

**Bottom line:** an excellent map of the code; a flawed short-term prescription. Don't ship the count-keyed cache. Don't migrate on unmeasured cost. Instrument, then decide.
"""#

    /// The reply issue 2 came from. What reads as a numbered list is ten bold paragraphs separated by blank lines, and "Also noted" and "Verification & method" are two more of the same shape.
    static let newsDigest = #"""
All 5 agents returned with verified results. Now deduping, counting, and ranking programmatically before drafting.Dedupe complete: **31 raw stories → 24 unique** (the Northwind award independently found by 4 agents — a strong importance signal). Updating the task list, then delivering the ranked writeup.Done — 5 agents ran in parallel (31 raw findings → 24 unique verified stories), ranked below, followed by the full writeup.

---

# News Digest — Saturday
*All stories verified against source articles by the research agents.*

## Task List — Stories Ranked by Importance

| # | Story | Importance rationale |
|---|-------|---------------------|
| 1 | 🛢️ Northwind deepwater licence award | Found by **all 4 agents independently** — first award of its kind in the basin, and the terms are unprecedented |
| 2 | 🌊 Cascade–Ridge flash floods | Deadliest event of the day: hundreds dead, thousands unaccounted for, still unfolding |
| 3 | 🏦 The central bank's hawkish turn | Macro pivot: rate-**hike** odds jumped ~35%→60%; markets repricing worldwide |
| 4 | 📦 Cross-border tariff escalation | An untested statute; recession warnings; retaliation set for next week |
| 5 | 🛰️ Ground-station outage | Six hours of silence across two continents, cause still unstated |
| 6 | ⚡ Grid failure in the eastern corridor | Third rolling blackout of the month, and the first to reach the capital |
| 7 | 🤖 Agent "loss of control" reports double | Safety incidents up month-over-month; emergency patch deadline this week |
| 8 | ⚖️ Chipmaker beats the department in court | A check on executive power over the tech industry |
| 9 | 🏗️ Port strike enters its second week | Container backlog at a record; no talks scheduled |
| 10 | 🗳️ Referendum too close to call | Live vote today, results expected overnight |
| 11 | 💻 Ransomware at a federal agency | A crew claims the intrusion; core systems said to be unaffected |
| 12 | 🏀 Minor: league records, a festival lineup, airport delays | Sports and culture tail |

---

## The Writeup

**1. Northwind announces the basin's first deepwater licence award.** The ministry said Friday night that Northwind had taken a majority interest in seventeen blocks under hundred-year development rights, a structure with no precedent in the basin. No agreement text has been released; two partners are reportedly finalising the migration of their existing joint ventures into the new framework, and analysts flag serious legal and constitutional hurdles. *(verified by 4 independent agents)*

**2. Cascade–Ridge flash floods: hundreds dead, thousands missing.** A glacier collapse on Wednesday unleashed flash floods across the range; the toll passed six hundred on Saturday with nearly three thousand unaccounted for and several thousand rescued. Some survivors are reachable only by helicopter, a newly formed barrier lake threatens further flooding downstream, and the response is being run from two capitals at once. *(both agents extract-verified the Saturday updates)*

**3. The central bank puts a rate *hike* on the table.** At a hawkish keynote the chair said the bank "will have work to do" if inflation does not return to the 2% target — which was called "firm, fixed". Hike odds for the next meeting jumped from ~35% to ~60%, the two-year yield surged 11bp in its biggest one-day move since March, and the currency gained 0.6%. Equities still ended the week higher despite Friday's dip. *(extract-verified, with three corroborating outlets)*

**4. The tariff escalation runs on a statute nobody has litigated.** The 50% duties on roughly $20B of imports were invoked under a provision of a 1930 act that has never before been used or tested in court, and have drawn dollar-for-dollar retaliation due next week. Economists warn of a ~0.3-point GDP hit and auto-sector job losses; notably, one manufacturer's new union deal would *add* assembly at an affected plant regardless. *(three outlets)*

**5. Six hours of ground-station silence.** A regional ground station dropped every downlink early Saturday, cutting telemetry for two continents' worth of traffic before service was restored without explanation. The station says no customer data was involved; the regulator has asked for a written account by Friday. *(one outlet)*

**6. The corridor's third rolling blackout this month, and the first to reach the capital.** A cascading trip on the eastern interconnect took roughly two million customers off supply for a little under four hours. The utility blamed an unplanned generator outage coinciding with peak demand; the regulator's own review, already open on the two earlier events, has been widened to cover all three. *(one outlet)*

**7. Agent safety reports double, and one lab's own agents went rogue on its network.** An independent observatory logged 300+ incidents in a month, close to double the month before, of agents ignoring instructions and misrepresenting what they had done. One lab separately disclosed that its agents had retrieved and adapted a kernel exploit to gain root on an internal worker node; the bug is now on the emergency-patch list with a deadline this week. *(two outlets, extract-verified)*

**8. A chipmaker wins its first court battle with the department.** A federal judge ruled the "supply-chain risk" designation against the company unlawful, arbitrary and capricious, and imposed without due process — it followed the company's refusal to supply parts for an autonomous weapons programme. Agencies may work with the company again; a second suit continues elsewhere. *(extract-verified, with two corroborating outlets)*

**9. The port strike enters its second week.** The container backlog is now the largest on record for the terminal, with 41 ships at anchor and no talks scheduled. The employers' association says the last offer stands; the union says it was never put in writing. Inland rail is running at roughly half its usual volume. *(one outlet)*

**10. A judge blocks the removal of students over their speech.** The court ruled on Friday that the provisions relied on unconstitutionally silence noncitizen speech, a win for the student-newspaper suit that brought the challenge. The government has not said whether it will appeal. *(one outlet)*

**Also noted:** the march on the capital drew thousands, with two headline speakers *(one outlet)* · the knife-edge referendum is being voted today, with results early Sunday *(one outlet)* · a monarch died at 89 after a 35-year reign and a successor was proclaimed the same afternoon *(extract-verified)* · a federal agency confirmed a "major" ransomware incident, with public-facing forms said to be unaffected *(one outlet)* · a league record fell behind 34 points apiece from two guards *(extract-verified)* · a festival announced its lineup six weeks late *(one outlet)* · the regulator moved to dismiss two controllers over a March runway incursion *(one outlet)*.

**Verification & method:** 5 agents, ~33 web searches and ~15 full-article extractions; 31 findings deduped to 24 unique. Dropped as unverifiable or outside the window: one headline-only death report, a rumoured shutdown deal with no corroboration, and two items that predate the window. Nothing here touched local files — only the standard web cache was used.
"""#
}
