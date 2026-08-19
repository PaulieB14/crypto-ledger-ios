# Appeal draft — App Review Board

**Do not send this until the corrected build has been on your own phone for a few
days.** The whole argument rests on "the changes are real and I have used them";
that sentence has to be true when you write it.

**Where to submit:** App Store Connect → the rejected submission → *Reply to App
Review*, or the App Review Board appeal form. The Board is the only channel that
gets a human to reconsider a suspended app record.

**Register:** this is a remediation statement, not a dispute. Apple's own Code of
Conduct language is *"you may provide a written statement detailing the
improvements you plan to make."* Do not argue the review was unfair — the build
they saw did contain the problems below, and claiming otherwise costs you the
credibility the rest of the letter depends on.

**Before sending, fill in:** the build number containing the fixes, and how long
you have been running it.

---

Subject: Appeal — Argus Crypto Tracker, submission 0082c87d-c74b-4b87-9780-25f4c78fa090

Hello,

Argus Crypto Tracker (version 1.0, build 17) was rejected under guideline 5.6
and made ineligible for resubmission. I am not writing to dispute that decision.
I went back through the build as a reviewer would see it, found specific
problems that justified it, and have fixed them. I am asking whether the
corrected build can be reviewed.

**What was wrong with the build you saw**

1. **It opened on an empty form.** The first screen asked the user to type in
   holdings before the app displayed anything. A reviewer who did not enter a
   portfolio never saw the product work.

2. **It shipped fabricated data.** Two taps from launch loaded invented
   holdings: a "Preview with sample data" button, and a "Sample" button in the
   CSV importer that filled the import buffer with five made-up 2024 trades.

3. **Price failures were invisible.** Every failed network call returned an
   empty result, so a rate-limited or offline device showed a $0 portfolio with
   no explanation rather than an error.

4. **The privacy policy URL was not reachable**, and the App Review Information
   Notes field was submitted empty.

**What has changed**

1. **The app now works with zero input.** It opens on live market prices for the
   largest coins by market cap. Tapping any coin opens the add-holding sheet
   pre-filled with that asset.

2. **Every path to fabricated data is gone.** No sample portfolio, no invented
   transactions. The CSV helper inserts only the column header, with the
   expected format shown as read-only help.

3. **Failures are visible and recoverable.** Network errors are typed and
   surfaced in the UI with a Retry control. The app also falls back to a second,
   keyless price provider and caches the last good prices to disk, so a device
   on a shared or rate-limited network still opens on a live market instead of
   an empty screen.

4. **Both URLs are live** — privacy policy and support — and the Notes field now
   describes the app's concept, its business model (free, no accounts, no
   purchases), and a step-by-step path through the full experience.

I also corrected two things that overstated what the app does: the price-alert
copy claimed notifications arrive "even when Argus is closed," which
misrepresents how iOS schedules background refresh, and sub-dollar prices were
rounded to two decimals so a coin worth $0.0149 displayed as "$0.01."

The corrected build is build ____, which I have been running on my own device
for ____ days.

I understand this app version cannot be resubmitted. If the corrected build can
be reviewed under this record, please let me know how to proceed. If it cannot,
I would appreciate confirmation of the right path forward, and whether anything
above still falls short of the standard — I would rather fix it than submit
something that wastes your reviewers' time.

Thank you,
Paul Barba
