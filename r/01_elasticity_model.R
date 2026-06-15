# =============================================================================
# Airline Fare Elasticity Model
# Spec: log-log panel OLS with route × fare-tier fixed effects + time FE
# Output: elasticity_estimates.csv, model_diagnostics.csv
# =============================================================================

library(arrow)        # read parquet
library(dplyr)
library(tidyr)
library(plm)          # panel data models
library(lmtest)       # coeftest
library(sandwich)     # clustered SEs
library(broom)        # tidy model output
library(ggplot2)
library(readr)

# Paths
DATA_DIR  <- file.path("..", "data", "output")
OUT_DIR   <- file.path("..", "data", "output")
PLOT_DIR  <- file.path("..", "data", "output", "plots")
dir.create(PLOT_DIR, showWarnings = FALSE)

# ---------------------------------------------------------------------------
# 1. Load data
# ---------------------------------------------------------------------------
panel_raw <- arrow::read_parquet(file.path(DATA_DIR, "model_ready.parquet"))

cat("Panel dimensions:", nrow(panel_raw), "x", ncol(panel_raw), "\n")
cat("Routes:", n_distinct(panel_raw$route), "\n")
cat("Fare tiers:", paste(unique(panel_raw$fare_tier), collapse = ", "), "\n")

# ---------------------------------------------------------------------------
# 2. Prepare panel data frame (plm pdata.frame)
# panel_id = route × fare_tier entity; time_idx = quarter index (1–12)
# ---------------------------------------------------------------------------
panel_df <- panel_raw %>%
  filter(
    is.finite(log_avg_fare),
    is.finite(log_passengers),
    total_passengers >= 1
  ) %>%
  mutate(
    panel_id = factor(panel_id),
    time_idx = as.integer(time_idx),
    Quarter  = factor(Quarter)
  )

pdata <- pdata.frame(panel_df, index = c("panel_id", "time_idx"), drop.index = FALSE)

# ---------------------------------------------------------------------------
# 3. Model specifications
#
# M1 (pooled OLS)       — baseline, no FE
# M2 (within / FE)      — route×fare_tier entity FE + time FE
# M3 (within + ULCC)    — M2 + ULCC competition interaction
# M4 (within + tier FE) — M3 + fare-tier dummies (for cross-tier comparison)
# ---------------------------------------------------------------------------

# Helper: cluster-robust SEs at route level
clust_se <- function(model, cluster_var) {
  coeftest(model, vcov = vcovHC(model, type = "HC1", cluster = "group"))
}

cat("\nFitting M1: Pooled OLS...\n")
m1 <- plm(
  log_passengers ~ log_avg_fare + log_distance + q2 + q3 + q4 + ulcc_competition,
  data   = pdata,
  model  = "pooling"
)

cat("Fitting M2: Within (FE) model...\n")
m2 <- plm(
  log_passengers ~ log_avg_fare + q2 + q3 + q4 + ulcc_competition,
  data   = pdata,
  model  = "within",
  effect = "twoways"   # entity FE + time FE
)

cat("Fitting M3: Within + ULCC interaction...\n")
m3 <- plm(
  log_passengers ~ log_avg_fare + log_avg_fare:ulcc_intensity +
    q2 + q3 + q4 + ulcc_competition,
  data   = pdata,
  model  = "within",
  effect = "twoways"
)

cat("Fitting M4: Within + fare-tier interactions...\n")
# Interact fare with fare tier to get tier-specific elasticities
m4 <- plm(
  log_passengers ~ log_avg_fare * fare_tier +
    q2 + q3 + q4 + ulcc_competition + ulcc_intensity,
  data   = pdata,
  model  = "within",
  effect = "twoways"
)

# ---------------------------------------------------------------------------
# 4. Hausman test: confirm FE preferred over RE
# ---------------------------------------------------------------------------
cat("\nRunning Hausman test (FE vs RE)...\n")
m2_re <- plm(
  log_passengers ~ log_avg_fare + q2 + q3 + q4 + ulcc_competition,
  data   = pdata,
  model  = "random"
)
hausman <- phtest(m2, m2_re)
cat("Hausman p-value:", round(hausman$p.value, 4),
    "→", ifelse(hausman$p.value < 0.05, "FE preferred ✓", "RE preferred"), "\n")

# ---------------------------------------------------------------------------
# 5. Route-level elasticity via individual OLS regressions
#    Gives per-route elasticity with 95% CI — the core output for RM decisions
# ---------------------------------------------------------------------------
cat("\nEstimating route-level elasticities...\n")

route_elasticities <- panel_df %>%
  group_by(route, fare_tier) %>%
  filter(n() >= 6) %>%   # need ≥6 obs for reliable estimate
  group_modify(function(data, key) {
    tryCatch({
      fit <- lm(log_passengers ~ log_avg_fare + q2 + q3 + q4 + ulcc_competition,
                data = data)
      tidy_fit <- tidy(fit, conf.int = TRUE) %>%
        filter(term == "log_avg_fare") %>%
        mutate(
          n_obs          = nrow(data),
          avg_fare_level = mean(data$avg_fare, na.rm = TRUE),
          avg_pax        = mean(data$total_passengers, na.rm = TRUE),
          ulcc_share     = mean(data$ulcc_share, na.rm = TRUE)
        )
      tidy_fit
    }, error = function(e) tibble())
  }) %>%
  ungroup() %>%
  rename(
    elasticity    = estimate,
    elasticity_se = std.error,
    elasticity_lo = conf.low,
    elasticity_hi = conf.high,
    p_value       = p.value
  ) %>%
  mutate(
    elasticity_sig = p_value < 0.05,
    demand_type    = case_when(
      elasticity > -1  ~ "Inelastic (raise fare)",
      elasticity < -1  ~ "Elastic (lower fare)",
      TRUE             ~ "Unit elastic"
    )
  ) %>%
  arrange(elasticity)

cat("Route-fare_tier combinations estimated:", nrow(route_elasticities), "\n")
cat("Significant (p<0.05):", sum(route_elasticities$elasticity_sig, na.rm = TRUE), "\n")

# ---------------------------------------------------------------------------
# 6. Global elasticity summary by fare tier (from M4)
# ---------------------------------------------------------------------------
m4_coef <- coeftest(m4, vcov = vcovHC(m4, type = "HC1", cluster = "group"))

m4_coef_df <- as.data.frame(unclass(m4_coef))
m4_coef_df$term <- rownames(m4_coef_df)
rownames(m4_coef_df) <- NULL
colnames(m4_coef_df) <- c("estimate", "se", "t_stat", "p_val", "term")

tier_elasticities <- m4_coef_df[grepl("log_avg_fare", m4_coef_df$term), ]

base_elas <- tier_elasticities$estimate[tier_elasticities$term == "log_avg_fare"]
tier_summary <- tier_elasticities
tier_summary$fare_tier_label <- gsub("log_avg_fare:fare_tier", "", tier_summary$term)
tier_summary$fare_tier_label[tier_summary$fare_tier_label == "log_avg_fare"] <- "Coach_Discount (base)"
tier_summary$total_elasticity <- ifelse(
  tier_summary$fare_tier_label == "Coach_Discount (base)",
  tier_summary$estimate,
  tier_summary$estimate + base_elas
)

# ---------------------------------------------------------------------------
# 7. Write outputs
# ---------------------------------------------------------------------------
write_csv(route_elasticities,
          file.path(OUT_DIR, "elasticity_estimates.csv"))

write_csv(tier_summary,
          file.path(OUT_DIR, "tier_elasticity_summary.csv"))

# Model comparison table
model_summary <- bind_rows(
  glance(m1) %>% mutate(model = "M1_Pooled_OLS"),
  glance(m2) %>% mutate(model = "M2_Within_FE"),
  glance(m3) %>% mutate(model = "M3_Within_ULCC"),
  glance(m4) %>% mutate(model = "M4_Within_TierInteraction")
) %>%
  select(model, r.squared, adj.r.squared, statistic, p.value, df.residual)

write_csv(model_summary, file.path(OUT_DIR, "model_diagnostics.csv"))

# ---------------------------------------------------------------------------
# 8. Diagnostic plots
# ---------------------------------------------------------------------------

# 8a. Distribution of route-level elasticities by fare tier
p1 <- route_elasticities %>%
  filter(elasticity_sig) %>%
  ggplot(aes(x = elasticity, fill = fare_tier)) +
  geom_histogram(bins = 40, alpha = 0.7, color = "white") +
  geom_vline(xintercept = -1, linetype = "dashed", color = "red", linewidth = 0.8) +
  facet_wrap(~fare_tier, scales = "free_y") +
  labs(
    title    = "Distribution of Fare Elasticities by Fare Tier",
    subtitle = "Red dashed line = unit elasticity threshold | Significant estimates only",
    x        = "Fare Elasticity (log-log)",
    y        = "Count of Routes",
    fill     = "Fare Tier"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")

ggsave(file.path(PLOT_DIR, "elasticity_distribution.png"), p1, width = 12, height = 7)

# 8b. Elasticity vs. ULCC share scatter
p2 <- route_elasticities %>%
  filter(elasticity_sig, elasticity >= -4 & elasticity <= 0) %>%
  ggplot(aes(x = ulcc_share, y = elasticity, color = fare_tier, size = avg_pax)) +
  geom_point(alpha = 0.6) +
  geom_smooth(method = "lm", se = FALSE, color = "black", linewidth = 0.8) +
  geom_hline(yintercept = -1, linetype = "dashed", color = "red") +
  scale_x_continuous(labels = scales::percent) +
  labs(
    title    = "Fare Elasticity vs. ULCC Competition",
    subtitle = "Bubble size = avg quarterly passengers",
    x        = "ULCC Carrier Share on Route",
    y        = "Fare Elasticity",
    color    = "Fare Tier"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "right")

ggsave(file.path(PLOT_DIR, "elasticity_vs_ulcc.png"), p2, width = 10, height = 7)

cat("\n=== Elasticity Model Complete ===\n")
cat("Outputs written to:", OUT_DIR, "\n")
cat("Plots written to:", PLOT_DIR, "\n")
print(model_summary)
