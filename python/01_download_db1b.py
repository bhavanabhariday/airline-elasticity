"""
DOT DB1B Data Downloader — parallel version
Downloads DB1B Coupon and Ticket tables from BTS for 2022-2024.
Files land in ../data/raw/
"""

import time
import zipfile
import requests
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

RAW_DIR = Path(__file__).parent.parent / "data" / "raw"
RAW_DIR.mkdir(parents=True, exist_ok=True)

YEARS    = [2022, 2023, 2024]
QUARTERS = [1, 2, 3, 4]
TABLES   = ["Coupon", "Ticket"]
WORKERS  = 6  # parallel downloads

BASE_URL = "https://transtats.bts.gov/PREZIP/Origin_and_Destination_Survey_DB1B{table}_{year}_{quarter}.zip"


def download_and_extract(year, quarter, table):
    url      = BASE_URL.format(table=table, year=year, quarter=quarter)
    zip_name = f"DB1B{table}_{year}_Q{quarter}.zip"
    zip_path = RAW_DIR / zip_name
    csv_dir  = RAW_DIR / f"{table}_{year}_Q{quarter}"
    csv_dir.mkdir(exist_ok=True)

    # Skip if already extracted
    if any(csv_dir.glob("*.csv")):
        print(f"[skip] {zip_name} already extracted")
        return True

    # Download if zip not already present
    if not zip_path.exists():
        for attempt in range(1, 4):
            try:
                print(f"[download] {zip_name} (attempt {attempt})")
                resp = requests.get(url, stream=True, timeout=300)
                resp.raise_for_status()
                with open(zip_path, "wb") as f:
                    for chunk in resp.iter_content(chunk_size=2 << 20):
                        f.write(chunk)
                break
            except Exception as e:
                print(f"[error] {zip_name}: {e}")
                zip_path.unlink(missing_ok=True)
                if attempt == 3:
                    return False
                time.sleep(5 * attempt)

    # Extract
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            for member in zf.namelist():
                if member.endswith(".csv"):
                    print(f"[extract] {member}")
                    zf.extract(member, csv_dir)
        zip_path.unlink(missing_ok=True)
        return True
    except Exception as e:
        print(f"[error] extracting {zip_name}: {e}")
        return False


def main():
    jobs = [
        (year, quarter, table)
        for year in YEARS
        for quarter in QUARTERS
        for table in TABLES
    ]

    print(f"Downloading {len(jobs)} files with {WORKERS} parallel workers...\n")
    failed = []

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futures = {ex.submit(download_and_extract, *job): job for job in jobs}
        for fut in as_completed(futures):
            job = futures[fut]
            if not fut.result():
                failed.append(job)

    print(f"\nDone. Failed: {len(failed)}")
    if failed:
        for j in failed:
            print(f"  FAILED: DB1B{j[2]}_{j[0]}_Q{j[1]}")


if __name__ == "__main__":
    main()
