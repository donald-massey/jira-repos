"""
{
  "denodo": {
    "connection_id": "ev_ds9",
    "flip": {
      "views": [
        "pres.vw_abstractdocument",
        "pres.vw_abstractdocumentgrantorgrantee",
        "pres.vw_abstractdocumentlanddescription",
        "pres.vw_abstractdocumentpriorreference"
      ]
    }
  },
  "elasticsearch": {
    "alias": "instruments",
    "connection_id": "es6",
    "load23": {
      "index_type": "abstract_plants"
    }
  },
  "geo_rendering_service": {
    "consul_datatype": "instruments",
    "datatype": "countyScans",
    "load_service": {
      "datacenters": [
        "azure-hci-ash"
      ],
      "name": "geo-rendering-load-dotnet-service"
    }
  },
  "notifications": {
    "hipchat": {
      "rooms": [
        {
          "name": "Data Delivery Dev",
          "token": "y5DiXEIVYELMdQi9YMzkrlcIXLVmJqLv1gByOW4K"
        }
      ]
    }
  },
  "row_count_tolerances": {
    "lower": 10.005,
    "upper": 10.0
  },
  "source": {
    "connection_id": "ev_ds9",
    "control_table": {
      "connection_id": "ev_ds9_data_sync_control",
      "downstream_dependencies": [],
      "id": "abstract_plant",
      "upstream_dependencies": []
    },
    "tables": [
      "abstractdocument",
      "abstractdocumentgrantorgrantee",
      "abstractdocumentlanddescription",
      "abstractdocumentpriorreference"
    ]
  }
}
"""

from typing import Dict, Any, List, Optional, Union
from datetime import datetime, timedelta
import logging
import functools
import json

from airflow import DAG
from airflow.models import Variable, Connection, TaskInstance
from airflow.providers.microsoft.mssql.hooks.mssql import MsSqlHook

from airflow.operators.empty import EmptyOperator
from airflow.operators.python import PythonOperator, BranchPythonOperator

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

from enverus.custom_utils.utils import datasync as ds
from enverus.custom_utils.utils.core.utilities import Utilities
from enverus.custom_utils.utils.core.victorops import notify_failure_victor_ops
from enverus.custom_operator.nomad_dispatch_operator_2 import NomadDispatchOperator2 as NomadDispatchOperator

DAG_NAME = 'abstract_plant'
DAG_CONFIG_VAR_NAME = DAG_NAME
DAG_DATASET = DAG_NAME

DAG_VICTOROPS_VAR_NAME = 'land.victorops'
DAG_EMAIL_LIST_VAR_NAME = 'land.emaillist'

dag_config: Dict[str, Any] = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)

# configure VictorOps notification level
message_type = Variable.get(DAG_VICTOROPS_VAR_NAME, deserialize_json=True)['message_type']
notify_failure_victor_ops = functools.partial(notify_failure_victor_ops, message_type=message_type)

# configure email list
land_email_list = Variable.get(DAG_EMAIL_LIST_VAR_NAME, deserialize_json=True)

# get configuration file paths
ES_MAP_PATH = Utilities.find_file_in_folder(folder_name="es_map", file_name=f"{DAG_DATASET}.json")
ES_CONFIG_PATH = Utilities.find_file_in_folder(folder_name="es_config", file_name=f"{DAG_DATASET}.json")

# Extra constants
LOAD_DENODO_TASK_ID = "load_denodo"
DENODO_LOADED_TABLES_XCOM_KEY = "denodo_load_tables"

# configure platforms
# ES platform still needed for current_state(), verify_load_counts(), verify_presentation_counts()
es23 = ds.Es23(dataset=DAG_DATASET, config=dag_config["elasticsearch"],
               source_connection_id=dag_config["denodo"]["connection_id"])
denodo = ds.Denodo(dataset=DAG_DATASET, config=dag_config["denodo"],
                   source_connection_id=dag_config["source"]["connection_id"])
grs = ds.GeoRendering(config=dag_config["geo_rendering_service"],
                      source_connection_id=dag_config["denodo"]["connection_id"])

# configure datasync object to mark_complete
datasync = ds.DataSync(dataset_config=dag_config, dataset=DAG_DATASET, platforms=[es23, denodo, grs])

default_args = {
    'owner': 'datasync',
    'depends_on_past': False,
    'start_date': datetime(2017, 1, 1),
    'email': [str(x) for x in land_email_list],
    'email_on_failure': True,
    'retries': 0,
    'on_failure_callback': notify_failure_victor_ops
}

dag = DAG(dag_id=DAG_NAME,
          schedule='0 20 * * *',
          catchup=False,
          max_active_runs=1,
          default_args=default_args,
          doc_md="#### **Updates Abstract Plant (instrument) Data in DS9_Pres to presentation tier**"
          )


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def build_es_config(connection_ids):
    config = {}
    for connection_id in connection_ids:
        config[connection_id] = Connection.get_connection_from_secrets(connection_id).host
    return config


def build_sql_config(connection_id):
    conn = Connection.get_connection_from_secrets(connection_id)
    source_dbms = 'pg' if conn.conn_type == 'postgres' else 'ms'
    return {"server": str(conn.host),
            "user": str(conn.login),
            "password": str(conn.password),
            "db": str(conn.schema),
            "source_dbms": source_dbms}


def get_index_map():
    with open(ES_MAP_PATH) as f:
        return json.load(f)


def get_indexer_config():
    with open(ES_CONFIG_PATH) as f:
        return json.load(f)


def get_index_name(index_type, context):
    index_name = '-'.join([index_type, context['ts_nodash'].lower()])
    context['ti'].xcom_push(key='elasticsearch_index', value=index_name)
    return index_name


def extend_es_create_index_meta(context, meta):
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])
    index_type = cfg["elasticsearch"]["load23"]["index_type"]
    meta["ES_CONNECTION_CONFIG"] = json.dumps(build_es_config(es_connection_ids))
    meta["INDEX_NAME"] = get_index_name(index_type, context)
    meta["INDEX_MAP"] = json.dumps(get_index_map())
    return meta


def modify_es_load_config_with_source_tables(config: dict, source_tables: list[str]) -> dict:
    '''
    This modifies the es_config dict so that it's sql_table values are replaced with the values from source_tables.

    The first table will replace the first top-level "sql_table" value in the first "dataset", and then the remaining
    tables will replace each "sql_table" in the "nested" datasets in the order that they are provided.

    This function performs an in-place modification, but returns the modified config dict for ease of use.
    '''

    # Remove the first value from source_tables and use it to replace the first top-level dataset sql_table
    first_table = source_tables.pop(0)
    config["datasets"][0]["sql_table"] = first_table

    # Iterate through the rest of the source_tables while looping through the "dataset[0].nested" values and make replacements
    for nested_index, table_name in enumerate(source_tables):
        config["datasets"][0]["nested"][nested_index]["sql_table"] = table_name

    return config


def extend_es_load_dataset_meta(context, meta):
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)
    ti: TaskInstance = context["ti"]
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])
    sql_connection_id = cfg["denodo"]["connection_id"]
    meta["ES_CONNECTION_CONFIG"] = json.dumps(build_es_config(es_connection_ids))
    meta["SQL_CONNECTION_CONFIG"] = json.dumps(build_sql_config(sql_connection_id))
    meta["INDEX_NAME"] = context["ti"].xcom_pull(task_ids="create_elasticsearch_index", key="elasticsearch_index")

    ti.log.info(f"Pulling '{DENODO_LOADED_TABLES_XCOM_KEY}' from the '{LOAD_DENODO_TASK_ID}' task")
    loaded_source_tables: list[str] = ti.xcom_pull(task_ids=LOAD_DENODO_TASK_ID, key=DENODO_LOADED_TABLES_XCOM_KEY)
    ti.log.info(f"Got '{DENODO_LOADED_TABLES_XCOM_KEY}' from the '{LOAD_DENODO_TASK_ID}' task: " + ", ".join(
        loaded_source_tables))

    ti.log.info(f"Getting base elasticsearch loader config from '{ES_CONFIG_PATH}'")
    static_es_config = get_indexer_config()

    ti.log.info(f"Modifying the base elasticsearch loader config with updated source_tables")
    es_config = modify_es_load_config_with_source_tables(static_es_config, loaded_source_tables)

    meta["INDEXER_CONFIG"] = json.dumps(es_config)
    return meta


def extend_es_flip_meta(context, meta):
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])
    meta["ES_CONNECTION_CONFIG"] = json.dumps(build_es_config(es_connection_ids))
    meta["ALIASES"] = json.dumps(get_indexer_config()["aliases"])
    meta["TO_INDEX"] = context["ti"].xcom_pull(task_ids="create_elasticsearch_index", key="elasticsearch_index")
    return meta


def extend_es_rollback_flip_meta(context, meta):
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])
    meta["ES_CONNECTION_CONFIG"] = json.dumps(build_es_config(es_connection_ids))
    meta["ALIASES"] = json.dumps(get_indexer_config()["aliases"])
    meta["TO_INDEX"] = context["ti"].xcom_pull(task_ids="capture_current_state", key="elasticsearch_index")
    return meta


def extend_es_delete_index_meta(context, meta):
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])
    meta["ES_CONNECTION_CONFIG"] = json.dumps(build_es_config(es_connection_ids))
    meta["INDEX_NAME"] = context["ti"].xcom_pull(task_ids="capture_current_state", key="elasticsearch_index")
    return meta


# ---------------------------------------------------------------------------
# Shared helper functions (count verification)
# ---------------------------------------------------------------------------

def get_nested_count(conn_id, schema, table1, table2, table3, table4, joinfield1, joinfield2):
    mssqlhook = MsSqlHook(mssql_conn_id=conn_id)
    sql = """
SELECT
(
SELECT COUNT(b.{joinfield2})
FROM {schema}{table1} a
LEFT OUTER JOIN {schema}{table2} b
ON a.{joinfield1} = b.{joinfield2} WHERE b.deleteddate IS NULL
)
+
(
SELECT COUNT(c.{joinfield2})
FROM {schema}{table1} a
LEFT OUTER JOIN {schema}{table3} c
ON a.{joinfield1} = c.{joinfield2} WHERE c.deleteddate IS NULL
)
+
(
SELECT COUNT(d.{joinfield2})
FROM {schema}{table1} a
LEFT OUTER JOIN {schema}{table4} d
ON a.{joinfield1} = d.{joinfield2} WHERE d.deleteddate IS NULL
)
+
(
SELECT COUNT(*)
FROM {schema}{table1} WHERE deleteddate IS NULL
)
""".format(schema=schema, table1=table1, table2=table2, table3=table3, table4=table4,
           joinfield1=joinfield1, joinfield2=joinfield2)
    records = mssqlhook.get_records(sql)
    if not records:
        return 0
    return records[0][0]


# ---------------------------------------------------------------------------
# Task callables
# ---------------------------------------------------------------------------

def current_state(**context):
    ti: TaskInstance = context['ti']

    ti.log.info("Querying elasticsearch current state")
    index_name = es23.current_state()
    ti.xcom_push(key='elasticsearch_index', value=index_name)

    ti.log.info("Querying denodo current state")
    denodo_tables = denodo.current_state()
    ti.xcom_push(key='denodo_abstract_document_table', value=denodo_tables[0])
    ti.xcom_push(key='denodo_abstract_document_grantor_grantee_table', value=denodo_tables[1])
    ti.xcom_push(key='denodo_abstract_document_land_description_table', value=denodo_tables[2])
    ti.xcom_push(key='denodo_abstract_document_prior_reference_table', value=denodo_tables[3])


@Utilities.retry_on_eof_error
def verify_new_counts(**context):
    ti: TaskInstance = context['ti']
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)

    source_connection = cfg['source']['connection_id']
    source_tables = cfg['source']['tables']
    source_count = get_nested_count(source_connection, 'pres.', source_tables[0], source_tables[1], source_tables[2],
                                    source_tables[3], "RecordId", "AbstractDocumentRecordId")
    ti.log.info(f'Source count: {source_count}')

    pres_connection = cfg['denodo']['connection_id']
    pres_views = cfg['denodo']['flip']['views']
    pres_count = get_nested_count(pres_connection, '', pres_views[0], pres_views[1], pres_views[2], pres_views[3],
                                  "RecordId", "AbstractDocumentRecordId")
    ti.log.info(f'Presentation count: {pres_count}')

    upper_tolerance = cfg['row_count_tolerances']['upper']
    lower_tolerance = cfg['row_count_tolerances']['lower']
    ti.log.info(f'Tolerance Multipliers: Upper={upper_tolerance}, Lower={lower_tolerance}')

    low_count = pres_count - (pres_count * lower_tolerance)
    high_count = pres_count + (pres_count * upper_tolerance)

    ti.log.info(
        f'Confirming source counts: (LowerBound) {low_count} <= (Actual) {source_count} <= (UpperBound) {high_count}')

    if not (low_count <= source_count <= high_count):
        ex_msg = "\n".join((
            f'Data source row count for {DAG_DATASET} Parent/Child tables are not within +/- tolerance of row count in production.',
            f'Data warehouse: {source_count}. Production: {pres_count}. Tolerance +{upper_tolerance * 100}/-{lower_tolerance * 100}'
        ))
        raise Exception(ex_msg)


@Utilities.unpack_templates_dict
@Utilities.retry_on_eof_error
def verify_load_counts(**context):
    ti: TaskInstance = context['ti']
    cfg = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)

    # denodo count
    denodo_connection = cfg['denodo']['connection_id']
    primary_table = ti.xcom_pull(key='denodo_load', task_ids='load_denodo')
    abstract_document_grantor_grantee_table = ti.xcom_pull(key='denodo_load',
                                                           task_ids='load_denodo_abstract_document_grantor_grantee')
    abstract_document_land_description_table_table = ti.xcom_pull(key='denodo_load',
                                                                  task_ids='load_denodo_abstract_document_land_description')
    abstract_document_prior_reference_table = ti.xcom_pull(key='denodo_load',
                                                           task_ids='load_denodo_abstract_document_prior_reference')

    ti.log.info(f'Getting denodo count')
    denodo_count = get_nested_count(denodo_connection, '', primary_table, abstract_document_grantor_grantee_table,
                                    abstract_document_land_description_table_table,
                                    abstract_document_prior_reference_table, 'RecordId', 'AbstractDocumentRecordId')
    ti.log.info(f'Denodo count: {denodo_count}')

    index_name = ti.xcom_pull(key='elasticsearch_index', task_ids='create_elasticsearch_index')
    es_count = es23.load_count(index_name)
    ti.log.info('Elasticsearch {index} count: {count}'.format(index=index_name, count=es_count))

    ti.xcom_push(key='load_counts', value={'denodo': denodo_count, 'es': es_count})
    return True


@Utilities.unpack_templates_dict
@Utilities.retry_on_eof_error
def verify_presentation_counts(**context):
    ti: TaskInstance = context['ti']
    cfg: Dict[str, Any] = Variable.get(DAG_CONFIG_VAR_NAME, deserialize_json=True)

    load_counts = ti.xcom_pull(key='load_counts'.format(DAG_DATASET), task_ids='verify_load_counts')

    # get states
    es_flip_state = ti.xcom_pull(key='state', task_ids='flip_elasticsearch')
    denodo_flip_state = ti.xcom_pull(key='state', task_ids='flip_denodo')
    grs_flip_state = ti.xcom_pull(key='state', task_ids='flip_geo_rendering_service')

    # evaluate states
    if not es_flip_state or not denodo_flip_state or not grs_flip_state:
        return 'notify_upstream_failure'
    elif es_flip_state != 'success' or denodo_flip_state != 'success' or grs_flip_state != 'success':
        return 'rollback_flip'

    # denodo count:
    denodo_connection = cfg['denodo']['connection_id']
    denodo_views = cfg['denodo']['flip']['views']
    denodo_count = get_nested_count(denodo_connection, '', denodo_views[0], denodo_views[1], denodo_views[2],
                                    denodo_views[3], "RecordId", "AbstractDocumentRecordId")

    # es counts
    index_name = ti.xcom_pull(key='elasticsearch_index', task_ids='create_elasticsearch_index')
    es_count = es23.load_count(index_name)
    logging.info('Elasticsearch {index} count: {count}'.format(index=index_name, count=es_count))

    if load_counts['denodo'] == denodo_count and load_counts['es'] == es_count:
        return 'mark_success'
    else:
        logging.info('Post flip count mismatch - flip did not succeed...Rolling back')
        return 'rollback_flip'


def set_denodo_table_name(context):
    abstract_document_table = 'pres.abstractdocument_' + context['ds_nodash']
    abstract_document_grantor_grantee_table = 'pres.abstractdocumentgrantorgrantee_' + context['ds_nodash']
    abstract_document_land_description_table = 'pres.abstractdocumentlanddescription_' + context['ds_nodash']
    abstract_document_prior_reference_table = 'pres.abstractdocumentpriorreference_' + context['ds_nodash']

    source_tables = [
        abstract_document_table,
        abstract_document_grantor_grantee_table,
        abstract_document_land_description_table,
        abstract_document_prior_reference_table
    ]
    # everything that reads *_denodo_load wants one table
    context['ti'].xcom_push(key='denodo_load', value=abstract_document_table)
    # es loader and grs also need associated tables
    context['ti'].xcom_push(key='denodo_load_tables', value=source_tables)


def set_denodo_abstract_document_grantor_grantee_table_name(context):
    abstract_document_grantor_grantee_table = 'pres.abstractdocumentgrantorgrantee_' + context['ds_nodash']
    context['ti'].xcom_push(key='denodo_load', value=abstract_document_grantor_grantee_table)


def set_denodo_abstract_document_land_description_table_name(context):
    abstract_document_land_description_table_table = 'pres.abstractdocumentlanddescription_' + context['ds_nodash']
    context['ti'].xcom_push(key='denodo_load', value=abstract_document_land_description_table_table)


def set_denodo_abstract_document_prior_reference_table_name(context):
    abstract_document_prior_reference_table = 'pres.abstractdocumentpriorreference_' + context['ds_nodash']
    context['ti'].xcom_push(key='denodo_load', value=abstract_document_prior_reference_table)


# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------


capture_current_state = PythonOperator(
    task_id='capture_current_state',
    python_callable=current_state,
    provide_context=True,
    dag=dag
)

stage_geo_rendering_load = PythonOperator(
    task_id='stage_geo_rendering_load',
    python_callable=grs.stage,
    provide_context=True,
    dag=dag
)

check_new_counts = PythonOperator(
    task_id='check_new_counts',
    python_callable=verify_new_counts,
    provide_context=True,
    retries=5,
    retry_delay=timedelta(seconds=30),
    email_on_retry=False,
    dag=dag
)

load_denodo = SQLExecuteQueryOperator(
    task_id='load_denodo',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocument.sql',
    params={
        'base_table_name': 'abstractdocument',
        'source_table': 'pres.AbstractDocument'
    },
    on_success_callback=set_denodo_table_name,
    retries=3,
    retry_delay=timedelta(seconds=30),
    email_on_retry=False,
    dag=dag
)

load_denodo_abstract_document_grantor_grantee = SQLExecuteQueryOperator(
    task_id='load_denodo_abstract_document_grantor_grantee',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocumentgrantorgrantee.sql',
    params={
        'base_table_name': 'abstractdocumentgrantorgrantee',
        'source_table': 'pres.AbstractDocumentGrantorGrantee'
    },
    on_success_callback=set_denodo_abstract_document_grantor_grantee_table_name,
    retries=3,
    retry_delay=timedelta(seconds=60),
    email_on_retry=False,
    dag=dag
)

load_denodo_abstract_document_land_description = SQLExecuteQueryOperator(
    task_id='load_denodo_abstract_document_land_description',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocumentlanddescription.sql',
    params={
        'base_table_name': 'abstractdocumentlanddescription',
        'source_table': 'pres.AbstractDocumentLandDescription'
    },
    on_success_callback=set_denodo_abstract_document_land_description_table_name,
    retries=3,
    retry_delay=timedelta(seconds=60),
    email_on_retry=False,
    dag=dag
)

load_denodo_abstract_document_prior_reference = SQLExecuteQueryOperator(
    task_id='load_denodo_abstract_document_prior_reference',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocumentpriorreference.sql',
    params={
        'base_table_name': 'abstractdocumentpriorreference',
        'source_table': 'pres.AbstractDocumentPriorReference'
    },
    on_success_callback=set_denodo_abstract_document_prior_reference_table_name,
    retries=3,
    retry_delay=timedelta(seconds=60),
    email_on_retry=False,
    dag=dag
)

load_geo_rendering_service = PythonOperator(
    task_id='load_geo_rendering_service',
    python_callable=grs.loadv2,
    templates_dict={
        'source_table': "{{ task_instance.xcom_pull(task_ids='load_denodo', key='denodo_load') }}",
        'nested_tables': [
            "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_grantor_grantee', key='denodo_load') }}",
            "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_land_description', key='denodo_load') }}",
            "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_prior_reference', key='denodo_load') }}"]
    },
    provide_context=True,
    dag=dag
)

join_load_task = EmptyOperator(
    task_id='join',
    dag=dag
)

LOAD_PROC_COUNT = 4

load_elastic_search_tasks = []

for i in range(LOAD_PROC_COUNT):
    load_task = NomadDispatchOperator(
        task_id=f'load_elastic_search_{i}',
        job_name='elasticsearch-loader_job',
        region='aws-ue1',
        meta={
            'ACTION': 'load_nested_dataset',
            'PROC_COUNT': str(LOAD_PROC_COUNT),
            'PROC_POSITION': str(i),
        },
        extend_meta_fn=extend_es_load_dataset_meta,
        poll_interval_sec=60,
        params={
            'dataset': DAG_DATASET,
            'index_name': {
                'task_ids': 'create_elasticsearch_index',
                'key': 'elasticsearch_index',
            },
        },
        dag=dag
    )
    load_elastic_search_tasks.append(load_task)

verify_load_counts_task = PythonOperator(
    task_id='verify_load_counts',
    python_callable=verify_load_counts,
    provide_context=True,
    dag=dag
)

flip_dnd_task = SQLExecuteQueryOperator(
    task_id='flip_denodo',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocument.sql',
    params={'rollback': False},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_grantorgrantee = SQLExecuteQueryOperator(
    task_id='flip_dnd_grantorgrantee',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentgrantorgrantee.sql',
    params={'rollback': False},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_landdescription = SQLExecuteQueryOperator(
    task_id='flip_dnd_landdescription',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentlanddescription.sql',
    params={'rollback': False},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_priorreference = SQLExecuteQueryOperator(
    task_id='flip_dnd_priorreference',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentpriorreference.sql',
    params={'rollback': False},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_grs_task = PythonOperator(
    task_id='flip_geo_rendering_service',
    python_callable=grs.flip,
    provide_context=True,
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_elasticsearch_task = NomadDispatchOperator(
    task_id='flip_elasticsearch',
    job_name='elasticsearch-loader_job',
    region='aws-ue1',
    meta={
        'ACTION': 'flip_index',
    },
    extend_meta_fn=extend_es_flip_meta,
    poll_interval_sec=10,
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    params={
        'dataset': DAG_DATASET,
    },
    dag=dag
)

verify_presentation_counts_task = BranchPythonOperator(
    task_id='verify_presentation_counts',
    trigger_rule='all_done',
    provide_context=True,
    python_callable=verify_presentation_counts,
    templates_dict={
        denodo.platform_name: "{{ task_instance.xcom_pull(task_ids='flip_denodo', key='state') }}",
        es23.platform_name: "{{ task_instance.xcom_pull(task_ids='flip_elasticsearch', key='state') }}",
        grs.platform_name: "{{ task_instance.xcom_pull(task_ids='flip_geo_rendering_service', key='state') }}"
    },
    dag=dag
)

mark_success = PythonOperator(
    task_id='mark_success',
    python_callable=datasync.mark_complete,
    op_kwargs={
        'conn_id': dag_config.get('source', {}).get('control_table', {}).get('connection_id', 'ev_dw_data_sync_control')
    },
    dag=dag
)

rollback_flip = EmptyOperator(
    task_id='rollback_flip',
    dag=dag
)

rollback_es_flip = PythonOperator(
    task_id='rollback_elasticsearch_flip',
    python_callable=es23.flip,
    templates_dict={
        "to_index": "{{ task_instance.xcom_pull(task_ids='capture_current_state', key='elasticsearch_index') }}"
    },
    provide_context=True,
    dag=dag
)

rollback_denodo_flip = SQLExecuteQueryOperator(
    task_id='rollback_denodo_flip',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocument.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_grantorgrantee = SQLExecuteQueryOperator(
    task_id='rollback_grantorgrantee',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentgrantorgrantee.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_landdescription = SQLExecuteQueryOperator(
    task_id='rollback_landdescription',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentlanddescription.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_priorreference = SQLExecuteQueryOperator(
    task_id='rollback_priorreference',
    conn_id=dag_config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentpriorreference.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_grs_flip = PythonOperator(
    task_id='rollback_grs_flip',
    python_callable=grs.rollback_flip,
    provide_context=True,
    dag=dag
)

cleanup_denodo = PythonOperator(
    task_id='cleanup_denodo',
    python_callable=denodo.cleanup,
    op_kwargs={'dataset': 'AbstractDocument'},
    templates_dict={
        'current_table': "{{ task_instance.xcom_pull(task_ids='load_denodo', key='denodo_load') }}",
        'previous_table': "{{ task_instance.xcom_pull(task_ids='capture_current_state', key='denodo_abstract_document_table') }}"
    },
    provide_context=True,
    dag=dag
)

cleanup_grantorgrantee = PythonOperator(
    task_id='cleanup_grantorgrantee',
    python_callable=denodo.cleanup,
    provide_context=True,
    op_kwargs={'dataset': 'AbstractDocumentGrantorGrantee'},
    templates_dict={
        'current_table': "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_grantor_grantee', key='denodo_load') }}",
        'previous_table': "{{ task_instance.xcom_pull(task_ids='capture_current_state', key='denodo_abstract_document_grantor_grantee_table') }}"
    },
    dag=dag
)

cleanup_landdescription = PythonOperator(
    task_id='cleanup_landdescription',
    python_callable=denodo.cleanup,
    provide_context=True,
    op_kwargs={'dataset': 'AbstractDocumentLandDescription'},
    templates_dict={
        'current_table': "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_land_description', key='denodo_load') }}",
        'previous_table': "{{ task_instance.xcom_pull(task_ids='capture_current_state', key='denodo_abstract_document_land_description_table') }}"
    },
    dag=dag
)

cleanup_priorreference = PythonOperator(
    task_id='cleanup_priorreference',
    python_callable=denodo.cleanup,
    provide_context=True,
    op_kwargs={'dataset': 'AbstractDocumentPriorReference'},
    templates_dict={
        'current_table': "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_prior_reference', key='denodo_load') }}",
        'previous_table': "{{ task_instance.xcom_pull(task_ids='capture_current_state', key='denodo_abstract_document_prior_reference_table') }}"
    },
    dag=dag
)

cleanup_es_index = NomadDispatchOperator(
    task_id='cleanup_es_index',
    job_name='elasticsearch-loader_job',
    region='aws-ue1',
    meta={
        'ACTION': 'delete_index',
    },
    extend_meta_fn=extend_es_delete_index_meta,
    poll_interval_sec=5,
    params={
        'dataset': DAG_DATASET,
    },
    dag=dag
)

create_elasticsearch_index = NomadDispatchOperator(
    task_id='create_elasticsearch_index',
    job_name='elasticsearch-loader_job',
    region='aws-ue1',
    meta={
        'ACTION': 'create_index',
    },
    extend_meta_fn=extend_es_create_index_meta,
    poll_interval_sec=10,
    params={
        'dataset': DAG_DATASET,
    },
    dag=dag
)

notify_success = EmptyOperator(
    task_id='notify_success',
    dag=dag
)

notify_failure = EmptyOperator(
    task_id='notify_failure',
    dag=dag
)

notify_upstream_failure = EmptyOperator(
    task_id='notify_upstream_failure',
    dag=dag
)

capture_current_state.set_downstream(check_new_counts)
check_new_counts.set_downstream([
    load_denodo,
    load_denodo_abstract_document_grantor_grantee,
    load_denodo_abstract_document_land_description,
    load_denodo_abstract_document_prior_reference
])

create_elasticsearch_index.set_upstream([
    load_denodo,
    load_denodo_abstract_document_grantor_grantee,
    load_denodo_abstract_document_land_description,
    load_denodo_abstract_document_prior_reference
])

create_elasticsearch_index.set_downstream(load_geo_rendering_service)
join_load_task.set_upstream(load_geo_rendering_service)

verify_load_counts_task.set_upstream(join_load_task)
verify_load_counts_task.set_downstream(stage_geo_rendering_load)
stage_geo_rendering_load.set_downstream([
    flip_elasticsearch_task,
    flip_dnd_task,
    flip_grs_task,
    flip_dnd_grantorgrantee,
    flip_dnd_landdescription,
    flip_dnd_priorreference
])

# branch paths
verify_presentation_counts_task.set_upstream([
    flip_elasticsearch_task,
    flip_dnd_task,
    flip_grs_task,
    flip_dnd_landdescription,
    flip_dnd_grantorgrantee,
    flip_dnd_priorreference
])
verify_presentation_counts_task.set_downstream(mark_success)
verify_presentation_counts_task.set_downstream(rollback_flip)
verify_presentation_counts_task.set_downstream(notify_upstream_failure)

# success path
mark_success.set_downstream([
    cleanup_denodo,
    cleanup_es_index,
    cleanup_grantorgrantee,
    cleanup_landdescription,
    cleanup_priorreference
])

notify_success.set_upstream([
    cleanup_denodo,
    cleanup_es_index,
    cleanup_grantorgrantee,
    cleanup_landdescription,
    cleanup_priorreference
])

create_elasticsearch_index >> load_elastic_search_tasks >> join_load_task >> verify_load_counts_task >> flip_elasticsearch_task

# rollback path
rollback_flip.set_downstream([
    rollback_denodo_flip,
    rollback_grantorgrantee,
    rollback_landdescription,
    rollback_priorreference,
    rollback_es_flip,
    rollback_grs_flip
])

notify_failure.set_upstream([
    rollback_denodo_flip,
    rollback_grantorgrantee,
    rollback_landdescription,
    rollback_priorreference,
    rollback_es_flip,
    rollback_grs_flip
])
