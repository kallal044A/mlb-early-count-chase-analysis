# 2025 MLB early-count chase analysis
# Requires an existing object: statcast_2025 (regular-season Statcast pitches).
# If starting a new R session, uncomment the data-loading section below.
# Outputs are saved to out_dir, relative to the CURRENT WORKING DIRECTORY
# (set it to the project folder first, or set the CHASE_OUT_DIR environment variable).

# ---------- 0. Packages, constants and input ----------
needed <- c('dplyr','tidyr','ggplot2','readr','Matrix','glmnet','tibble')
missing_pkgs <- setdiff(needed, rownames(installed.packages()))
if (length(missing_pkgs))
  stop('Install required packages first: ', paste(missing_pkgs, collapse=', '))
invisible(lapply(needed, library, character.only = TRUE))
out_dir <- Sys.getenv('CHASE_OUT_DIR', 'chase_analysis_outputs')
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# Analysis constants
PLATE_HALF_WIDTH_FT <- 0.83          # approximate horizontal strike-zone half-width
VALIDATION_START    <- as.Date('2025-07-01')
TEST_START          <- as.Date('2025-08-01')
MIN_TRAINING_PITCHES <- 40           # minimum March-July pitches per hitter-count cell

# Uncomment if statcast_2025 does not exist in the current R session:
# daily_files <- list.files('statcast_2025_daily', pattern='\\.csv$', full.names=TRUE)
# stopifnot(length(daily_files) > 0)
# statcast_2025 <- dplyr::bind_rows(lapply(daily_files, function(f)
#   readr::read_csv(f, show_col_types=FALSE))) |>
#   dplyr::filter(game_type == 'R')

if (!exists('statcast_2025')) stop('Load statcast_2025 first; see commented data-loading block.')
# Defined unconditionally so a stale object in the session cannot change the outcome.
# Hit-by-pitch is deliberately NOT a swing.
swing_events <- c('swinging_strike','swinging_strike_blocked','foul',
                  'foul_tip','foul_bunt','bunt_foul_tip','missed_bunt','hit_into_play')

# ---------- 1. Consistent eligibility and pitch-level features ----------
# Statcast zones 11-14 indicate outside the zone. The geometric distance
# below is an approximate covariate, NOT an official strike-zone measurement.
raw <- statcast_2025 |>
  filter(game_type == 'R', strikes < 2, zone %in% 11:14,
         !description %in% c('automatic_ball','automatic_strike','pitchout'),
         !is.na(plate_x), !is.na(plate_z), !is.na(sz_top),
         !is.na(sz_bot), !is.na(pitch_type), !is.na(release_speed),
         !is.na(batter), !is.na(pitcher), !is.na(game_date)) |>
  mutate(
    Chase = as.integer(description %in% swing_events),
    Count = paste0(balls, '-', strikes),
    batter = as.character(batter),
    pitcher = as.character(pitcher),
    pitch_type = as.character(pitch_type),
    PitchGroup = if_else(pitch_type %in%
      c('FF','SI','FC','SL','ST','CH','CU','FS','KC'), pitch_type, 'Other'),
    HorizontalOutside = pmax(abs(plate_x) - PLATE_HALF_WIDTH_FT, 0),
    VerticalOutside = pmax(sz_bot - plate_z, plate_z - sz_top, 0),
    DistanceOutside = sqrt(HorizontalOutside^2 + VerticalOutside^2),
    game_date = as.Date(game_date)
  ) |>
  filter(!pitch_type %in% c('PO','UN'),
         is.finite(DistanceOutside), is.finite(release_speed),
         !is.na(stand), !is.na(p_throws))

# Fix levels before splitting so train/test design matrices align.
count_levels <- c('0-0','0-1','1-0','1-1','2-0','2-1','3-0','3-1')
raw <- raw |>
  mutate(Count = factor(Count, levels=count_levels),
         PitchGroup = factor(PitchGroup),
         stand = factor(stand), p_throws = factor(p_throws),
         batter = factor(batter)) |>
  filter(!is.na(Count))
stopifnot(nrow(raw) > 100000, all(raw$Chase %in% c(0,1)))

# March-June model development; July validation; Aug-Sep final holdout.
raw <- raw |>
  mutate(Split = case_when(
    game_date < VALIDATION_START ~ 'development',
    game_date < TEST_START ~ 'validation',
    TRUE ~ 'test'))
split_summary <- raw |>
  group_by(Split) |>
  summarise(Pitches=n(), ChaseRate=mean(Chase),
            Batters=n_distinct(batter), Games=n_distinct(game_pk), .groups='drop')
print(split_summary)
write_csv(split_summary, file.path(out_dir,'sample_and_splits.csv'))

# ---------- 2. Descriptive count-level rates ----------
count_summary <- raw |>
  group_by(Count) |>
  summarise(OutsidePitches=n(), Chases=sum(Chase),
            ChaseRate=mean(Chase), .groups='drop')
write_csv(count_summary, file.path(out_dir,'league_chase_by_count.csv'))


# ---------- 3. Design matrices: league context and regularized hitter-by-count ----------
# The ridge model estimates partially shrunk hitter-by-count coefficients.
# This is REGULARIZED logistic regression, not a fully hierarchical GLMM.
# Ridge shrinks sparse hitter-count cells, mitigating noisy raw rankings.
base_formula <- ~ Count + DistanceOutside + I(DistanceOutside^2) +
  PitchGroup + release_speed + stand + p_throws
full_formula <- ~ Count + DistanceOutside + I(DistanceOutside^2) +
  PitchGroup + release_speed + stand + p_throws + batter:Count

cat('Building sparse matrices...\n')
X_base <- Matrix::sparse.model.matrix(base_formula, data=raw)
X_full <- Matrix::sparse.model.matrix(full_formula, data=raw)
# glmnet includes its own intercept. Remove the design-matrix intercept.
X_base <- X_base[, colnames(X_base) != '(Intercept)', drop=FALSE]
X_full <- X_full[, colnames(X_full) != '(Intercept)', drop=FALSE]

idx_dev <- which(raw$Split == 'development')
idx_val <- which(raw$Split == 'validation')
idx_train <- which(raw$Split != 'test')
idx_test <- which(raw$Split == 'test')
train <- raw[idx_train,]
test <- raw[idx_test,]

# Training-only hitter-count rates (March-July); no test-period outcomes.
observed <- train |>
  group_by(batter, Count) |>
  summarise(TrainingOpportunities=n(), TrainingChases=sum(Chase),
            TrainingRate=mean(Chase), .groups='drop')
y <- raw$Chase
stopifnot(length(idx_dev)>0, length(idx_val)>0, length(idx_test)>0)

# Manual scaling of numeric covariates (development-period mean/sd; reused for reference rows).
num_cols <- c('DistanceOutside','I(DistanceOutside^2)','release_speed')
num_scale <- sapply(num_cols, function(cn) c(mu=mean(X_full[idx_dev,cn]), sd=sd(X_full[idx_dev,cn])))
apply_scale <- function(X) {
  for (cn in num_cols) X[,cn] <- (X[,cn]-num_scale['mu',cn])/num_scale['sd',cn]
  X
}
X_base <- apply_scale(X_base); X_full <- apply_scale(X_full)

# A single penalty grid shared across both models, tuned on July only (wide enough to bracket optima).
# standardize=FALSE keeps ridge shrinkage equal across indicator columns (sparse cells are not under-penalized);
# numeric covariates are z-scored manually below using development-period statistics.
lambdas <- exp(seq(log(0.1), log(1e-7), length.out=45))
cat('Fitting development-period ridge models...\n')
fit_base_dev <- glmnet::glmnet(X_base[idx_dev,,drop=FALSE], y[idx_dev],
  family='binomial', alpha=0, lambda=lambdas, standardize=FALSE,
  control=list(maxit=100000))
fit_full_dev <- glmnet::glmnet(X_full[idx_dev,,drop=FALSE], y[idx_dev],
  family='binomial', alpha=0, lambda=lambdas, standardize=FALSE,
  control=list(maxit=100000))

clip <- function(p) pmin(pmax(as.numeric(p), 1e-12), 1-1e-12)
logloss <- function(actual, predicted) {
  p <- clip(predicted)
  -mean(actual*log(p) + (1-actual)*log1p(-p))
}
brier <- function(actual, predicted) mean((actual-as.numeric(predicted))^2)

# glmnet predict with s=lambda vector returns a matrix (rows=pitches, columns=lambdas).
val_base <- predict(fit_base_dev, newx=X_base[idx_val,,drop=FALSE],
                    s=lambdas, type='response')
val_full <- predict(fit_full_dev, newx=X_full[idx_val,,drop=FALSE],
                    s=lambdas, type='response')
val_metrics <- bind_rows(
  tibble(Model='Pitch-adjusted ridge', Lambda=lambdas,
         LogLoss=apply(val_base, 2, function(p) logloss(y[idx_val],p)),
         Brier=apply(val_base, 2, function(p) brier(y[idx_val],p))),
  tibble(Model='Pitch + hitter-count ridge', Lambda=lambdas,
         LogLoss=apply(val_full, 2, function(p) logloss(y[idx_val],p)),
         Brier=apply(val_full, 2, function(p) brier(y[idx_val],p)))
)
write_csv(val_metrics, file.path(out_dir,'july_lambda_tuning.csv'))
selected <- val_metrics |>
  group_by(Model) |>
  slice_min(LogLoss, n=1, with_ties=FALSE) |>
  ungroup()
print(selected)
lambda_base <- selected$Lambda[selected$Model=='Pitch-adjusted ridge']
lambda_full <- selected$Lambda[selected$Model=='Pitch + hitter-count ridge']
# The base model has few parameters, so its validation curve is nearly flat and its optimum
# may sit at the weakest penalty (effectively unpenalized); only the hitter-count model matters here.
if (lambda_full %in% range(lambdas))
  warning('Hitter-count lambda is at the edge of the grid; consider extending it.')
if (lambda_base %in% range(lambdas))
  message('Note: base-model lambda is at the grid edge (effectively unpenalized).')

# ---------- 4. Refit through July; evaluate untouched Aug-Sep ----------
cat('Refitting selected models on March-July...\n')
fit_base <- glmnet::glmnet(X_base[idx_train,,drop=FALSE], y[idx_train],
  family='binomial', alpha=0, lambda=lambda_base,
  standardize=FALSE, control=list(maxit=100000))
fit_full <- glmnet::glmnet(X_full[idx_train,,drop=FALSE], y[idx_train],
  family='binomial', alpha=0, lambda=lambda_full,
  standardize=FALSE, control=list(maxit=100000))

# League rate must come from training only, not test outcomes.
p_league <- mean(y[idx_train])
pred_league <- rep(p_league, length(idx_test))
pred_base <- as.numeric(predict(fit_base,
  newx=X_base[idx_test,,drop=FALSE], type='response'))
pred_full <- as.numeric(predict(fit_full,
  newx=X_full[idx_test,,drop=FALSE], type='response'))

# Unseen hitters in Aug-Sep have columns but no trained coefficients;
# the model falls back to shared context effects for them.
test_metrics <- tibble(
  Model=c('Training league rate','Pitch-adjusted ridge','Pitch + hitter-count ridge'),
  N=length(idx_test),
  LogLoss=c(logloss(y[idx_test],pred_league),
            logloss(y[idx_test],pred_base), logloss(y[idx_test],pred_full)),
  Brier=c(brier(y[idx_test],pred_league),
          brier(y[idx_test],pred_base), brier(y[idx_test],pred_full))
) |>
  mutate(LogLossImprovementVsLeague=LogLoss[1]-LogLoss,
         BrierImprovementVsLeague=Brier[1]-Brier)
print(test_metrics)
write_csv(test_metrics, file.path(out_dir,'holdout_model_performance.csv'))

# Calibration bins for diagnostic visualization.
calibration <- tibble(Actual=y[idx_test], Predicted=pred_full) |>
  mutate(Bin=dplyr::ntile(Predicted, 10)) |>
  group_by(Bin) |>
  summarise(MeanPredicted=mean(Predicted), ObservedRate=mean(Actual),
            N=n(), .groups='drop')
write_csv(calibration, file.path(out_dir,'holdout_calibration.csv'))
p_cal <- ggplot(calibration, aes(MeanPredicted,ObservedRate)) +
  geom_abline(slope=1,intercept=0,linetype='dashed',color='grey50') +
  geom_point(size=2.5,color='#1f577a') + geom_line(color='#1f577a') +
  coord_equal(xlim=range(c(calibration$MeanPredicted,calibration$ObservedRate))+c(-0.02,0.02),
            ylim=range(c(calibration$MeanPredicted,calibration$ObservedRate))+c(-0.02,0.02)) +
  labs(title='2025 MLB: Held-out chase probability calibration',
       subtitle='August-September test pitches; ten equally sized prediction groups',
       x='Mean predicted chase probability',y='Observed chase rate') +
  theme_minimal(base_size=12)
ggsave(file.path(out_dir,'holdout_calibration.png'),p_cal,
       width=7,height=5,dpi=180)

# ---------- 5. Model-adjusted hitter/count rankings ----------
# IMPORTANT: Rankings use ONLY March-July pitches for fitting.
# Compare hitters on the SAME representative pitch context:
# median distance and speed; changeup; right-handed batter/pitcher.
# These are CONDITIONAL probabilities at a reference context, not
# season-wide marginal chase rates. They are not causal effects.
reference <- train[rep(1, length(levels(raw$batter))*length(count_levels)), ,drop=FALSE]
reference$batter <- factor(rep(levels(raw$batter),each=length(count_levels)),
                           levels=levels(raw$batter))
reference$Count <- factor(rep(count_levels,times=length(levels(raw$batter))),
                          levels=count_levels)
reference$DistanceOutside <- median(train$DistanceOutside)
reference$release_speed <- median(train$release_speed)
reference$PitchGroup <- factor('CH',levels=levels(raw$PitchGroup))
reference$stand <- factor('R',levels=levels(raw$stand))
reference$p_throws <- factor('R',levels=levels(raw$p_throws))
X_ref <- Matrix::sparse.model.matrix(full_formula, data=reference)
X_ref <- X_ref[, colnames(X_ref)!='(Intercept)', drop=FALSE]
# Ensure exact training matrix column order.
stopifnot(setequal(colnames(X_ref),colnames(X_full)))
X_ref <- X_ref[,colnames(X_full),drop=FALSE]
X_ref <- apply_scale(X_ref)
reference$AdjustedProbability <- as.numeric(predict(fit_full,
                                  newx=X_ref,type='response'))

# Comparison baseline: average of trained hitter estimates in each count,
# equally weighted by hitter (NOT an observed league-wide chase rate).
trained_batters <- unique(as.character(train$batter))
reference_summary <- reference |>
  filter(as.character(batter) %in% trained_batters) |>
  group_by(Count) |>
  summarise(ReferenceAverage=mean(AdjustedProbability), .groups='drop')

test_observed <- test |>
  group_by(batter,Count) |>
  summarise(TestOpportunities=n(), TestRate=mean(Chase), .groups='drop')

# Eligibility uses TRAINING counts only; test columns are validation-only.
rankings <- reference |>
  select(batter,Count,AdjustedProbability) |>
  left_join(reference_summary,by='Count') |>
  mutate(AdjustedDifferencePP=100*(AdjustedProbability-ReferenceAverage)) |>
  left_join(observed,by=c('batter','Count')) |>
  left_join(test_observed,by=c('batter','Count')) |>
  mutate(across(c(TrainingOpportunities,TrainingChases,TestOpportunities),
                \(v) coalesce(v,0L))) |>
  filter(as.character(batter) %in% trained_batters,
         TrainingOpportunities >= MIN_TRAINING_PITCHES) |>
  arrange(desc(AdjustedDifferencePP))
stopifnot(all(rankings$TrainingOpportunities >= MIN_TRAINING_PITCHES),
          max(train$game_date) < TEST_START,
          min(test$game_date) >= TEST_START)
write_csv(rankings, file.path(out_dir,'adjusted_hitter_count_rankings_ids.csv'))

# Player-name lookup: optional. Batch small requests to avoid API limits.
# If baseballr is not installed or MLB API fails, ID-based output still works.
name_lookup <- tibble(batter=character(), Player=character())
if (requireNamespace('baseballr',quietly=TRUE)) {
  ids <- unique(as.character(head(rankings$batter,100)))
  chunks <- split(ids, ceiling(seq_along(ids)/10))
  name_rows <- lapply(chunks, function(ids_chunk) {
    tryCatch({
      p <- baseballr::mlb_people(person_ids=as.integer(ids_chunk))
      if (is.null(p) || !all(c('id','full_name') %in% names(p))) return(NULL)
      tibble(batter=as.character(p$id),Player=as.character(p$full_name))
    }, error=function(e) NULL)
  })
  name_lookup <- bind_rows(name_rows) |> distinct(batter,.keep_all=TRUE)
}
rankings_named <- rankings |>
  left_join(name_lookup,by='batter') |>
  mutate(Player=if_else(is.na(Player),paste0('MLB ID ',batter),Player)) |>
  relocate(Player)
write_csv(rankings_named, file.path(out_dir,'adjusted_hitter_count_rankings.csv'))
print(head(rankings_named |>
  select(Player,Count,TrainingOpportunities,TrainingRate,
         AdjustedProbability,ReferenceAverage,AdjustedDifferencePP),20))

# ---------- 6. Training-only eligibility and figures ----------
# Define eligibility from data available when the model was fitted.
scouting_shortlist <- rankings_named |>
  filter(TrainingOpportunities>=MIN_TRAINING_PITCHES) |>
  arrange(desc(AdjustedDifferencePP))
write_csv(scouting_shortlist, file.path(out_dir,'scouting_shortlist_training_min40.csv'))

plot_top <- scouting_shortlist |> slice_head(n=20) |>
  mutate(Label=paste0(Player,' (',Count,')'),
         Label=factor(Label,levels=rev(unique(Label))))
p_top <- ggplot(plot_top,aes(x=AdjustedDifferencePP,y=Label)) +
  geom_col(fill='#b33b3b') +
  labs(title='2025 MLB: Model-adjusted early-count chase tendencies',
       subtitle=paste0('Top 20 hitter-count cells; >=',MIN_TRAINING_PITCHES,' March-July TRAINING opportunities'),
       x='Percentage points above equal-hitter reference average',y=NULL,
       caption='Reference-pitch estimates; exploratory, not validated player weaknesses') +
  theme_minimal(base_size=11)
ggsave(file.path(out_dir,'top20_adjusted_chase.png'),p_top,
       width=10,height=8,dpi=180)

heat_ids <- scouting_shortlist |> distinct(batter,.keep_all=TRUE) |>
  slice_head(n=20) |> pull(batter)
heat <- scouting_shortlist |> filter(batter %in% heat_ids) |>
  mutate(Player=factor(Player,levels=rev(unique(Player))))
p_heat <- ggplot(heat,aes(x=Count,y=Player,fill=AdjustedDifferencePP)) +
  geom_tile(color='white',linewidth=0.4) +
  geom_text(aes(label=sprintf('%+.1f',AdjustedDifferencePP)),size=3) +
  scale_fill_gradient2(low='#2166ac',mid='white',high='#b2182b',midpoint=0,
                       name='Adjusted\ndifference (pp)') +
  labs(title='Model-adjusted chase tendencies by hitter and count',
       subtitle=paste0('Cells shown only with >=',MIN_TRAINING_PITCHES,' March-July TRAINING opportunities'),
       x='Ball-strike count',y=NULL) +
  theme_minimal(base_size=11) + theme(panel.grid=element_blank())
ggsave(file.path(out_dir,'hitter_count_heatmap.png'),p_heat,
       width=11,height=8,dpi=180)

# ---------- 7. Robustness / reporting ----------
# Data audit and interpretation notes.
notes <- c(
  '2025 MLB early-count chase analysis',
  paste('Eligible pitches:',nrow(raw)),
  'Outcome: swing on Statcast zone 11-14, with fewer than two strikes.',
  'Exclude automatic events, pitchouts, unknown pitch types, and missing tracking fields.',
  paste0('DistanceOutside uses an approximate ',PLATE_HALF_WIDTH_FT,
         '-ft horizontal half-width and recorded vertical boundaries.'),
  paste0('Development: before ',VALIDATION_START,'; penalty tuning: ',VALIDATION_START,
         ' to ',TEST_START-1,'; final evaluation: ',TEST_START,' onward.'),
  'Baseline and hitter-count models: ridge-penalized logistic regression (glmnet, alpha=0).',
  'Penalty grid: 1e-1 to 1e-7 (45 values), tuned on validation log-loss. standardize=FALSE; numeric covariates z-scored with development-period statistics.',
  'Hitter-count coefficients are shrunk; this is not a full hierarchical mixed-effects model.',
  'The hitter-count model is predictive, not causal. Pitcher identity and sequencing are not adjusted.',
  'Rankings compare predictions for the same representative pitch context (CH, R/R, median speed/distance).',
  'Ranking reference is equal-weight average across training-period hitters, not observed league chase rate.',
  paste0('Rankings, eligibility (>=',MIN_TRAINING_PITCHES,' pitches) and observed rates use ONLY training-period pitches (before ',TEST_START,').'),
  paste0('Eligible hitter-count cells: ',nrow(rankings),' (',n_distinct(rankings$batter),' hitters).'),
  'TestOpportunities/TestRate columns are validation-only and are not used for fitting or eligibility.',
  'Selected top cells are extremes among many cells; estimates are optimistic even after shrinkage.',
  'No confidence intervals are claimed: ridge shrinkage is not a substitute for interval estimation.',
  'The August-September evaluation is retrospective: modelling choices were made with knowledge of the full season.',
  'Do not claim pitcher-adjusted or causal hitter vulnerability from this model.'
)
writeLines(notes,file.path(out_dir,'methodology_and_limitations.txt'))
writeLines(capture.output(sessionInfo()),file.path(out_dir,'session_info.txt'))
cat('\nDONE. See outputs in: ',normalizePath(out_dir),'\n',sep='')
cat('\nHoldout performance:\n'); print(test_metrics)
cat('\nTop scouting shortlist:\n'); print(head(scouting_shortlist,15))
