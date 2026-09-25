from datetime import datetime, timedelta
import logging
import functools
from airflow.hooks.mssql_hook import MsSqlHook

from airflow import DAG
from airflow.models import Variable

from airflow.operators.dummy_operator import DummyOperator
from airflow.operators.python_operator import PythonOperator
from airflow.operators.python_operator import BranchPythonOperator
from airflow.operators import MsSqlDDLOperator
from airflow.operators.msteams import MSTeamsWebhookOperator
from airflow.hooks.msteams import MSTeamsWebhookHook

import data_ops_dags.utils.datasync as ds
from data_ops_dags.utils.core.utilities import Utilities
from data_ops_dags.utils.core.victorops import notify_failure_victor_ops

dataset = 'abstract_plant'
config = Variable.get(dataset, deserialize_json=True)
es_map_path   = Utilities.find_file_in_folder(folder_name="es_map",
                                              file_name="{dataset}.json".format(dataset=dataset))
es_config_path   = Utilities.find_file_in_folder(folder_name="es_config",
                                                 file_name="{dataset}.json".format(dataset=dataset))

# configure platforms
es23 = ds.Es23(dataset=dataset, config=config["elasticsearch"], source_connection_id=config["denodo"]["connection_id"])
denodo = ds.Denodo(dataset=dataset, config=config["denodo"], source_connection_id=config["source"]["connection_id"])
grs = ds.GeoRendering(config=config["geo_rendering_service"], source_connection_id=config["denodo"]["connection_id"])

# configure datasync object
datasync = ds.DataSync(dataset_config=config, dataset=dataset, platforms=[es23, denodo, grs])

# configure VictorOps notification level
message_type = Variable.get('land.victorops', deserialize_json=True)['message_type']
notify_failure_victor_ops = functools.partial(notify_failure_victor_ops, message_type=message_type)

default_args = {
    'owner': 'datasync',
    'depends_on_past': False,
    'start_date': datetime(2017, 1, 1),
    'email': [str(x) for x in (Variable.get('land.emaillist', deserialize_json=True))],
    'email_on_failure': True,
    'retries': 0,
    'on_failure_callback': notify_failure_victor_ops
}

dag = DAG('abstract_plant',
          default_args=default_args,
          schedule_interval='0 20 * * *',
          max_active_runs=1)

dag.doc_md = """####**Updates Abstract Plant (instrument) Data in DS9_Pres to presentation tier**  \n
"""


def current_state(**context):
    index_name = es23.current_state()
    # returns a list of tables that correspond with the list in config['denodo']['flip']['views']
    denodo_tables = denodo.current_state()

    # publish out name of current denodo tables, used in case denodo needs to rollback (used in view templates)
    context['ti'].xcom_push(key='denodo_abstract_document_table', value=denodo_tables[0])
    context['ti'].xcom_push(key='denodo_abstract_document_grantor_grantee_table', value=denodo_tables[1])
    context['ti'].xcom_push(key='denodo_abstract_document_land_description_table', value=denodo_tables[2])
    context['ti'].xcom_push(key='denodo_abstract_document_prior_reference_table', value=denodo_tables[3])
    context['ti'].xcom_push(key='elasticsearch_index', value=index_name)


def get_nested_count(conn_id, schema, table1, table2, table3, table4, joinfield1, joinfield2):
    """
    handles one-to-many and many-to-many relationships for nested tables
    """
    mssqlhook = MsSqlHook(mssql_conn_id=conn_id)
    logging.info(str(table1) + ", " + str(table2) + ", " + str(table3))

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
""".format(schema=schema, table1=table1, table2=table2, table3=table3, table4=table4, joinfield1=joinfield1,
           joinfield2=joinfield2)
    logging.info(sql)
    records = mssqlhook.get_records(sql)
    if not records:
        count = 0
    else:
        count = records[0][0]
    return count


@Utilities.retry_on_eof_error
def verify_new_counts():
    """Customized for this DAG due to the many-to-many source count"""
    # source count
    source_connection = config['source']['connection_id']
    source_tables = config['source']['tables']
    source_count = get_nested_count(source_connection, 'pres.', source_tables[0], source_tables[1], source_tables[2],
                                    source_tables[3], "RecordId", "AbstractDocumentRecordId")
    logging.info('Source count: {count}'.format(count=source_count))

    # pres count
    pres_connection = config['denodo']['connection_id']
    pres_views = config['denodo']['flip']['views']
    pres_count = get_nested_count(pres_connection, '', pres_views[0], pres_views[1], pres_views[2], pres_views[3],
                                  "RecordId", "AbstractDocumentRecordId")
    logging.info('Presentation count: {count}'.format(count=pres_count))

    upper_tolerance = config['row_count_tolerances']['upper']
    lower_tolerance = config['row_count_tolerances']['lower']
    low_count = pres_count - (pres_count * lower_tolerance)
    high_count = pres_count + (pres_count * upper_tolerance)

    if low_count <= source_count <= high_count:
        if source_count < pres_count:
            MSTeamsWebhookHook(
                http_conn_id='ms_teams_data_delivery',
                message='{} Parent / Child table count has decreased, but is within tolerance. '
                        'Update process will continue.'.format(dataset.capitalize()),
                subtitle='Current count: {}. New Count: {}'.format(pres_count, source_count),
                theme_color='C3792F'
            ).execute()
    else:
        message = 'Data source row count for {} Parent/Child tables are not within +/- tolerance ' \
                  'of row count in production.'.format(dataset)
        subtitle = 'Data warehouse: {}. Production: {}. Tolerance +{}/-{}'.format(
            source_count,
            pres_count,
            upper_tolerance * 100,
            lower_tolerance * 100
        )
        MSTeamsWebhookHook(
            http_conn_id='ms_teams_data_delivery',
            message=message,
            subtitle=subtitle,
            theme_color='962D32'
        ).execute()
        raise Exception('{}\n{}'.format(message, subtitle))


@Utilities.unpack_templates_dict
@Utilities.retry_on_eof_error
def verify_load_counts(**context):
    load_counts = {}

    # denodo count
    denodo_connection = config['denodo']['connection_id']
    primary_table = context['ti'].xcom_pull(key='denodo_load', task_ids='load_denodo')
    abstract_document_grantor_grantee_table = context['ti'].xcom_pull(key='denodo_load',
                                                           task_ids='load_denodo_abstract_document_grantor_grantee')
    abstract_document_land_description_table_table = context['ti'].xcom_pull(key='denodo_load',
                                                        task_ids='load_denodo_abstract_document_land_description')
    abstract_document_prior_reference_table = context['ti'].xcom_pull(key='denodo_load',
                                                           task_ids='load_denodo_abstract_document_prior_reference')
    denodo_count = get_nested_count(denodo_connection, '', primary_table, abstract_document_grantor_grantee_table,
                                    abstract_document_land_description_table_table,
                                    abstract_document_prior_reference_table,
                                    'RecordId', 'AbstractDocumentRecordId')
    load_counts['denodo'] = denodo_count
    logging.info('Denodo count: {count}'.format(count=denodo_count))

    # es23 counts
    index_name = context['ti'].xcom_pull(key='elasticsearch_index', task_ids='create_elasticsearch_index')
    es_count = es23.load_count(index_name)
    load_counts['es'] = es_count
    logging.info('Elasticsearch {index} count: {count}'.format(index=index_name, count=es_count))

    context['ti'].xcom_push(key='load_counts', value=load_counts)

    if  denodo_count == es_count:
        return True
    else:
        raise Exception('Counts do not match, not flipping datasets.')


stage_geo_rendering_load = PythonOperator(
    task_id='stage_geo_rendering_load',
    python_callable=grs.stage,
    provide_context=True,
    dag=dag
)


@Utilities.unpack_templates_dict
@Utilities.retry_on_eof_error
def verify_presentation_counts(**context):
    load_counts = context['ti'].xcom_pull(key='load_counts'.format(dataset), task_ids='verify_load_counts')

    # get states
    es_flip_state = context['ti'].xcom_pull(key='state', task_ids='flip_elasticsearch')
    denodo_flip_state = context['ti'].xcom_pull(key='state', task_ids='flip_denodo')
    grs_flip_state = context['ti'].xcom_pull(key='state', task_ids='flip_geo_rendering_service')

    # evaluate states
    if not es_flip_state or not denodo_flip_state or not grs_flip_state:
        return 'notify_upstream_failure'
    elif es_flip_state != 'success' or denodo_flip_state != 'success' or grs_flip_state != 'success':
        return 'rollback_flip'

    # denodo count:
    denodo_connection = config['denodo']['connection_id']
    denodo_views = config['denodo']['flip']['views']
    denodo_count = get_nested_count(denodo_connection, '', denodo_views[0], denodo_views[1], denodo_views[2],
                                    denodo_views[3], "RecordId", "AbstractDocumentRecordId")

    # es counts
    index_name = context['ti'].xcom_pull(key='elasticsearch_index', task_ids='create_elasticsearch_index')
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
    source_tables = [abstract_document_table, abstract_document_grantor_grantee_table,
                     abstract_document_land_description_table, abstract_document_prior_reference_table]
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


capture_current_state = PythonOperator(
    task_id='capture_current_state',
    python_callable=current_state,
    provide_context=True,
    dag=dag
)

check_new_counts = PythonOperator(
    task_id='check_new_counts',
    python_callable=verify_new_counts,
    retries=5,
    retry_delay=timedelta(seconds=30),
    email_on_retry=False,
    dag=dag
)

load_denodo = MsSqlDDLOperator(
    task_id='load_denodo',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocument.sql',
    params={'base_table_name': 'abstractdocument',
            'source_table': 'pres.AbstractDocument'},
    on_success_callback=set_denodo_table_name,
    retries=3,
    retry_delay=timedelta(seconds=30),
    email_on_retry=False,
    dag=dag
)

load_denodo_abstract_document_grantor_grantee = MsSqlDDLOperator(
    task_id='load_denodo_abstract_document_grantor_grantee',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocumentgrantorgrantee.sql',
    params={'base_table_name': 'abstractdocumentgrantorgrantee',
            'source_table': 'pres.AbstractDocumentGrantorGrantee'},
    on_success_callback=set_denodo_abstract_document_grantor_grantee_table_name,
    retries=3,
    retry_delay=timedelta(seconds=60),
    email_on_retry=False,
    dag=dag
)

load_denodo_abstract_document_land_description = MsSqlDDLOperator(
    task_id='load_denodo_abstract_document_land_description',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocumentlanddescription.sql',
    params={'base_table_name': 'abstractdocumentlanddescription',
            'source_table': 'pres.AbstractDocumentLandDescription'},
    on_success_callback=set_denodo_abstract_document_land_description_table_name,
    retries=3,
    retry_delay=timedelta(seconds=60),
    email_on_retry=False,
    dag=dag
)

load_denodo_abstract_document_prior_reference = MsSqlDDLOperator(
    task_id='load_denodo_abstract_document_prior_reference',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/abstractdocumentpriorreference.sql',
    params={'base_table_name': 'abstractdocumentpriorreference',
            'source_table': 'pres.AbstractDocumentPriorReference'},
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
        'nested_tables': ["{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_grantor_grantee', key='denodo_load') }}",
                          "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_land_description', key='denodo_load') }}",
                          "{{ task_instance.xcom_pull(task_ids='load_denodo_abstract_document_prior_reference', key='denodo_load') }}"]
    },
    provide_context=True,
    dag=dag
)

create_elasticsearch_index = PythonOperator(
    task_id='create_elasticsearch_index',
    python_callable=es23.create_index,
    op_kwargs={
        'es_conn_id': config["elasticsearch"]["connection_id"],
        'es_map_path': es_map_path
    },
    provide_context=True,
    dag=dag
)

join = DummyOperator(
    task_id='join',
    dag=dag
)

for x in range(1, 5):
    load_elastic_search = PythonOperator(
        task_id='load_elastic_search_batch_{x}'.format(x=x),
        python_callable=es23.load,
        op_kwargs={
            'proc_count': 4,
            'proc_position': x,
            'sql_conn_id': config["denodo"]["connection_id"],
            'sql_schema': 'pres',
            'es_load_type': 'window',
            'es_conn_id': config["elasticsearch"]["connection_id"],
            'es_config_path': es_config_path
        },
        templates_dict={
            'index_name': "{{ task_instance.xcom_pull(task_ids='create_elasticsearch_index', key='elasticsearch_index') }}",
            'source_tables': "{{ task_instance.xcom_pull(task_ids='load_denodo', key='denodo_load_tables') }}"
        },
        pool='elasticsearch_indexer',
        provide_context=True,
        queue="default_ash",
        dag=dag
    )
    load_elastic_search.set_upstream(create_elasticsearch_index)
    load_elastic_search.set_downstream(join)

verify_load_counts = PythonOperator(
    task_id='verify_load_counts',
    python_callable=verify_load_counts,
    provide_context=True,
    dag=dag
)

flip_es_task = PythonOperator(
    task_id='flip_elasticsearch',
    python_callable=es23.flip,
    provide_context=True,
    templates_dict={
        "to_index": "{{ task_instance.xcom_pull(task_ids='create_elasticsearch_index', key='elasticsearch_index') }}"
    },
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_task = MsSqlDDLOperator(
    task_id='flip_denodo',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocument.sql',
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_grantorgrantee = MsSqlDDLOperator(
    task_id='flip_dnd_grantorgrantee',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentgrantorgrantee.sql',
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_landdescription = MsSqlDDLOperator(
    task_id='flip_dnd_landdescription',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentlanddescription.sql',
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

flip_dnd_priorreference = MsSqlDDLOperator(
    task_id='flip_dnd_priorreference',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentpriorreference.sql',
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

verify_presentation_counts = BranchPythonOperator(
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
    op_kwargs={'conn_id': config['source']['control_table']['connection_id']},
    dag=dag
)

rollback_flip = DummyOperator(
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

rollback_denodo_flip = MsSqlDDLOperator(
    task_id='rollback_denodo_flip',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocument.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_grantorgrantee = MsSqlDDLOperator(
    task_id='rollback_grantorgrantee',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentgrantorgrantee.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_landdescription = MsSqlDDLOperator(
    task_id='rollback_landdescription',
    mssql_conn_id=config["denodo"]["connection_id"],
    sql='templates/sql/views/vw_abstractdocumentlanddescription.sql',
    params={'rollback': True},
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    dag=dag
)

rollback_priorreference = MsSqlDDLOperator(
    task_id='rollback_priorreference',
    mssql_conn_id=config["denodo"]["connection_id"],
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

cleanup_elasticsearch_index = PythonOperator(
    task_id='cleanup_es_index',
    python_callable=es23.drop_index,
    op_kwargs={'es_conn_id': config["elasticsearch"]["connection_id"]},
    provide_context=True,
    templates_dict={
        "index_name": "{{ task_instance.xcom_pull(task_ids='capture_current_state', key='elasticsearch_index') }}"
    },
    dag=dag
)


notify_success = MSTeamsWebhookOperator(
    task_id='notify_success',
    http_conn_id='ms_teams_land_notifications',
    message='Abstract Documents / Instruments have been updated successfully',
    theme_color='78BE20',
    dag=dag
)


notify_failure = MSTeamsWebhookOperator(
    task_id='notify_failure',
    http_conn_id='ms_teams_land_notifications',
    message='Abstract Documents / Instruments have failed to update',
    theme_color='962D32',
    dag=dag
)


notify_upstream_failure = MSTeamsWebhookOperator(
    task_id='notify_upstream_failure',
    http_conn_id='ms_teams_land_notifications',
    message='Abstract Documents / Instruments have failed to update',
    theme_color='962D32',
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
join.set_upstream(load_geo_rendering_service)

verify_load_counts.set_upstream(join)
verify_load_counts.set_downstream(stage_geo_rendering_load)
stage_geo_rendering_load.set_downstream([
    flip_es_task,
    flip_dnd_task,
    flip_grs_task,
    flip_dnd_grantorgrantee,
    flip_dnd_landdescription,
    flip_dnd_priorreference
])

# branch paths
verify_presentation_counts.set_upstream([
    flip_es_task,
    flip_dnd_task,
    flip_grs_task,
    flip_dnd_landdescription,
    flip_dnd_grantorgrantee,
    flip_dnd_priorreference
])
verify_presentation_counts.set_downstream(mark_success)
verify_presentation_counts.set_downstream(rollback_flip)
verify_presentation_counts.set_downstream(notify_upstream_failure)

# success path
mark_success.set_downstream([
    cleanup_denodo,
    cleanup_elasticsearch_index,
    cleanup_grantorgrantee,
    cleanup_landdescription,
    cleanup_priorreference
])

notify_success.set_upstream([
    cleanup_denodo,
    cleanup_elasticsearch_index,
    cleanup_grantorgrantee,
    cleanup_landdescription,
    cleanup_priorreference
])

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