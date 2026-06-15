# =============================================================================
# Revenue Opportunity Model
# Uses route-level elasticity estimates to compute optimal fare and
# modeled revenue delta vs. current pricing.
#
# Framework:
#   Revenue = Fare × Passengers
#   Passengers(F') = Passengers(F) × (F'/F)^ε   [arc-elasticity demand shift]
#   Optimal fare (revenue-max): F* = F × ε/(ε+1) when ε < -1
#   Revenue delta: ΔRev = Rev(F*) - Rev(F)
# =============================================================================

library(arrow)
library(dplyr)
library(tidyr)
library(readr)
library(ggplot2)
library(scales)

DATA_DIR <- file.path("..", "data", "output")
OUT_DIR  <- file.path("..", "data", "output")
PLOT_DIR <- file.path("..", "data", "output", "plots")

FARE_STEPS <- c(-0.20, -0.15, -0.10, -0.05, 0, 0.05, 0.10, 0.15, 0.20)

# ---------------------------------------------------------------------------
# 1. Load inputs
# ---------------------------------------------------------------------------
elasticities <- read_csv(file.path(DATA_DIR, "elasticity_estimates.csv"),
                         show_col_types = FALSE)

panel_raw    <- arrow::read_parquet(file.path(DATA_DIR, "model_ready.parquet"))

# Most recent quarter per route × fare_tier as current baseline
current_baseline <- panel_raw %>%
  group_by(route, fare_tier) %>%
  slice_max(order_by = time_idx, n = 1) %>%
  ungroup() %>%
  select(route, fare_tier, current_fare = avg_fare,
         current_pax = total_passengers, ulcc_share,
         Year, Quarter)

# ---------------------------------------------------------------------------
# 2. Merge elasticities onto baseline
# ---------------------------------------------------------------------------
model_df <- elasticities %>%
  filter(elasticity_sig) %>%            # only statistically significant routes
  select(route, fare_tier, elasticity, elasticity_lo, elasticity_hi,
         avg_fare_level, n_obs) %>%
  inner_join(current_baseline, by = c("route", "fare_tier")) %>%
  filter(
    is.finite(elasticity),
    elasticity < 0,                     # demand curves slope down
    current_fare > 0,
    current_pax > 0
  )

cat("Routes with valid elasticity + baseline:", nrow(model_df), "\n")

# ---------------------------------------------------------------------------
# 3. Revenue-maximizing optimal fare
#    Derived from dRev/dF = 0:  F* = -1/ε × (MC = 0 assumption)
#    Practical: F* = F_current × ε/(ε+1)  when |ε| > 1
#    For inelastic routes (|ε| < 1): raise fare until |ε| = 1
#    Cap fare changes at ±30% to stay within realistic pricing bands
# ---------------------------------------------------------------------------
compute_optimal_fare <- function(fare, elasticity, cap = 0.30) {
  if (elasticity > -1) {
    # Inelastic: raise fare — optimal is at unit elasticity (boundary)
    # Use +cap as ceiling for conservative estimate
    optimal_pct_change <- cap
  } else {
    # Elastic: revenue-maximizing fare from MR = 0 condition
    # F* = F × |ε| / (|ε| - 1)
    abs_e <- abs(elasticity)
    ratio  <- abs_e / (abs_e - 1)
    optimal_pct_change <- ratio - 1
    optimal_pct_change <- max(-cap, min(cap, optimal_pct_change))
  }
  fare * (1 + optimal_pct_change)
}

# Demand response to fare change: arc elasticity
demand_response <- function(pax, elasticity, fare_new, fare_old) {
  fare_ratio <- fare_new / fare_old
  pax * (fare_ratio ^ elasticity)
}

model_df <- model_df %>%
  rowwise() %>%
  mutate(
    optimal_fare   = compute_optimal_fare(current_fare, elasticity),
    fare_change_pct = (optimal_fare - current_fare) / current_fare,
    optimal_pax    = demand_response(current_pax, elasticity, optimal_fare, current_fare),
    # Bound pax to physically plausible range (not below 10% of current, not > 3x)
    optimal_pax    = pmax(current_pax * 0.1, pmin(current_pax * 3, optimal_pax)),
    current_rev    = current_fare * current_pax,
    optimal_rev    = optimal_fare * optimal_pax,
    rev_delta      = optimal_rev - current_rev,
    rev_delta_pct  = rev_delta / current_rev,
    recommendation = case_when(
      abs(fare_change_pct) < 0.02 ~ "Hold",
      fare_change_pct > 0         ~ "Raise Fare",
      fare_change_pct < 0         ~ "Lower Fare"
    )
  ) %>%
  ungroup()

# ---------------------------------------------------------------------------
# 4. Fare sensitivity curve: revenue at each ±20% fare step
# ---------------------------------------------------------------------------
sensitivity_long <- model_df %>%
  select(route, fare_tier, current_fare, current_pax, elasticity) %>%
  crossing(fare_step = FARE_STEPS) %>%
  mutate(
    test_fare    = current_fare * (1 + fare_step),
    test_pax     = demand_response(current_pax, elasticity, test_fare, current_fare),
    test_rev     = test_fare * test_pax,
    base_rev     = current_fare * current_pax,
    rev_index    = test_rev / base_rev   # 1.0 = current revenue
  )

# ---------------------------------------------------------------------------
# 5. Route-level opportunity summary (Power BI input)
# ---------------------------------------------------------------------------
opportunity_summary <- model_df %>%
  arrange(desc(rev_delta)) %>%
  mutate(
    opportunity_tier = case_when(
      rev_delta > quantile(rev_delta, 0.75) ~ "High",
      rev_delta > quantile(rev_delta, 0.25) ~ "Medium",
      TRUE                                   ~ "Low"
    )
  ) %>%
  select(
    route, fare_tier, Year, Quarter,
    current_fare, optimal_fare, fare_change_pct,
    current_pax, optimal_pax,
    current_rev, optimal_rev, rev_delta, rev_delta_pct,
    elasticity, elasticity_lo, elasticity_hi,
    ulcc_share, n_obs,
    recommendation, opportunity_tier
  )

# ---------------------------------------------------------------------------
# 6. Write outputs
# ---------------------------------------------------------------------------
write_csv(opportunity_summary,
          file.path(OUT_DIR, "revenue_opportunities.csv"))

write_csv(sensitivity_long,
          file.path(OUT_DIR, "fare_sensitivity_curves.csv"))

cat("\nTotal modeled revenue uplift: $",
    format(sum(opportunity_summary$rev_delta, na.rm = TRUE), big.mark = ",", digits = 2),
    "\n")
cat("Routes with 'Raise Fare' recommendation:",
    sum(opportunity_summary$recommendation == "Raise Fare"), "\n")
cat("Routes with 'Lower Fare' recommendation:",
    sum(opportunity_summary$recommendation == "Lower Fare"), "\n")

# ---------------------------------------------------------------------------
# 7. Plots
# ---------------------------------------------------------------------------

# 7a. Revenue opportunity waterfall by fare tier
p3 <- opportunity_summary %>%
  group_by(fare_tier, recommendation) %>%
  summarise(total_rev_delta = sum(rev_delta, na.rm = TRUE), .groups = "drop") %>%
  ggplot(aes(x = reorder(fare_tier, total_rev_delta), y = total_rev_delta / 1e6,
             fill = recommendation)) +
  geom_col(position = "dodge") +
  scale_y_continuous(labels = dollar_format(suffix = "M")) +
  coord_flip() +
  labs(
    title = "Modeled Revenue Opportunity by Fare Tier",
    subtitle = "Quarterly revenue delta vs. current pricing",
    x = "Fare Tier", y = "Revenue Opportunity ($M)", fill = "Action"
  ) +
  scale_fill_manual(values = c("Raise Fare" = "#2166ac", "Lower Fare" = "#d73027", "Hold" = "#999999")) +
  theme_minimal(base_size = 12)

ggsave(file.path(PLOT_DIR, "revenue_opportunity_by_tier.png"), p3, width = 10, height = 6)

# 7b. Top 20 route opportunities
p4 <- opportunity_summary %>%
  slice_max(abs(rev_delta), n = 20) %>%
  mutate(label = paste0(route, "\n(", fare_tier, ")")) %>%
  ggplot(aes(x = reorder(label, rev_delta), y = rev_delta / 1000,
             fill = recommendation)) +
  geom_col() +
  coord_flip() +
  scale_y_continuous(labels = dollar_format(suffix = "K")) +
  scale_fill_manual(values = c("Raise Fare" = "#2166ac", "Lower Fare" = "#d73027", "Hold" = "#999999")) +
  labs(
    title    = "Top 20 Route Revenue Opportunities",
    subtitle = "Quarterly delta; based on fare elasticity model",
    x = NULL, y = "Revenue Delta (K/quarter)", fill = "Action"
  ) +
  theme_minimal(base_size = 11)

ggsave(file.path(PLOT_DIR, "top20_route_opportunities.png"), p4, width = 10, height = 9)

# 7c. Elasticity vs. revenue opportunity scatter
p5 <- opportunity_summary %>%
  filter(elasticity >= -4 & elasticity <= 0, rev_delta_pct >= -0.5 & rev_delta_pct <= 0.5) %>%
  ggplot(aes(x = elasticity, y = rev_delta_pct, color = fare_tier, size = current_rev / 1e3)) +
  geom_point(alpha = 0.6) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  geom_vline(xintercept = -1, linetype = "dashed", color = "red") +
  scale_y_continuous(labels = percent) +
  scale_color_brewer(palette = "Set1") +
  labs(
    title    = "Price Elasticity vs. Revenue Uplift Potential",
    subtitle = "Bubble size = current quarterly revenue | Red line = unit elasticity",
    x        = "Fare Elasticity",
    y        = "Modeled Revenue Change (%)",
    color    = "Fare Tier",
    size     = "Current Rev ($K)"
  ) +
  theme_minimal(base_size = 12)

ggsave(file.path(PLOT_DIR, "elasticity_vs_revenue_delta.png"), p5, width = 11, height = 7)

cat("\n=== Revenue Opportunity Model Complete ===\n")
cat("Outputs:\n")
cat("  - revenue_opportunities.csv   (route-level RM actions)\n")
cat("  - fare_sensitivity_curves.csv (scenario analysis input for Power BI)\n")
