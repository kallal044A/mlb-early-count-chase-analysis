# Validation notes

A review of the original analysis found and fixed the following. All results in this repository come from the corrected script.

## Fixes

- **Leakage in the rankings.** Eligibility (at least 40 pitches), observed rates and the output files used full-season counts, including the August-September test period. They now use March-July pitches only. Test-period rates appear only in clearly named validation columns (`TestOpportunities`, `TestRate`), and the script checks the date boundary.
- **Penalty grid.** The base model's best penalty sat at the edge of the original grid. The grid now runs from 1e-1 to 1e-7. The base model still prefers the weakest penalty, which is expected with few parameters and a large sample.
- **Standardization.** glmnet's internal standardization under-penalized sparse hitter-count cells. It is now off, with numeric covariates z-scored manually from development-period statistics. With this change the hitter-count model beats the pitch-only model on held-out data (log-loss 0.467 versus 0.475). Before, it did not (0.479 versus 0.475).
- **Reproducibility.** Removed `install.packages()` and an unused random seed, defined the swing events unconditionally, named the constants (zone half-width, split dates, minimum pitches), saved session information, and updated the methodology notes.
- **Plot.** The calibration chart now uses axis limits that fit the data.

## Independent checks

- No duplicate pitches; no missing values in the fields used; every swing description in the data is covered.
- The held-out calibration of top-ranked cells, a comparison against raw chase-rate lists, and the sensitivity to the 40, 60 and 100 pitch cutoffs are in `chase_report.qmd`.

## Still open

- No hitter-level main effect, pitcher adjustment, or handedness-aware location term.
- Pitch-type and location-specific tendencies, and outcomes after the swing, are not modeled.
- The held-out results were seen while refining the penalty settings, so the August-September check is retrospective.
