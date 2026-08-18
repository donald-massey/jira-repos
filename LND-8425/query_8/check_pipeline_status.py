"""LND-8425 post-keying pipeline status check + full export-log snapshot.

Verifier for the 4-link chain after re-keying record 68125b82 / LeaseID 5184347:
  1. CSTitle tblLandDescription populated (keyed legal present)
  2. tblRecord status 4/16, recordIsLease 1 (exportable)
  3. tblexportLog re-export happened (fresh exportDate/zipName after keying)
  4. DIV1 tblleaseAbstractMapping row exists (mapping_id gate -> glue publishes)

Windows auth against countyScansTitle; DIV1 via [LinktoDiv1Repl] linked server.
Run again after the tblexportLog delete + next daily export to confirm 3 & 4 flip.
"""
import pyodbc

SERVER = "AUS2-DTF-PAP01V.NA.DRILLINGINFO.COM"
REC = "68125b82-1ae2-4058-a46f-f3e46709e47b"
LEASE = 5184347

conn = pyodbc.connect(
    f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={SERVER};"
    f"DATABASE=countyScansTitle;Trusted_Connection=yes;TrustServerCertificate=yes;",
    autocommit=True,
)
cur = conn.cursor()


def run(title, sql, params=()):
    print("\n" + "=" * 70)
    print(title)
    print("-" * 70)
    try:
        cur.execute(sql, params)
        cols = [c[0] for c in cur.description]
        rows = cur.fetchall()
        if not rows:
            print("(no rows)")
        else:
            print(" | ".join(cols))
            for r in rows:
                print(" | ".join("" if v is None else str(v) for v in r))
    except Exception as e:
        print(f"ERROR: {e}")


run("1) CSTitle tblLandDescription (keyed legal?)",
    """SELECT L.landDescriptionID, L.AbstractName, L.section, L.township,
              L.rangeOrBlock, L.survey, L.IsDeleted
       FROM [countyScansTitle].[dbo].[tblRecord] R
       JOIN [countyScansTitle].[dbo].[tblLandDescription] L ON R.recordID = L.recordID
       WHERE R.recordID = ?""", (REC,))

run("2) tblRecord shell status",
    """SELECT recordID, recordNumber, statusID, recordIsLease, fileDate, _ModifiedDateTime
       FROM [countyScansTitle].[dbo].[tblRecord] WHERE recordID = ?""", (REC,))

run("3) tblexportLog history for record",
    """SELECT recordID, leaseID, exportDate, zipName
       FROM [countyScansTitle].[dbo].[tblexportLog]
       WHERE recordID = ? ORDER BY exportDate""", (REC,))

run("4) DIV1 tblleaseAbstractMapping (mapping_id gate)",
    """SELECT m.LeaseID, m.abstractID, m.mappingid AS legacy_mapping_id, m.parcelNum,
              a.StateID, st.state_name
       FROM [LinktoDiv1Repl].[div1_Daily].[dbo].[tblleaseAbstractMapping] m
       LEFT JOIN [LinktoDiv1Repl].[div1_Daily].[dbo].[tblAbstract] a ON a.AbstractID = m.abstractID
       LEFT JOIN [LinktoDiv1Repl].[div1_Daily].[dbo].[tblState]   st ON st.StateID   = a.StateID
       WHERE m.LeaseID = ?""", (LEASE,))

conn.close()
print("\n" + "=" * 70)
print("DONE")
