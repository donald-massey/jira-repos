import os
import sys
import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine
from urllib.parse import quote_plus

# Pandas display settings - show all rows and columns
pd.set_option('display.max_rows', None)
pd.set_option('display.max_columns', None)
pd.set_option('display.width', None)
pd.set_option('display.max_colwidth', None)


def read_source_table():
    """
    Read data from source SQL Server table into a pandas DataFrame.
    Uses Windows authentication (your current credentials).

    Returns:
        pandas.DataFrame containing source table data
    """
    # Load environment variables
    server = os.getenv('SOURCE_SERVER')
    database = os.getenv('SOURCE_DATABASE')
    table = os.getenv('SOURCE_TABLE')

    print(f"Reading from source table: {table}")

    try:
        # Use SQLAlchemy with Windows authentication
        connection_string = (
            f"mssql+pyodbc://{server}/{database}"
            f"?driver=ODBC+Driver+17+for+SQL+Server"
            f"&trusted_connection=yes"
        )

        print(f"Connecting to {server}/{database} with Windows authentication...")
        engine = create_engine(connection_string)
        print(f"Successfully connected to {server}/{database}")

        # Read entire table into DataFrame
        query = f"SELECT * FROM {table}"
        df = pd.read_sql(query, engine)
        df.drop(columns=['countyName', 'stateName'], inplace=True)

        print(f"Successfully read {len(df)} rows from {table}")
        print(f"{df.head()}")
        engine.dispose()

        return df

    except Exception as e:
        print(f"ERROR: Failed to read source table: {str(e)}")
        raise


def write_dest_table(df):
    """
    Write DataFrame to destination SQL Server table.
    Drops existing table if it exists, then creates new table.

    Args:
        df: pandas.DataFrame to write to destination
    """
    # Load environment variables
    server = os.getenv('DEST_SERVER')
    database = os.getenv('DEST_DATABASE')
    username = os.getenv('DEST_USERNAME')
    password = os.getenv('DEST_PASSWORD')
    table = os.getenv('DEST_TABLE')

    # Split schema and table name
    if '.' in table:
        schema, table_name = table.split('.', 1)
    else:
        schema = 'dbo'
        table_name = table

    print(f"Writing to destination table: {schema}.{table_name}")

    try:
        # Use SQLAlchemy with SQL Server authentication
        connection_string = (
            f"mssql+pyodbc://{quote_plus(username)}:{quote_plus(password)}"
            f"@{server}/{database}"
            f"?driver=ODBC+Driver+17+for+SQL+Server"
        )

        print(f"Connecting to {server}/{database}...")
        engine = create_engine(connection_string)
        print(f"Successfully connected to {server}/{database}")

        # Write DataFrame to SQL Server (replace will drop and recreate)
        print(f"Creating new table and inserting {len(df)} rows...")
        df.to_sql(
            name=table_name,
            schema=schema,
            con=engine,
            if_exists='replace',
            index=False,
            method=None
        )

        print(f"Successfully wrote {len(df)} rows to {schema}.{table_name}")
        engine.dispose()

    except Exception as e:
        print(f"ERROR: Failed to write destination table: {str(e)}")
        raise


def main():
    """
    Main execution function: reads from source table and writes to destination table.
    """
    # Load .env file
    load_dotenv()

    print("=" * 60)
    print("SQL Server Table Migration")
    print("=" * 60)

    try:
        # Read from source
        df = read_source_table()

        # Write to destination
        write_dest_table(df)

        print("=" * 60)
        print("Migration completed successfully!")
        print("=" * 60)

    except Exception as e:
        print("=" * 60)
        print(f"Migration failed: {str(e)}")
        print("=" * 60)
        sys.exit(1)


if __name__ == '__main__':
    main()
