"""
Feature Engineering for Elasticity Model
Reads db1b_panel.parquet, selects top routes, adds lagged/derived features,
and writes model_ready.parquet + route_index.csv for R consumption.
"""

from pathlib import Path

import numpy as np
import pandas as pd

PROCESSED_DIR = Path(__file__).parent.parent / "data" / "processed"
OUTPUT_DIR = Path(__file__).parent.parent / "data" / "output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

TOP_N_ROUTES = 250
MIN_PAX_PER_QUARTER = 500       # route-fare_tier combos below this dropped
MIN_QUARTERS_OBSERVED = 6       # need enough time-series depth for panel FE


def select_top_routes(df: pd.DataFrame) -> pd.DataFrame:
    """Keep top N routes by total passenger volume (revenue management relevance)."""
    route_vol = (
        df.groupby("route")["total_passengers"]
        .sum()
        .nlargest(TOP_N_ROUTES)
        .reset_index()
        .rename(columns={"total_passengers": "route_total_pax"})
    )
    return df.merge(route_vol[["route", "route_total_pax"]], on="route", how="inner")


def add_time_index(df: pd.DataFrame) -> pd.DataFrame:
    """Linear time index (1 = 2022 Q1) for trend control."""
    df = df.copy()
    df["time_idx"] = (df["Year"] - 2022) * 4 + df["Quarter"]
    return df


def add_season_flags(df: pd.DataFrame) -> pd.DataFrame:
    """Quarter dummies (Q1 = baseline)."""
    df = df.copy()
    for q in [2, 3, 4]:
        df[f"q{q}"] = (df["Quarter"] == q).astype(int)
    return df


def add_log_transforms(df: pd.DataFrame) -> pd.DataFrame:
    """Log-transform fare and passengers for log-log elasticity specification."""
    df = df.copy()
    df["log_avg_fare"] = np.log(df["avg_fare"])
    df["log_passengers"] = np.log(df["total_passengers"])
    df["log_distance"] = np.log(df["avg_distance"].clip(lower=1))
    return df


def add_competition_flags(df: pd.DataFrame) -> pd.DataFrame:
    """ULCC competition flag: 1 if ULCC share > 10% on the route-quarter."""
    df = df.copy()
    df["ulcc_competition"] = (df["ulcc_share"] > 0.10).astype(int)
    df["ulcc_intensity"] = df["ulcc_share"]  # continuous version for interactions
    return df


def add_fare_tier_dummies(df: pd.DataFrame) -> pd.DataFrame:
    """Encode fare tiers (Coach_Discount = baseline)."""
    baseline = "Coach_Discount"
    tiers = [t for t in df["fare_tier"].unique() if t != baseline and t != "Other"]
    for tier in tiers:
        col = "ft_" + tier.lower().replace(" ", "_")
        df[col] = (df["fare_tier"] == tier).astype(int)
    return df


def filter_minimum_observations(df: pd.DataFrame) -> pd.DataFrame:
    """Drop route-fare_tier panels with too few time observations for FE estimation."""
    counts = df.groupby(["route", "fare_tier"])["time_idx"].count()
    valid = counts[counts >= MIN_QUARTERS_OBSERVED].reset_index()[["route", "fare_tier"]]
    return df.merge(valid, on=["route", "fare_tier"], how="inner")


def build_route_index(df: pd.DataFrame) -> pd.DataFrame:
    """Integer route ID for R's plm package (requires numeric panel index)."""
    routes = df[["route", "Origin", "Dest", "route_total_pax"]].drop_duplicates("route")
    routes = routes.sort_values("route_total_pax", ascending=False).reset_index(drop=True)
    routes["route_id"] = routes.index + 1
    return routes


def main():
    panel_path = PROCESSED_DIR / "db1b_panel.parquet"
    if not panel_path.exists():
        raise FileNotFoundError("Run 02_clean_pipeline.py first.")

    df = pd.read_parquet(panel_path)
    print(f"Loaded panel: {len(df):,} rows")

    df = df[df["total_passengers"] >= MIN_PAX_PER_QUARTER]
    df = select_top_routes(df)
    print(f"After top-{TOP_N_ROUTES} route filter: {len(df):,} rows")

    df = add_time_index(df)
    df = add_season_flags(df)
    df = add_log_transforms(df)
    df = add_competition_flags(df)
    df = add_fare_tier_dummies(df)
    df = filter_minimum_observations(df)
    print(f"After minimum-observation filter: {len(df):,} rows")

    route_index = build_route_index(df)
    df = df.merge(route_index[["route", "route_id"]], on="route", how="left")

    # Panel identifier for plm: route_id × fare_tier → unique entity
    df["panel_id"] = df["route_id"].astype(str) + "_" + df["fare_tier"]

    model_ready_path = OUTPUT_DIR / "model_ready.parquet"
    route_idx_path = OUTPUT_DIR / "route_index.csv"

    df.to_parquet(model_ready_path, index=False)
    route_index.to_csv(route_idx_path, index=False)

    print(f"\nWrote model_ready: {model_ready_path}")
    print(f"Wrote route_index: {route_idx_path}")
    print(f"Routes: {df['route'].nunique()} | Fare tiers: {df['fare_tier'].nunique()}")
    print(f"Date range: {df['Year'].min()} Q{df['Quarter'].min()} – {df['Year'].max()} Q{df['Quarter'].max()}")
    print("\nSample:")
    print(df[["route", "fare_tier", "Year", "Quarter", "avg_fare", "total_passengers",
              "log_avg_fare", "log_passengers", "ulcc_competition"]].head(10).to_string())


if __name__ == "__main__":
    main()
