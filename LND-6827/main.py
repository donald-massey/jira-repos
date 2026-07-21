import os
import traceback
from datetime import datetime
from typing import List, Dict, Any, Generator

import boto3
import pandas as pd
from dotenv import load_dotenv
from botocore.config import Config
from concurrent.futures import TimeoutError
from pebble import ProcessPool, ProcessExpired
from PyPDF2 import PdfReader

from utils import create_alchemy_engine, copy_table


def create_df(cred_dict=None, input_query=None):
    # Create the SQLAlchemy engine
    engine = create_alchemy_engine(cred_dict)

    # TODO Change the query so it gathers from the DEST table if they don't exist in the new dest
    print(f"Start: Running Query {datetime.now()}")
    query = (input_query)

    df = pd.read_sql(query, engine)
    # print(f"df.head():\n\n {df.head()}")
    # print(f"len(df): {len(df)}")
    print(f"Complete: Running Query {datetime.now()}")

    return df

# TODO Copy image from source_path to destination_path
# TODO Insert record into tblS3Image
def process_batch(batch):
    config = Config(
        retries={
            'max_attempts': 10,  # Maximum number of retry attempts
            'mode': 'standard'  # Standard mode includes exponential backoff
        }
    )
    s3_client = boto3.client('s3', region_name='us-east-1', config=config)

    return_list = list()
    start_time = datetime.now()

    counter = 0
    for row in batch:
        counter += 1


        try:
            # Destination bucket and object
            destination_bucket = 'enverus-courthouse-prod-chd-plants'
            destination_key = row['s3FilePath'][40:]

            row['status'] = 'copied'
            # print(f"os.path.join(os.path.normpath(row['storageFilePath']), 'rb'), row['recordID'],  row['s3FilePath'][-4:]: {os.path.join(os.path.normpath(row['storageFilePath']), 'rb'), row['recordID'] +  row['s3FilePath'][-4:]}")

            with open (os.path.join(os.path.normpath(row['storageFilePath']), row['recordID'] + row['s3FilePath'][-4:]), 'rb') as f:
                s3_client.upload_fileobj(f, destination_bucket, destination_key)

        except Exception as e:
            print(f"recordID: {row['recordID']}; Error: {e}")
            print(f"Traceback: {traceback.format_exc()}")
            row['status'] = 'error'

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


def copy_images_to_s3(cred_dict=None, max_workers=7, max_timeout=None):
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

    counter = 0
    batch_list = list()

    cst_engine = create_alchemy_engine(cred_dict)

    cst_query = """
                SELECT TOP 1 *
                FROM countyScansTitle.dbo.LND_6827_STAGE_20251103
                """

    # Read data from source into DataFrame
    s3image_df = pd.read_sql(cst_query, cst_engine)
    print(s3image_df.head())

    for batch in create_batches_from_dataframe(s3image_df):
        batch_list.append(batch)

    with ProcessPool(max_workers=max_workers) as pool:
         future = pool.map(process_batch, batch_list, timeout=max_timeout)
         iterator = future.result()

         while True:
             try:
                 counter += 1

                 result = next(iterator)
                 df_results = pd.DataFrame(result)
                 df_results.to_sql('LND_6827_tblS3Image_20251103', create_alchemy_engine(cred_dict), if_exists='append', index=False)
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


def create_ds9_source_table(source_cred_dict, dest_cred_dict, dest_table_name):
    # Create SQLAlchemy engines for source and destination
    ds9_engine = create_alchemy_engine(source_cred_dict, database='DS9')
    dest_engine = create_alchemy_engine(dest_cred_dict, database='countyScansTitle')

    # DS9 query to get the data as a DataFrame
    ds9_query = """
                SELECT DISTINCT lease_id
                FROM [DS9].[pres].[legal_lease]
                WHERE 1=1
                 AND (image_link IS NOT NULL AND image_link != 'none')
                 AND image_link NOT LIKE '%s3://%'
                """

    # Read data from source into DataFrame
    df = pd.read_sql(ds9_query, ds9_engine)
    # print(df.head())

    # Write DataFrame to destination server
    # If the table already exists, you can specify if_exists='replace' or 'append'
    df.to_sql(dest_table_name, dest_engine, if_exists='replace', index=False)


def get_pdf_page_count(file_path):
    try:
        reader = PdfReader(file_path)
        return len(reader.pages)
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
        return None

def gather_pc_fsb(cred_dict=None, table=None):
    """
    Gathers page count and file size bytes for each file listed in the given table.
    Assumes files are accessible on a network share and are PDFs.
    """
    engine = create_alchemy_engine(cred_dict)

    # Query the table for file paths
    query = f"SELECT recordID, storageFilePath FROM {table}"
    df = pd.read_sql(query, engine)

    results = []
    counter = 0
    for idx, row in df.iterrows():
        counter += 1
        path = os.path.join(row["storageFilePath"], row['recordID'] + '.pdf')
        file_size = None
        page_count = None
        status = 'error'
        if os.path.exists(path):
            file_size = os.path.getsize(path)
            page_count = get_pdf_page_count(path)
            status = 'processed'
        else:
            print(f"Error With: {path}")

        results.append({
            'recordID': row['recordID'],
            'pageCount': page_count,
            'fileSizeBytes': file_size,
            'status': status
        })
        if str(counter)[-2:] == '00':
            print(f"Processed {counter} files at {datetime.now()}")

    result_df = pd.DataFrame(results)
    print(result_df.head())

    # 1. Write to a temporary table
    temp_table = table + '_temp'
    result_df.to_sql(temp_table, engine, if_exists='replace', index=False)

    # 2. Update original table using a JOIN on recordID
    update_sql = f"""
                  UPDATE a
                  SET 
                    a.pageCount = t.pageCount,
                    a.fileSizeBytes = t.fileSizeBytes,
                    a.status = t.status
                  FROM countyScansTitle.dbo.{table} AS a
                  INNER JOIN countyScansTitle.dbo.{temp_table} AS t
                    ON a.recordID = t.recordID
                  """
    # Note: The above syntax works for SQL Server and PostgreSQL. For MySQL, the syntax is different.
    # TODO This syntax isn't correct
    with engine.connect() as conn:
        conn.execute(update_sql)
        conn.commit()

    # 3. (Optional) Drop the temporary table
    with engine.connect() as conn:
        conn.execute(f"DROP TABLE {temp_table}")
        conn.commit()

if __name__ == "__main__":
    # Load environment variables from the .env file
    load_dotenv()

    pd.set_option('display.max_columns', None)
    pd.set_option('display.expand_frame_repr', False)

    cstitle_server = os.getenv('cstitle_server')
    cstitle_username = os.getenv('cstitle_username')
    cstitle_password = os.getenv('cstitle_password')
    cstitle_database = os.getenv('cstitle_database')

    print(f"cstitle_server: {cstitle_server}")
    print(f"cstitle_username: {cstitle_username}")
    print(f"cstitle_password: {cstitle_password}")
    print(f"cstitle_database: {cstitle_database}")

    csdigital_server = os.getenv('csdigital_server')
    csdigital_username = os.getenv('csdigital_username')
    csdigital_password = os.getenv('csdigital_password')
    csdigital_database = os.getenv('csdigital_database')

    print(f"csdigital_server: {csdigital_server}")
    print(f"csdigital_username: {csdigital_username}")
    print(f"csdigital_password: {csdigital_password}")

    ds9_server = os.getenv('ds9_server')
    ds9_username = os.getenv('ds9_username')
    ds9_password = os.getenv('ds9_password')
    ds9_database = os.getenv('ds9_database')

    print(f"ds9_server: {ds9_server}")
    print(f"ds9_username: {ds9_username}")
    print(f"ds9_password: {ds9_password}")
    print(f"ds9_database: {ds9_database}")

    cst_cred_dict = {'server': cstitle_server,
                     'username': cstitle_username,
                     'password': cstitle_password,
                     'database': cstitle_database}
    csd_cred_dict = {'server': csdigital_server,
                     'username': csdigital_username,
                     'password': csdigital_password}
    ds9_cred_dict = {'server': ds9_server,
                     'username': ds9_username,
                     'password': ds9_password,
                     'database': ds9_database}

    create_table = """
                    USE [countyScansTitle]
                    GO
                    
                    /****** Object:  Table [dbo].[tblS3Image_20251103]    Script Date: 10/30/2025 11:17:08 AM ******/
                    SET ANSI_NULLS ON
                    GO
                    
                    SET QUOTED_IDENTIFIER ON
                    GO
                    
                    CREATE TABLE [dbo].[tblS3Image_20251103](
                        [recordID] [varchar](36) NOT NULL,
                        [s3FilePath] [varchar](300) NOT NULL,
                        [pageCount] [int] NULL,
                        [fileSizeBytes] [bigint] NULL,
                        [_ModifiedDateTime] [datetime] NULL,
                        [_ModifiedBy] [varchar](75) NULL,
                     CONSTRAINT [PK_tblS3Image_20251103] PRIMARY KEY CLUSTERED 
                    (
                        [recordID] ASC
                    )WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
                    ) ON [PRIMARY]
                    GO
                    
                    ALTER TABLE [dbo].[tblS3Image_20251103] ADD  CONSTRAINT [DF_tblS3Image_ModifiedDateTime_20251103]  DEFAULT (getdate()) FOR [_ModifiedDateTime]
                    GO
                    
                    ALTER TABLE [dbo].[tblS3Image_20251103] ADD  CONSTRAINT [DF_tblS3Image_ModifiedBy_20251103]  DEFAULT (suser_sname()) FOR [_ModifiedBy]
                    GO
                    """


    cst_query = """
                SELECT DISTINCT tel.recordID, LOWER(tls.stateAbbreviation) + '/' + REPLACE(LOWER(tlc.countyName), '.', '') AS state_countyname, tr.storageFilePath, 's3://enverus-courthouse-prod-chd-plants' + '/' + LOWER(tls.stateAbbreviation) + '/' + REPLACE(LOWER(tlc.countyName), '.', '') + '/' + LEFT(tr.recordID, 4) + '/' + tr.recordID + tr.fileExtension AS s3FilePath,'                                     ' AS pageCount, '                                         ' AS fileSizeBytes, GETDATE() AS _ModifiedDateTime, 'LND-6827' AS _ModifiedBy, '                                             ' AS status
                INTO countyScansTitle.dbo.LND_6827_STAGE_20251103
                FROM countyScansTitle.dbo.tblrecord tr
                JOIN countyScansTitle.dbo.tblexportLog tel ON tel.recordID = tr.recordID
                JOIN countyScansTitle.dbo.LND_6827_SRC_20251103 src ON src.lease_id = tel.LeaseID
                JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tlc.countyID = tr.countyID
                JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateID = tr.stateID
                WHERE tr.recordIsLease = 1
                                and tr.statusID IN (4, 16)
                                and tr.fileDate >= '2002-01-01'
                            -- Include EOG McMullen and Gonzales. These are only keyed for EOG so we need to sources leases from those plants.
                                and tr.countyID not in (288,291,292,293,295,296,298,300,684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
                                700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,1187)
                                and tr.storageFilePath != 'NONE'
                """

    try:
        # print(f"Start: Create DS9 Source Table In CountyScansTitle dB {datetime.now()}")
        # create_ds9_source_table(ds9_cred_dict, cst_cred_dict, dest_table_name='LND_6827_SRC_20251103')
        # print(f"Complete: Create DS9 Source Table In CountyScansTitle dB {datetime.now()}")

        # print(f"Start: Gathering PageCount & fileSizeBytes For LND_6827_STAGE_20251103 {datetime.now()}")
        # gather_pc_fsb(table='LND_6827_STAGE_20251103', cred_dict=cst_cred_dict)
        # print(f"Complete: Gathering PageCount & fileSizeBytes For LND_6827_STAGE_20251103 {datetime.now()}")

        print(f"Start: Copying Network Files To S3 Bucket {datetime.now()}")
        copy_images_to_s3(cred_dict=cst_cred_dict, max_workers=7, max_timeout=600)
        print(f"Complete: Copying Network Files To S3 Bucket {datetime.now()}")

        # print(f"Start: Update tblS3Image With New Records {datetime.now()}")
        # update_s3image(cred_dict=cst_cred_dict)
        # print(f"Complete: Update tblS3Image With New Records {datetime.now()}")
    except Exception as e:
        print(f"Error: {e}")
        print(f"Traceback: {traceback.format_exc()}")
        raise e
