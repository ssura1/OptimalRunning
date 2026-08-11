# Hardware protocol — watch → phone sync (T-106, T-107)

**The acceptance bar for the sync fix**, and the only place it can be checked: a real run,
on the real watch, ends normally and shows up in the iPhone app — distance, route, heart
rate, splits — with **no manual intervention**.

This needs two paired devices. The Simulator cannot reproduce reachability transitions
between a watch and a phone, which is exactly why `FileTransporting` is injectable and why
everything about *when* to transfer is tested against a fake instead.

Everything below assumes the build from T-106 is installed on both devices.

---

## Section 0 — before the run (5 min, indoors)

| # | Do | Record |
|---|---|---|
| 0.1 | Open the app on the **iPhone**. Note how many runs are in the list. | count: ___ |
| 0.2 | Open the app on the **watch**. | Launches? Y / N |
| 0.3 | Leave the phone at home, or in a bag well away from you. | — |

> **0.3 is not a convenience, it is the test.** A run that syncs only while the phone is in
> your hand proves nothing — `enqueue` writing to disk before any transfer is attempted is
> the property that matters, and it is only exercised when the phone is *not* reachable at
> the moment the run ends.

---

## Section A — the run (15+ min)

Any preset. **Outdoors**, so there is a route to check.

| # | Do | Record |
|---|---|---|
| A.1 | Start the run. Grant Location and Health if asked. | Prompts appeared? Y / N |
| A.2 | Run for at least 10 minutes. Cover real ground — a loop is ideal, so the map has a recognisable shape. | distance: ___ |
| A.3 | **End the run normally**, through the app's own End flow. | — |
| A.4 | Note the distance and duration the watch shows at the end. | ___ mi / ___ |

> **A.3 matters.** The bug was on the *happy* path: a run that ended cleanly deleted its own
> samples. Force-quitting instead would exercise crash recovery, which always worked, and
> would prove nothing about what was broken.

---

## Section B — the sync (indoors, phone nearby again)

| # | Do | Record |
|---|---|---|
| B.1 | Bring the watch near the phone. Open the phone app. **Do not tap anything to force a sync** — there is nothing to tap, and that is the point. | — |
| B.2 | Wait up to 2 minutes. | Run appeared? Y / N — after ___ s |
| B.3 | Open the run. | |
| B.4 | **Distance** matches A.4? | Y / N — phone shows ___ |
| B.5 | **Duration** matches A.4? | Y / N |
| B.6 | **Heart rate** present, and not flat or empty? | Y / N |
| B.7 | **Route** — is there a map, and does its shape match where you ran? | Y / N |
| B.8 | **Splits / per-step table** present? | Y / N |

**If B.2 fails**, that is the fix not working, and the useful next step is to check whether
the run is still on the watch rather than assuming it is lost:

```sh
xcrun devicectl list devices | grep -i watch     # must read "connected"
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.optimalrunner.watch \
  --source / --destination ./watch-container
find ./watch-container -name "*.completed" -o -name "*.envelope.gz"
```

A `.envelope.gz` in `Outbox/` means the run was durably queued and the *transfer* is what
failed — a different problem, and a much better one, than the run never being built. A
`.completed` file with no envelope means the hand-off itself failed. Neither being present
means the run is gone, which is the original bug.

---

## Section C — Apple Health (2 min)

Separate from the phone app: this is T-107, and it is a different write.

| # | Do | Record |
|---|---|---|
| C.1 | iPhone → **Health** → Browse → Activity → Workouts. Find today's run. | Present? Y / N |
| C.2 | Open it. Is there a **map**? | Y / N |
| C.3 | Is the source **OptimalRunner**? | Y / N |

> C.2 is the one that has never worked. Both watch tiers requested route-write permission
> from the day they were written and never wrote a route, so every run this app has saved to
> Health has been mapless.

---

## Section D — the durability property (optional, 5 min)

Only if B passed and you want the stronger result.

| # | Do | Record |
|---|---|---|
| D.1 | Turn the phone **off**. Do a short run (2–3 min) and end it normally. | — |
| D.2 | Without turning the phone on, check the watch app still starts a new run normally. | Y / N |
| D.3 | Turn the phone on. Open the app. Wait 2 minutes. | Short run appeared? Y / N |

D.3 passing is the real claim: **a run is safe the moment it ends, not the moment it
arrives.**

---

## Recording sheet

```
0.1 runs in list before:  ___
A.4 watch distance/time:  ___ mi / ___

B.2 appeared on phone?    Y / N   after ___ s
B.4 distance matches?     Y / N   phone: ___
B.5 duration matches?     Y / N
B.6 heart rate present?   Y / N
B.7 route/map correct?    Y / N
B.8 splits present?       Y / N

C.1 workout in Health?    Y / N
C.2 map in Health?        Y / N

D.3 phone-off run synced? Y / N
```

---

## What this cannot close

| Question | Why not |
|---|---|
| Whether a *second* run overwrites the first | Needs two runs; ingest idempotency is covered by `IngestTests` on the phone side, but two real runs in one day is the honest check |
| Behaviour when the phone rejects a payload | The nack path is tested against fakes; producing a genuine rejection on hardware means corrupting a payload deliberately |
| Battery cost of holding a queue | Too small to measure over one outing |
