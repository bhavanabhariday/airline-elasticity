# Airline Fare Elasticity & Revenue Opportunity Model

Price sensitivity regression across 250 U.S. routes using DOT DB1B data (2022–2024),
with route-level fare elasticity estimates and modeled revenue uplift for RM decisions.

## Architecture

```
airline_elasticity/
├── python/
│   ├── 01_download_db1b.py       # BTS data downloader (Coupon + Ticket tables)
│   ├── 02_clean_pipeline.py      # Merge, filter, aggregate → db1b_panel.parquet
│   ├── 03_feature_engineering.py # Route selection, log transforms, panel IDs → model_ready.parquet
│   └── requirements.txt
├── r/
│   ├── install_packages.R        # One-time package setup
│   ├── 01_elasticity_model.R     # Panel FE regression, route-level elasticities
│   └── 02_revenue_opportunity.R  # Optimal fare, revenue delta, sensitivity curves
├── powerbi/
│   └── dax_measures.md           # Full DAX + data model + dashboard layout
└── data/
    ├── raw/                      # Downloaded BTS ZIPs/CSVs (gitignored)
    ├── processed/                # Intermediate parquets
    └── output/                   # Model outputs → Power BI inputs
        ├── elasticity_estimates.csv
        ├── revenue_opportunities.csv
        ├── fare_sensitivity_curves.csv
        ├── route_index.csv
        └── plots/
```

## Run Order

### 1. Python pipeline (~2–4 hrs for full download)
```bash
cd python
pip install -r requirements.txt
python 01_download_db1b.py      # Downloads 12 quarters × 2 tables from BTS
python 02_clean_pipeline.py     # Cleans and aggregates → db1b_panel.parquet
python 03_feature_engineering.py  # Route selection + features → model_ready.parquet
```

### 2. R modeling
```r
# In R or RStudio, set working directory to r/
source("install_packages.R")    # One-time
source("01_elasticity_model.R") # ~5–15 min depending on dataset size
source("02_revenue_opportunity.R")
```

### 3. Power BI
- Import `data/output/revenue_opportunities.csv`, `fare_sensitivity_curves.csv`, `route_index.csv`
- Follow `powerbi/dax_measures.md` for relationships, measures, and page layout

## Modeling Approach

| Decision | Choice | Reason |
|---|---|---|
| Specification | Log-log OLS | Coefficients = direct elasticity estimates |
| Panel structure | Route × fare_tier entity FE + time FE (two-way) | Controls route invariants + macro trends |
| Route selection | Top 250 by passenger volume | Revenue-weighted coverage for RM impact |
| Min observations | 6 quarters per route-tier | Stability of individual FE estimates |
| SE adjustment | Cluster-robust (group/route level) | Corrects within-route autocorrelation |
| ULCC effect | Interaction term (fare × ULCC intensity) | Captures competitive pricing pressure |
| Revenue optimum | MR=0 condition (F* = F×\|ε\|/(\|ε\|-1)) | Textbook revenue-maximizing price |
| Fare change cap | ±30% | Conservative; avoids revenue-management shock |

## Key Outputs

**`elasticity_estimates.csv`** — route × fare_tier elasticity with 95% CI, significance flag, demand type (elastic/inelastic), ULCC share.

**`revenue_opportunities.csv`** — current vs. optimal fare, passenger shift, quarterly revenue delta, recommendation (Raise/Lower/Hold), opportunity tier (High/Medium/Low).

**`fare_sensitivity_curves.csv`** — revenue index at ±5/10/15/20% fare steps per route — powers the Power BI scenario slicer.

## Interpretation Notes

- Elasticity = -1.5 means a 10% fare increase → 15% passenger drop → net revenue *decreases* (elastic, lower fare)
- Elasticity = -0.6 means a 10% fare increase → 6% passenger drop → net revenue *increases* (inelastic, raise fare)
- ULCC share interaction: routes with heavy ULCC competition typically show more elastic demand
- Revenue opportunity is quarterly; annualize by ×4 for executive reporting
