import csv
from pathlib import Path

CSV_FILE = Path(__file__).parent / "directory_sizes.csv"


def format_size(total_bytes):
    units = [
        ("TB", 1024 ** 4),
        ("GB", 1024 ** 3),
        ("MB", 1024 ** 2),
        ("KB", 1024),
        ("Bytes", 1),
    ]
    return {label: round(total_bytes / divisor, 4) for label, divisor in units}


def main():
    total_bytes = 0
    row_count = 0
    errors = 0

    with open(CSV_FILE, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                total_bytes += int(row["Size_Bytes"])
                row_count += 1
            except (ValueError, KeyError):
                errors += 1

    sizes = format_size(total_bytes)

    print(f"Rows processed : {row_count:,}")
    if errors:
        print(f"Rows skipped   : {errors:,}")
    print()
    print(f"Total Bytes    : {total_bytes:,}")
    print(f"Total KB       : {sizes['KB']:,.4f}")
    print(f"Total MB       : {sizes['MB']:,.4f}")
    print(f"Total GB       : {sizes['GB']:,.4f}")
    print(f"Total TB       : {sizes['TB']:,.4f}")


if __name__ == "__main__":
    main()
