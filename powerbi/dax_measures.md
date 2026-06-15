# Power BI — DAX Measures & Data Model

## Data Sources (import these CSVs/Parquet into Power BI)

| Table | File | Grain |
|---|---|---|
| `RouteOpportunities` | `revenue_opportunities.csv` | route × fare_tier × quarter |
| `FareSensitivity` | `fare_sensitivity_curves.csv` | route × fare_tier × fare_step |
| `RouteIndex` | `route_index.csv` | route |

---

## Relationships

```
RouteIndex[route]  →  RouteOpportunities[route]   (1:many)
RouteIndex[route]  →  FareSensitivity[route]       (1:many)
```

---

## DAX Measures

### Core Revenue Metrics

```dax
Current Revenue =
SUMX(
    RouteOpportunities,
    RouteOpportunities[current_fare] * RouteOpportunities[current_pax]
)

Optimal Revenue =
SUMX(
    RouteOpportunities,
    RouteOpportunities[optimal_fare] * RouteOpportunities[optimal_pax]
)

Revenue Uplift ($) =
[Optimal Revenue] - [Current Revenue]

Revenue Uplift (%) =
DIVIDE([Revenue Uplift ($)], [Current Revenue])

Revenue Uplift ($M) =
DIVIDE([Revenue Uplift ($)], 1000000)
```

### Route Counts

```dax
# Routes Analyzed =
DISTINCTCOUNT(RouteOpportunities[route])

# High Opportunity Routes =
CALCULATE(
    DISTINCTCOUNT(RouteOpportunities[route]),
    RouteOpportunities[opportunity_tier] = "High"
)

# Raise Fare Routes =
CALCULATE(
    COUNTROWS(RouteOpportunities),
    RouteOpportunities[recommendation] = "Raise Fare"
)

# Lower Fare Routes =
CALCULATE(
    COUNTROWS(RouteOpportunities),
    RouteOpportunities[recommendation] = "Lower Fare"
)
```

### Elasticity KPIs

```dax
Avg Elasticity =
AVERAGE(RouteOpportunities[elasticity])

% Inelastic Routes =
DIVIDE(
    CALCULATE(COUNTROWS(RouteOpportunities), RouteOpportunities[elasticity] > -1),
    COUNTROWS(RouteOpportunities)
)

% Elastic Routes =
DIVIDE(
    CALCULATE(COUNTROWS(RouteOpportunities), RouteOpportunities[elasticity] <= -1),
    COUNTROWS(RouteOpportunities)
)

Avg ULCC Share =
AVERAGE(RouteOpportunities[ulcc_share])
```

### Fare Sensitivity (for line chart visual)

```dax
Revenue Index at Fare Step =
AVERAGE(FareSensitivity[rev_index])

-- Use this measure with FareSensitivity[fare_step] on the X axis
-- Filter by route/fare_tier for route-level drill-down
```

### Conditional Formatting

```dax
Recommendation Color =
SWITCH(
    SELECTEDVALUE(RouteOpportunities[recommendation]),
    "Raise Fare", "#2166AC",
    "Lower Fare", "#D73027",
    "#999999"
)

Opportunity Tier Color =
SWITCH(
    SELECTEDVALUE(RouteOpportunities[opportunity_tier]),
    "High",   "#1A9641",
    "Medium", "#F4A582",
    "Low",    "#D1D1D1"
)
```

---

## Suggested Dashboard Pages

### Page 1 — Executive Summary
- KPI cards: Total Revenue Uplift ($M), # High Opportunity Routes, % Elastic vs. Inelastic, Avg ULCC Share
- Bar chart: Revenue Opportunity by Fare Tier (grouped by recommendation)
- Scatter: Elasticity vs. Revenue Delta (bubble = current revenue)
- Table: Top 20 routes by |rev_delta|

### Page 2 — Route Explorer
- Slicer: Route, Fare Tier, Recommendation, Opportunity Tier
- Map visual: US route map (Origin/Dest lat-lon) colored by opportunity tier
- Line chart: Fare Sensitivity Curve (revenue index vs. fare step %) — updates on route selection
- Detail table: current_fare, optimal_fare, fare_change_pct, elasticity ± CI, recommendation

### Page 3 — ULCC Competition Analysis
- Scatter: ULCC Share vs. Elasticity by fare tier
- Bar: Avg elasticity by ULCC competition flag (0/1)
- Heatmap: Route × Quarter elasticity (for selected fare tier)
- Insight card: "Routes with >30% ULCC share are X% more price-elastic"

### Page 4 — Scenario Modeling
- Parameter slicer: fare change % (-20% to +20%, step 5%)
- Calculated table: apply chosen fare_step to all routes, compute ΔRev
- Ranked list: routes that benefit most from chosen fare adjustment
- Total modeled quarterly uplift KPI card

---

## Calculated Columns (add in Power Query or DAX)

```dax
-- In RouteOpportunities table:
Fare Change Label =
FORMAT(RouteOpportunities[fare_change_pct], "0.0%") & " → " & RouteOpportunities[recommendation]

Route Label =
RouteOpportunities[route] & " (" & RouteOpportunities[fare_tier] & ")"

Elasticity Band =
IF(RouteOpportunities[elasticity] > -0.5, "Very Inelastic (>-0.5)",
IF(RouteOpportunities[elasticity] > -1.0, "Inelastic (-1 to -0.5)",
IF(RouteOpportunities[elasticity] > -2.0, "Elastic (-2 to -1)",
"Highly Elastic (<-2)")))
```
