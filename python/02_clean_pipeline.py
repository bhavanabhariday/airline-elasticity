"""
DB1B Clean & Merge Pipeline — memory-efficient streaming version
Processes one quarter at a time, writes incremental parquet chunks,
then concatenates at the end. Avoids loading all 26GB into RAM at once.
"""

from pathlib import Path
import pandas as pd
import numpy as np
import gc

RAW_DIR       = Path(__file__).parent.parent / "data" / "raw"
PROCESSED_DIR = Path(__file__).parent.parent / "data" / "processed"
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

ULCC_CARRIERS = {"NK", "F9", "G4", "SY", "WN"}

FARE_CLASS_MAP = {
    "Y": "Coach_Full",    "B": "Coach_Full",
    "M": "Coach_Discount","H": "Coach_Discount",
    "Q": "Coach_Discount","K": "Coach_Discount",
    "V": "Coach_Deep_Discount","W": "Coach_Deep_Discount",
    "L": "Coach_Deep_Discount","U": "Coach_Deep_Discount",
    "T": "Coach_Deep_Discount","X": "Coach_Deep_Discount",
    "F": "First",         "A": "First",  "P": "First",
    "J": "Business",      "C": "Business","D": "Business","I": "Business",
}

COUPON_COLS = ["ItinID","MktID","SeqNum","Quarter","Year",
               "Origin","Dest","TkCarrier","OpCarrier",
               "FareClass","Distance","ItinGeoType"]

TICKET_COLS = ["ItinID","Quarter","Year",
               "Passengers","ItinFare","BulkFare","ItinGeoType"]


def find_csv(directory: Path) -> Path | None:
    csvs = list(directory.glob("*.csv"))
    return csvs[0] if csvs else None


def process_quarter(year: int, quarter: int) -> pd.DataFrame | None:
    coupon_dir = RAW_DIR / f"Coupon_{year}_Q{quarter}"
    ticket_dir = RAW_DIR / f"Ticket_{year}_Q{quarter}"

    coupon_csv = find_csv(coupon_dir)
    ticket_csv = find_csv(ticket_dir)

    if not coupon_csv or not ticket_csv:
        print(f"  [{year} Q{quarter}] Missing CSV — skipping")
        return None

    print(f"  [{year} Q{quarter}] Loading...", flush=True)

    # Read only needed columns, use low-memory chunked read
    coupon = pd.read_csv(coupon_csv, usecols=lambda c: c in COUPON_COLS,
                         low_memory=True)
    ticket = pd.read_csv(ticket_csv, usecols=lambda c: c in TICKET_COLS,
                         low_memory=True)

    print(f"  [{year} Q{quarter}] Coupon {len(coupon):,} rows, Ticket {len(ticket):,} rows")

    # --- Clean coupon ---
    coupon = coupon[coupon["SeqNum"] == 1].copy() if "SeqNum" in coupon.columns else coupon
    coupon["FareClass"] = coupon["FareClass"].astype(str).str.strip().str.upper()
    coupon["fare_tier"] = coupon["FareClass"].map(FARE_CLASS_MAP).fillna("Other")
    coupon["is_ulcc"]   = coupon["TkCarrier"].isin(ULCC_CARRIERS).astype("int8")
    coupon = coupon.drop_duplicates(subset=["ItinID","MktID"])
    coupon_slim = coupon[["ItinID","fare_tier","is_ulcc","Distance","Origin","Dest"]].copy()
    del coupon; gc.collect()

    # --- Clean ticket ---
    if "BulkFare" in ticket.columns:
        ticket = ticket[ticket["BulkFare"] == 0]
    if "ItinGeoType" in ticket.columns:
        ticket = ticket[ticket["ItinGeoType"] == 1]  # domestic only
    ticket = ticket[(ticket["ItinFare"] > 0) & (ticket["Passengers"] > 0)]
    ticket = ticket[(ticket["ItinFare"] >= 20) & (ticket["ItinFare"] <= 5000)]

    # --- Merge on ItinID (Ticket has no MktID) ---
    merged = ticket.merge(coupon_slim, on="ItinID", how="inner")
    del ticket, coupon_slim; gc.collect()

    if merged.empty:
        print(f"  [{year} Q{quarter}] No rows after merge — skipping")
        return None

    # Undirected route key
    merged["route"] = merged[["Origin","Dest"]].apply(
        lambda r: "-".join(sorted([str(r["Origin"]), str(r["Dest"])])), axis=1
    )

    # Aggregate
    agg = (
        merged.groupby(["route","Origin","Dest","Year","Quarter","fare_tier"])
        .agg(
            total_passengers=("Passengers","sum"),
            avg_fare        =("ItinFare","mean"),
            median_fare     =("ItinFare","median"),
            avg_distance    =("Distance","mean"),
            ulcc_share      =("is_ulcc","mean"),
            n_itins         =("ItinID","nunique"),
        )
        .reset_index()
    )
    del merged; gc.collect()
    print(f"  [{year} Q{quarter}] → {len(agg):,} route-tier rows")
    return agg


def main():
    years    = [2022, 2023, 2024]
    quarters = [1, 2, 3, 4]
    chunks   = []

    for year in years:
        for quarter in quarters:
            chunk = process_quarter(year, quarter)
            if chunk is not None:
                # Save each quarter immediately to avoid holding in RAM
                chunk_path = PROCESSED_DIR / f"panel_{year}_Q{quarter}.parquet"
                chunk.to_parquet(chunk_path, index=False)
                chunks.append(chunk_path)
                del chunk; gc.collect()

    print("\nCombining quarters...")
    panel = pd.concat([pd.read_parquet(p) for p in chunks], ignore_index=True)
    out   = PROCESSED_DIR / "db1b_panel.parquet"
    panel.to_parquet(out, index=False)

    # Clean up chunk files
    for p in chunks:
        p.unlink()

    print(f"Done. {len(panel):,} rows → {out}")
    print(panel[["route","fare_tier","Year","Quarter","avg_fare","total_passengers"]].head())


if __name__ == "__main__":
    main()
