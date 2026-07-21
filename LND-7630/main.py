import os
import csv
import multiprocessing
from concurrent.futures import ProcessPoolExecutor


def calculate_dir_sizes(root_path):
    """
    Walk a directory tree bottom-up and calculate total size for each directory.
    Returns dict of {directory_path: size_in_bytes}
    """
    dir_sizes = {}

    try:
        for dirpath, dirnames, filenames in os.walk(root_path, topdown=False):
            total_size = 0

            # Add size of files in this directory
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                try:
                    total_size += os.path.getsize(filepath)
                except (OSError, FileNotFoundError, PermissionError):
                    # Skip files we can't access
                    continue

            # Add sizes of subdirectories (already calculated)
            for dirname in dirnames:
                subdir_path = os.path.join(dirpath, dirname)
                total_size += dir_sizes.get(subdir_path, 0)

            dir_sizes[dirpath] = total_size

    except (OSError, PermissionError) as e:
        print(f"Error accessing {root_path}: {e}")

    return dir_sizes


def scan_network_path(network_path, output_csv, max_workers=None):
    """
    Scan network path using multiprocessing and write directory sizes to CSV.

    Args:
        network_path: Root network path to scan
        output_csv: Output CSV file path
        max_workers: Number of worker processes (defaults to CPU count)
    """
    if max_workers is None:
        max_workers = multiprocessing.cpu_count()

    print(f"Scanning {network_path} with {max_workers} workers...")

    # Get top-level directories to distribute across workers
    try:
        top_level_items = os.listdir(network_path)
    except (OSError, PermissionError) as e:
        print(f"Cannot access network path: {e}")
        return

    top_dirs = [
        os.path.join(network_path, item)
        for item in top_level_items
        if os.path.isdir(os.path.join(network_path, item))
    ]

    print(f"Found {len(top_dirs)} top-level directories to process")

    # Process directories in parallel
    all_dir_sizes = {}

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        results = executor.map(calculate_dir_sizes, top_dirs)

        for dir_sizes in results:
            all_dir_sizes.update(dir_sizes)

    print(f"Processed {len(all_dir_sizes)} directories total")

    # Write to CSV
    with open(output_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['Directory', 'Size_Bytes'])

        for directory_path in sorted(all_dir_sizes.keys()):
            writer.writerow([directory_path, all_dir_sizes[directory_path]])

    print(f"Results written to {output_csv}")


if __name__ == '__main__':
    # Configure these values
    NETWORK_PATH = r'\\aus2-cs-fss01.na.drillinginfo.com\leasing_images_uncompressed'
    OUTPUT_CSV = 'directory_sizes.csv'

    scan_network_path(NETWORK_PATH, OUTPUT_CSV)
