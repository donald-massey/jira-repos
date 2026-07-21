import os
import traceback

import boto3
from botocore.config import Config
import pandas as pd
from datetime import datetime
from dotenv import load_dotenv
from sqlalchemy import create_engine
from concurrent.futures import TimeoutError
from pebble import ProcessPool, ProcessExpired

from typing import List, Dict, Any, Generator
from io import BytesIO
from PyPDF2 import PdfReader


def create_alchemy_engine():
    """
    Create a SQLAlchemy engine.
    """
    try:
        connection_string = (
            f"mssql+pyodbc://{cstitle_username}:{cstitle_password}@{cstitle_server}/countyScansTitle?driver=ODBC+Driver+17+for+SQL+Server")  # Ensure the driver is installed
        engine = create_engine(connection_string)
        return engine
    except Exception as e:
        print(f"Error creating engine: {e}")
        raise

def create_leaseid_df():
    # Create the SQLAlchemy engine
    engine = create_alchemy_engine()

    print(f"Start: Gathering LeaseIDs {datetime.now()}")
    query = ("SELECT * FROM countyScansTitle.dbo.LND_6732_SRC_20250717 "
             "ORDER BY leaseid DESC")

    df = pd.read_sql(query, engine)
    # print(f"df.head():\n\n {df.head()}")
    print(f"Complete: Gathering LeaseIDs {datetime.now()}")

    return df

def get_page_count(s3, bucket_name, source_path):
    response = s3.get_object(Bucket=bucket_name, Key=source_path)
    # Read the PDF content as a stream
    pdf_stream = BytesIO(response['Body'].read())
    # Get page count using PyPDF2
    try:
        reader = PdfReader(pdf_stream)
    except Exception as e:
        print(f"Error reading PDF: {e}")
        return 0
    page_count = len(reader.pages)
    return page_count


def process_batch(batch):
    config = Config(
        retries={
            'max_attempts': 10,  # Maximum number of retry attempts
            'mode': 'standard'  # Standard mode includes exponential backoff
        }
    )
    s3 = boto3.client('s3', region_name='us-east-1', config=config)

    return_list = list()
    start_time = datetime.now()

    counter = 0
    for row in batch:
        counter += 1
        contents = None

        try:
            response = s3.list_objects_v2(Bucket='di-diml-platinum-prod', Prefix=row['package_id'])
            contents = response['Contents']
        except Exception as e:
            print(f"LeaseID: {row['leaseid']}; Error: {e}")
            print(f"Traceback: {traceback.format_exc()}")

        if contents:
            row['file_size'] = contents[0]['Size']
            row['source_path'] = contents[0]['Key']
            row['page_count'] = get_page_count(s3, bucket_name='di-diml-platinum-prod', source_path=contents[0]['Key'])
            row['destination_path'] = ('s3://enverus-courthouse-prod-chd-plants' + '/' + row['state_countyname']
                                + '/' + row['recordid'][0:4].lower() + '/' + row['recordid'].lower()
                                + os.path.splitext(row['source_path'])[1])
            row['status'] = 'processed'
            return_list.append(row)
        else:
            row['status'] = 's3 query failed'
            return_list.append(row)

        if str(counter)[-2:] == '00':
            end_time = datetime.now()
            elapsed = end_time - start_time
            print(f"end_time: {end_time}")
            print(f'elapsed: {elapsed}')
            print(f"Processed: {counter} rows")

    return return_list


def create_batches_from_dataframe(
        df: pd.DataFrame,
        batch_size: int = 1000
) -> Generator[List[Dict[str, Any]], None, None]:
    """
    Convert a pandas DataFrame to dictionary format and yield batches of specified size.

    Args:
        df: The pandas DataFrame to process
        batch_size: Number of rows per batch (default: 10000)

    Yields:
        Batches of records in dictionary format
    """
    total_rows = len(df)

    for start_idx in range(0, total_rows, batch_size):
        end_idx = min(start_idx + batch_size, total_rows)
        batch_df = df.iloc[start_idx:end_idx]
        # Convert the batch to a list of dictionaries
        batch_records = batch_df.to_dict('records')
        yield batch_records


# TODO Make sure to populate the S3storagePath table talk with Ty
def query_s3(df_lease_ids, max_workers=7, max_timeout=None):
    # TODO Need to gather the dataset ID value by querying the S3 bucket, follow the same pattern to gather the
    """
    Process the dataframe using Pebble for multiprocessing.

    Args:
        df: pandas DataFrame to process
        max_workers: number of worker processes
        timeout: timeout in seconds for each row processing

    Returns:
        Updated DataFrame with processing results
    """
    start_time = datetime.now()
    rolling_start_time = datetime.now()

    batch_list = list()

    for batch in create_batches_from_dataframe(df_lease_ids):
        batch_list.append(batch)

    with ProcessPool(max_workers=max_workers) as pool:
         future = pool.map(process_batch, batch_list, timeout=max_timeout)
         iterator = future.result()

         while True:
             try:
                 result = next(iterator)
                 df_results = pd.DataFrame(result)
                 df_results.to_sql('LND_6732_DEST_20250717', create_alchemy_engine(), if_exists='append', index=False)

             except StopIteration:
                 break
             except TimeoutError as error:
                 print("Reading File Took Longer Than {} Seconds".format(error.args[1]))
             except ProcessExpired as error:
                 print("{}. Exit code: {}".format(error, error.exitcode))
             except Exception:
                 message = "An error occurred: {error} ".format(error=traceback.print_exc())
                 print(message)

    end_time = datetime.now()
    elapsed = end_time - start_time
    print("Files were processed in (hh:mm:ss.ms) {}".format(str(elapsed)[:-3]))


if __name__ == "__main__":
    # Load environment variables from the .env file
    load_dotenv()

    environ_var = 'dev'
    es_api = os.getenv('es_api')
    pd.set_option('display.max_columns', None)
    pd.set_option('display.expand_frame_repr', False)

    cstitle_username = os.getenv('cstitle_username')
    cstitle_password = os.getenv('cstitle_password')
    if environ_var.lower() == 'dev':
        cstitle_server = os.getenv('cstitle_dev_server')
    elif environ_var.lower() == 'prod':
        cstitle_server = os.getenv('cstitle_prod_server')

    print(f"cstitle_server: {cstitle_server}")
    print(f"cstitle_username: {cstitle_username}")
    print(f"cstitle_password: {cstitle_password}")

    try:
        df_lease_ids = create_leaseid_df()

        print("Start: Querying S3")
        query_s3(df_lease_ids, max_workers=8)
        print("Complete: Querying S3")
    except Exception as e:
        print(f"Error: {e}")
        print(f"Traceback: {traceback.format_exc()}")
        raise e
