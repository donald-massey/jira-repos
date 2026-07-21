import os
import pandas as pd
from sqlalchemy import create_engine


def copy_table(table_name=None, cred_dict=None):
    cstitle_username = cred_dict.get('cstitle_username')
    cstitle_password = cred_dict.get('cstitle_password')
    cstitle_dev_server = cred_dict.get('cstitle_dev_server')
    cstitle_prod_server = cred_dict.get('cstitle_prod_server')

    source_connection_string = f"mssql+pyodbc://{cstitle_username}:{cstitle_password}@{cstitle_dev_server}/countyScansTitle?driver=ODBC+Driver+17+for+SQL+Server"
    target_connection_string = f"mssql+pyodbc://{cstitle_username}:{cstitle_password}@{cstitle_prod_server}/countyScansTitle?driver=ODBC+Driver+17+for+SQL+Server"

    # Create engines for source and target databases
    source_engine = create_engine(source_connection_string)
    target_engine = create_engine(target_connection_string)

    try:
        # Read the table from the source database into a DataFrame
        with source_engine.connect() as source_conn:
            query = f"SELECT * FROM {table_name}"
            df = pd.read_sql(query, source_conn)
            print(f"Read {len(df)} rows from table '{table_name}' in the source database.")

        # Write the DataFrame to the target database
        with target_engine.connect() as target_conn:
            df.to_sql(table_name, con=target_conn, if_exists='replace', index=False)
            print(f"Successfully wrote {len(df)} rows to table '{table_name}' in the target database.")
    except Exception as e:
        print(f"An error occurred: {e}")


from sqlalchemy import create_engine

def create_alchemy_engine(cred_dict, driver='ODBC Driver 17 for SQL Server', dialect='mssql+pyodbc'):
    """
    Create a SQLAlchemy engine from a credentials dict.
    cred_dict should include: username, password, server, and optionally database.
    db can override the database in cred_dict.
    """
    try:
        username = cred_dict.get("username")
        password = cred_dict.get("password")
        server = cred_dict.get("server")
        database = cred_dict.get("database")
        if not all([username, password, server, database]):
            raise ValueError("Missing required database connection information.")

        connection_string = (
            f"{dialect}://{username}:{password}@{server}/{database}"
            f"?driver={driver.replace(' ', '+')}"
        )
        engine = create_engine(connection_string)
        return engine
    except Exception as e:
        print(f"Error creating engine: {e}")
        raise