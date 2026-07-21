import os
import traceback

import pandas as pd
from sqlalchemy import text
from dotenv import load_dotenv
from utils import create_alchemy_engine, copy_table


if __name__ == "__main__":
    # Load environment variables from the .env file
    load_dotenv()

    environ_var = 'dev'
    pd.set_option('display.max_columns', None)
    pd.set_option('display.expand_frame_repr', False)

    cstitle_username = os.getenv('cstitle_username')
    cstitle_password = os.getenv('cstitle_password')
    cstitle_dev_server = os.getenv('cstitle_dev_server')
    cstitle_prod_server = os.getenv('cstitle_prod_server')

    print(f"cstitle_dev_server: {cstitle_dev_server}")
    print(f"cstitle_prod_server: {cstitle_prod_server}")
    print(f"cstitle_username: {cstitle_username}")
    print(f"cstitle_password: {cstitle_password}")
    cred_dict = {"cstitle_dev_server": cstitle_dev_server,
                 "cstitle_prod_server": cstitle_prod_server,
                 "cstitle_username": cstitle_username,
                 "cstitle_password": cstitle_password}

    csv_file = r'C:\tmp\BriefLegals\parsed_brief_legals.csv'

    try:
        print("Start: Processing Brief Legals CSV")
        dev_engine = create_alchemy_engine(cred_dict, env='dev')
        # prod_engine = create_alchemy_engine(cred_dict, env='prod')

        print(f'Reading: {csv_file}')
        df_ld = pd.read_csv(csv_file, sep=',', doublequote=False, escapechar='\\')
        print(f"Loaded CSV: {csv_file}")

        # Print the combined DataFrame
        print(f'df_ld.head():\n{df_ld.head()}')

        print(f"Start: Creating LND_6838_temp_table")
        df_ld.to_sql('LND_6838_temp_table', con=dev_engine, if_exists='replace', index=False)
        print(f"Complete: Creating LND_6838_temp_table")

        print("Start: Updating LND_6838_tbllandDescription From LND_6838_temp_table")
        # Perform a bulk update
        with dev_engine.begin() as connection:
            connection.execute(text("""
            UPDATE target_table
            SET
                target_table.Survey = source_table.Survey,
                target_table.Subdivision = source_table.Subdivision,
                target_table.Lot = source_table.Lot,
                target_table.Block = source_table.Block,
                target_table.Section = source_table.Section,
                target_table.Township = source_table.Township,
                target_table.RangeOrBlock = source_table.Range,
                target_table.Quartercalls = source_table.Quartercall,
                target_table.NewCityBlock = source_table.NewCityBlock
            FROM countyScansTitle.dbo.LND_6838_tbllandDescription target_table
            JOIN countyScansTitle.dbo.LND_6838_temp_table source_table
                ON target_table.landDescriptionID = source_table.landDescriptionID;
            """))
            connection.commit()

        with dev_engine.begin() as connection:
            # Remove the temporary table
            connection.execute(text("""DROP TABLE countyScansTitle.dbo.LND_6838_temp_table"""))
            connection.commit()
        print("Complete: Updating LND_6838_tbllandDescription From LND_6838_temp_table")
        print("Complete: Processing Brief Legals CSV")

        # print("Start: Copy [countyScansTitle].[dbo].[LND_6838_tbllandDescription] From Dev -> Prod")
        # copy_table(table_name='LND_6838_tbllandDescription', cred_dict=cred_dict)
        # print("Complete: Copy [countyScansTitle].[dbo].[LND_6838_tbllandDescription] From Dev -> Prod")
    except Exception as e:
        print(f"Error: {e}")
        print(f"Traceback: {traceback.format_exc()}")
        raise e
