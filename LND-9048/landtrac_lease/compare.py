"""DAG comparison — paste DAG source and fill variables below, then run: python compare.py"""

import difflib
import json
import sys

# fmt: off

PROD_DAG = '''
from datetime import datetime
import json
import functools

from airflow import DAG
from airflow.models import Variable, Connection, TaskInstance

from airflow.utils.trigger_rule import TriggerRule

from airflow.operators.python import PythonOperator
from airflow.operators.empty import EmptyOperator
from airflow.utils.dates import days_ago

from enverus.custom_utils.utils import datasync as ds
from enverus.custom_utils.utils.core.utilities import Utilities
from enverus.custom_utils.utils.core.victorops import notify_failure_victor_ops
from enverus.custom_operator.nomad_dispatch_operator_2 import NomadDispatchOperator2 as NomadDispatchOperator
from enverus.custom_utils.utils.es2 import EsOps2

dataset = "landtrac_lease"
dag_name = "landtrac_lease"
dag_variable_name = dag_name

default_dag_config_json = json.loads("""
{
  "row_count_tolerances": {
    "upper": 1.1,
    "lower": 1.005
  },
  "schedule": "0 12 * * *",
  "source": {
    "connection_id": "ev_ds9",
    "tables": [
      "landtrac_lease",
      "lease_assignment_detail",
      "depthseverances"
    ],
    "control_table": {
      "connection_id": "ev_ds9_data_sync_control",
      "id": "landtrac_lease",
      "upstream_dependencies": [],
      "downstream_dependencies": []
    }
  },
  "elasticsearch": {
    "connection_id": "es6",
    "connection_ids": ["es6"],
    "loader_workers": 10,
    "alias": "landtrac-leases",
    "load23": {
      "index_type": "landtrac_lease"
    }
  },
  "denodo": {
    "connection_id": "ev_ds9",
    "flip": {
      "view": "pres.vw_landtrac_lease",
      "views": [
        "pres.vw_landtrac_lease",
        "pres.vw_lease_assignment_detail",
        "pres.vw_depthseverances"
      ],
      "nested_table": "pres.vw_depthseverances"
    }
  },
  "geo_rendering_service": {
    "consul_datatype": "landtrac-leases",
    "datatype": "landtracLeases",
    "nested_table": "pres.lease_assignment_detail",
    "load_service": {
      "name": "geo-rendering-load-dotnet-service",
      "datacenters": [
        "azure-hci-ash"
      ]
    }
  }
}
""")

dag_config = Variable.setdefault(key=dag_variable_name, default=default_dag_config_json, deserialize_json=True)

es_map_path = Utilities.find_file_in_folder(folder_name="es_map", file_name=f"{dataset}.json")
es_config_path = Utilities.find_file_in_folder(folder_name="es_config", file_name=f"{dataset}.json")

# configure platforms
grs = ds.GeoRendering(config=dag_config["geo_rendering_service"],
                      source_connection_id=dag_config["denodo"]["connection_id"])
es23 = ds.Es23(dataset=dataset, config=dag_config["elasticsearch"],
               source_connection_id=dag_config["denodo"]["connection_id"])

# configure VictorOps notification level
vo_config = Variable.get('land.victorops', deserialize_json=True)
vo_routing_key = vo_config.get("endpoint")
vo_message_type = vo_config.get("message_type", "CRITICAL")

send_victor_ops_failure = functools.partial(notify_failure_victor_ops, endpoint=vo_routing_key,
                                            message_type=vo_message_type)

default_args = {
    'owner': 'land',
    'depends_on_past': False,
    'start_date': datetime(2017, 1, 1),
    'email': [str(x) for x in (Variable.get('land.emaillist', deserialize_json=True))],
    'email_on_failure': True,
    'retries': 0,
    # 'on_failure_callback': send_victor_ops_failure
}

dag = DAG(dag_id=dag_name,
          default_args=default_args,
          schedule_interval=dag_config['schedule'],
          max_active_runs=1,
          catchup=False,
          )

dag.doc_md = """####**Updates {dataset} from Data Warehouse to presentation tier**  \n
Config variable:  ```{dataset}```  \n
Data is loaded from source to new tables in the target location.  After post-loading counts are verified,
the newly loaded tables/index become the live ones. In the case where any of the loads fail, the dataset
is not flipped.  In the case where the flip fails on one or more of the targets, all the flips are rolled back to the
same state as before the data load began.  \n
**Source (DS9):**  \n
- connection: ```EV_DS9``` \n
- table: {dataset}  \n
**Target:**  \n
- Geo-rendering-service \n
""".format(dataset=dataset, es_alias=dag_config['elasticsearch']['alias'])


def current_state(**context):
    index_name = es23.current_state()
    # publish out name of current denodo tables, used in case denodo needs to rollback (used in view templates)
    context['ti'].xcom_push(key='elasticsearch_index', value=index_name)


capture_current_state = PythonOperator(
    task_id='capture_current_state',
    python_callable=current_state,
    provide_context=True,
    dag=dag
)


def get_index_name(index_type, context):
    index_name = '-'.join([index_type, context['ts_nodash'].lower()])
    context['ti'].xcom_push(key='elasticsearch_index', value=index_name)
    return index_name


def get_index_map():
    with open(es_map_path) as json_file:
        return json.load(json_file)


def extend_es_create_index_meta(context, meta):
    es_connection_ids = dag_config["elasticsearch"].get("connection_ids",
                                                        [dag_config["elasticsearch"]["connection_id"]])
    index_type = dag_config["elasticsearch"]['load23']['index_type']

    meta['ES_CONNECTION_CONFIG'] = json.dumps(build_es_config(es_connection_ids))
    meta['INDEX_NAME'] = get_index_name(index_type, context)
    meta['INDEX_MAP'] = json.dumps(get_index_map())
    return meta


DEFAULT_ES_LOADER_PARALLELISM = 10


def get_es_loader_workers():
    def _try_parse_workers_int(value):
        if value is None:
            return DEFAULT_ES_LOADER_PARALLELISM
        try:
            int_value = int(value)
            if int_value >= 1:
                return int_value
        except:
            return DEFAULT_ES_LOADER_PARALLELISM

    dag_config = Variable.get(dag_variable_name, deserialize_json=True)
    es_config = dag_config.get("elasticsearch", {})
    loaders_workers = es_config.get("loader_workers", None)

    return _try_parse_workers_int(loaders_workers)


create_elasticsearch_index = NomadDispatchOperator(
    task_id='create_elasticsearch_index',
    job_name='elasticsearch-loader_job',
    region='aws-ue1',
    meta={
        'ACTION': 'create_index',
    },
    extend_meta_fn=extend_es_create_index_meta,
    poll_interval_sec=30,
    params={
        'dataset': dataset,
    },
    dag=dag
)

join = EmptyOperator(
    task_id='join',
    dag=dag
)


def build_es_config(connection_ids):
    config = {}
    for connection_id in connection_ids:
        config[connection_id] = Connection.get_connection_from_secrets(connection_id).host
    return config


def build_sql_config(connection_id):
    conn = Connection.get_connection_from_secrets(connection_id)
    source_dbms = 'ms'
    if conn.conn_type == 'postgres':
        source_dbms = 'pg'
    return {"server": str(conn.host),
            'user': str(conn.login),
            'password': str(conn.password),
            'db': str(conn.schema),
            'source_dbms': source_dbms}


def get_indexer_config():
    with open(es_config_path) as json_file:
        return json.load(json_file)


def extend_es_load_dataset_meta(context, meta):
    def pull_index_name():
        _task_ids = context['params']['index_name']['task_ids']
        _task_key = context['params']['index_name']['key']
        _index_name = context['ti'].xcom_pull(task_ids=_task_ids, key=_task_key)

        return _index_name

    cfg = Variable.get('landtrac_lease', deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"]["connection_ids"]
    sql_connection_id = cfg["denodo"]["connection_id"]

    meta['ES_CONNECTION_CONFIG'] = json.dumps(build_es_config(es_connection_ids))
    meta['SQL_CONNECTION_CONFIG'] = json.dumps(build_sql_config(sql_connection_id))
    meta['INDEX_NAME'] = pull_index_name()
    es_loader_config = cfg.get('es_config', get_indexer_config())
    meta['INDEXER_CONFIG'] = json.dumps(es_loader_config)
    return meta


es_loader_tasks = []

es_loader_task_workers = get_es_loader_workers()

for task_index in range(es_loader_task_workers):
    load_task = NomadDispatchOperator(
        task_id=f"load_elastic_search_{task_index}",
        job_name='elasticsearch-loader_job',
        region='aws-ue1',
        meta={
            'ACTION': 'load_nested_dataset',
            'PROC_COUNT': str(es_loader_task_workers),
            'PROC_POSITION': str(task_index),
        },
        extend_meta_fn=extend_es_load_dataset_meta,
        poll_interval_sec=60,
        params={
            'dataset': dataset,
            'index_name': {
                'task_ids': 'create_elasticsearch_index',
                'key': 'elasticsearch_index',
            },
        },
        dag=dag
    )

    es_loader_tasks.append(load_task)

load_geo_rendering_service = PythonOperator(
    task_id='load_geo_rendering_service',
    python_callable=grs.loadv2,
    templates_dict={
        'source_table': dag_config["denodo"]["flip"]["view"],
        'nested_tables': [dag_config['geo_rendering_service']['nested_table'],
                          dag_config["denodo"]["flip"]["nested_table"]]
    },
    provide_context=True,
    dag=dag
)

stage_geo_rendering_load = PythonOperator(
    task_id='stage_geo_rendering_load',
    python_callable=grs.stage,
    provide_context=True,
    retries=3,
    retry_exponential_backoff=True,
    dag=dag
)


def extend_es_flip_meta(context, meta):
    cfg = Variable.get('landtrac_lease', deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])
    meta["ES_CONNECTION_CONFIG"] = json.dumps(build_es_config(es_connection_ids))
    meta["ALIASES"] = json.dumps(get_indexer_config()["aliases"])
    meta["TO_INDEX"] = context["ti"].xcom_pull(task_ids="create_elasticsearch_index", key="elasticsearch_index")
    return meta


flip_es_task = NomadDispatchOperator(
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
        'dataset': dataset,
    },
    dag=dag
)


def extend_es_delete_index_meta(context, meta):
    ti: TaskInstance = context['ti']
    ti.log.info(f"Extending META values for {ti.operator_name} ({ti.task_id})")

    cfg = Variable.get('landtrac_lease', deserialize_json=True)
    es_connection_ids = cfg["elasticsearch"].get("connection_ids", [cfg["elasticsearch"]["connection_id"]])

    ti.log.info(f"Building ES_CONNECTION_CONFIG with connection IDs: {es_connection_ids}")
    es_connection_config = build_es_config(es_connection_ids)

    index_name = ti.xcom_pull(task_ids="capture_current_state", key="elasticsearch_index")
    ti.log.info(f"Pulled index name from XComs: {index_name}")

    meta["ES_CONNECTION_CONFIG"] = json.dumps(es_connection_config)
    meta["INDEX_NAME"] = index_name
    return meta


cleanup_elasticsearch_index = NomadDispatchOperator(
    task_id="cleanup_es_index",
    job_name='elasticsearch-loader_job',
    region='aws-ue1',
    meta={
        'ACTION': 'delete_index',
    },
    extend_meta_fn=extend_es_delete_index_meta,
    poll_interval_sec=30,
    dag=dag
)

flip_grs_task = PythonOperator(
    task_id='flip_geo_rendering_service',
    python_callable=grs.flip,
    provide_context=True,
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    retries=3,
    retry_exponential_backoff=True,
    dag=dag
)

capture_current_state >> create_elasticsearch_index >> [*es_loader_tasks,
                                                        load_geo_rendering_service] >> join >> stage_geo_rendering_load >> [
    flip_es_task, flip_grs_task] >> cleanup_elasticsearch_index
'''

DEV_DAG = '''
from datetime import datetime
import json
import logging
import functools

from airflow import DAG
from airflow.models import Variable

from airflow.utils.trigger_rule import TriggerRule
from airflow.operators.dummy_operator import DummyOperator
from airflow.operators.dagrun_operator import TriggerDagRunOperator
from airflow.operators.python_operator import PythonOperator
from airflow.operators.msteams import MSTeamsWebhookOperator
from airflow.hooks.msteams import MSTeamsWebhookHook

import data_ops_dags.utils.datasync as ds
from data_ops_dags.utils.core.utilities import Utilities
from data_ops_dags.utils.core.victorops import notify_failure_victor_ops


dataset = 'landtrac_lease'
config = Variable.get(dataset, deserialize_json=True)

es_map_path   = Utilities.find_file_in_folder(folder_name="es_map",
                                              file_name="{dataset}.json".format(dataset=dataset))
es_config_path   = Utilities.find_file_in_folder(folder_name="es_config",
                                                 file_name="{dataset}.json".format(dataset=dataset))

# configure platforms
grs = ds.GeoRendering(config=config["geo_rendering_service"], source_connection_id=config["denodo"]["connection_id"])
es23 = ds.Es23(dataset=dataset, config=config["elasticsearch"], source_connection_id=config["denodo"]["connection_id"])

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

dag = DAG('landtrac_lease',
          default_args=default_args,
          schedule_interval=config['schedule'],
          max_active_runs=1
          )

dag.doc_md = """####**Updates {dataset} from Data Warehouse to presentation tier**  \n
Config variable:  ```{dataset}```  \n
Data is loaded from source to new tables in the target location.  After post-loading counts are verified,
the newly loaded tables/index become the live ones. In the case where any of the loads fail, the dataset
is not flipped.  In the case where the flip fails on one or more of the targets, all the flips are rolled back to the
same state as before the data load began.  \n
**Source (DS9):**  \n
- connection: ```DS9``` \n
- table: {dataset}  \n
**Target:**  \n
- Geo-rendering-service \n
""".format(dataset=dataset, es_alias=config['elasticsearch']['alias'])

def current_state(**context):
    index_name = es23.current_state()
    # publish out name of current denodo tables, used in case denodo needs to rollback (used in view templates)
    context['ti'].xcom_push(key='elasticsearch_index', value=index_name)

capture_current_state = PythonOperator(
    task_id='capture_current_state',
    python_callable=current_state,
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

for x in range(1, 11):
    load_elastic_search = PythonOperator(
        task_id='load_elastic_search_batch_{x}'.format(x=x),
        python_callable=es23.load,
        op_kwargs={
            'proc_count': 10,
            'proc_position': x,
            'sql_conn_id': config["denodo"]["connection_id"],
            'sql_schema': 'pres',
            'es_load_type': 'window',
            'es_conn_id': config["elasticsearch"]["connection_id"],
            'es_config_path': es_config_path
        },
        templates_dict={
            'index_name': "{{ task_instance.xcom_pull(task_ids='create_elasticsearch_index', key='elasticsearch_index') }}",
            'source_tables': json.dumps(config["denodo"]["flip"]["views"])
        },
        pool='elasticsearch_indexer',
        provide_context=True,
        queue="default_ash",
        dag=dag
    )
    create_elasticsearch_index >> load_elastic_search >> join

load_geo_rendering_service = PythonOperator(
    task_id='load_geo_rendering_service',
    python_callable=grs.loadv2,
    templates_dict={
        'source_table': config["denodo"]["flip"]["view"],
        'nested_tables': [config['geo_rendering_service']['nested_table'], config["denodo"]["flip"]["nested_table"]]
    },
    provide_context=True,
    dag=dag
)

stage_geo_rendering_load = PythonOperator(
    task_id='stage_geo_rendering_load',
    python_callable=grs.stage,
    provide_context=True,
    retries=3,
    retry_exponential_backoff=1,
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
    retries=3,
    retry_exponential_backoff=1,
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
    retries=3,
    retry_exponential_backoff=1,
    dag=dag
)

flip_grs_task = PythonOperator(
    task_id='flip_geo_rendering_service',
    python_callable=grs.flip,
    provide_context=True,
    on_success_callback=Utilities.set_flip_state_success,
    on_failure_callback=Utilities.set_flip_state_failure,
    retries=3,
    retry_exponential_backoff=1,
    dag=dag
)

# trigger_gds_load = TriggerDagRunOperator(
#     task_id='trigger_{}_gds_load'.format(dataset),
#     trigger_dag_id="{}_gds_load".format(dataset),
#     python_callable=Utilities.trigger_dag_run,
#     retries=0,
#     dag=dag
# )

notify_success = MSTeamsWebhookOperator(
    task_id='notify_success',
    trigger_rule=TriggerRule.ALL_SUCCESS,
    http_conn_id='ms_teams_land_notifications',
    message='Landtrac Lease has been updated successfully',
    theme_color='78BE20',
    dag=dag
)

notify_failure = MSTeamsWebhookOperator(
    task_id='notify_failure',
    trigger_rule=TriggerRule.ONE_FAILED,
    http_conn_id='ms_teams_land_notifications',
    message='Landtrac Lease has failed to update',
    theme_color='962D32',
    dag=dag
)

(capture_current_state >> create_elasticsearch_index >> load_geo_rendering_service >> join  >> stage_geo_rendering_load
 >> [flip_es_task, flip_grs_task] >> cleanup_elasticsearch_index >> [notify_success, notify_failure])
 '''

PROD_VARIABLES = {
	"row_count_tolerances": {
		"upper": 1.1,
		"lower": 1.005
	},
	"notifications": {
		"hipchat": {
			"rooms": [{
				"name": "Data Delivery",
				"token": "YB9AvrBGLscpS6fTQv6OI5sBPWXdOHLBM3mGovSI"
			}]
		}
	},
        "schedule": "0 12 * * *",
	"source": {
		"connection_id": "ds9",
		"tables": [
			"landtrac_lease",
			"lease_assignment_detail",
			"depthseverances"
		],
		"control_table": {
			"connection_id": "ds9_data_sync_control",
			"id": "landtrac_lease",
			"upstream_dependencies": [

			],
			"downstream_dependencies": [

			]
		}
	},
	"elasticsearch": {
		"connection_id": "es6",
		"alias": "landtrac-leases",
		"load23": {
			"index_type": "landtrac_lease"
		}
	},
	"denodo": {
		"connection_id": "ds9",
		"flip": {
			"views": [
				"pres.vw_landtrac_lease",
				"pres.vw_lease_assignment_detail",
				"pres.vw_depthseverances"
			],
                        "view":"pres.vw_landtrac_lease",
			"nested_table": "pres.vw_depthseverances"
		}
	},
	"geo_rendering_service": {
		"consul_datatype": "landtrac-leases",
		"datatype": "landtracLeases",
		"nested_table": "pres.lease_assignment_detail",
		"load_service": {
			"name": "geo-rendering-load-dotnet-service",
			"datacenters": ["vmw-ash"]
		}
	}
}

DEV_VARIABLES = {
  "row_count_tolerances": {
    "upper": 1.1,
    "lower": 1.005
  },
  "schedule": "0 12 * * *",
  "source": {
    "connection_id": "ev_ds9",
    "tables": [
      "landtrac_lease",
      "lease_assignment_detail",
      "depthseverances"
    ],
    "control_table": {
      "connection_id": "ev_ds9_data_sync_control",
      "id": "landtrac_lease",
      "upstream_dependencies": [],
      "downstream_dependencies": []
    }
  },
  "elasticsearch": {
    "connection_id": "es6",
    "connection_ids": [
      "es6"
    ],
    "loader_workers": 10,
    "alias": "landtrac-leases",
    "load23": {
      "index_type": "landtrac_lease"
    }
  },
  "denodo": {
    "connection_id": "ev_ds9",
    "flip": {
      "view": "pres.vw_landtrac_lease",
      "views": [
        "pres.vw_landtrac_lease",
        "pres.vw_lease_assignment_detail",
        "pres.vw_depthseverances"
      ],
      "nested_table": "pres.vw_depthseverances"
    }
  },
  "geo_rendering_service": {
    "consul_datatype": "landtrac-leases",
    "datatype": "landtracLeases",
    "nested_table": "pres.lease_assignment_detail",
    "load_service": {
      "name": "geo-rendering-load-dotnet-service",
      "datacenters": [
        "azure-hci-ash"
      ]
    }
  }
}

# fmt: on

# ---------------------------------------------------------------------------

def compare_source() -> bool:
    print(f"\n{'='*60}\nDAG SOURCE DIFF\n{'='*60}")
    diff = list(difflib.unified_diff(
        PROD_DAG.splitlines(keepends=True),
        DEV_DAG.splitlines(keepends=True),
        fromfile="prod",
        tofile="dev",
    ))
    if not diff:
        print("  No differences.")
        return True
    print("".join(diff))
    return False


def _flat_diff(prod, dev, path=""):
    """Recursively yield (path, prod_val, dev_val) for every leaf that differs."""
    if isinstance(prod, dict) and isinstance(dev, dict):
        all_keys = sorted(set(prod) | set(dev))
        for k in all_keys:
            child = f"{path}.{k}" if path else k
            if k not in dev:
                yield child, prod[k], "<missing>"
            elif k not in prod:
                yield child, "<missing>", dev[k]
            else:
                yield from _flat_diff(prod[k], dev[k], child)
    elif prod != dev:
        yield path, prod, dev


def compare_variables() -> bool:
    print(f"\n{'='*60}\nVARIABLES DIFF\n{'='*60}")
    diffs = list(_flat_diff(PROD_VARIABLES, DEV_VARIABLES))
    if not diffs:
        print("  No differences.")
        return True
    for path, prod_val, dev_val in diffs:
        print(f"\n  ~ {path}")
        print(f"      Prod: {json.dumps(prod_val, indent=2) if isinstance(prod_val, (dict, list)) else prod_val!r}")
        print(f"      Dev:  {json.dumps(dev_val, indent=2) if isinstance(dev_val, (dict, list)) else dev_val!r}")
    return False


if __name__ == "__main__":
    clean = compare_source() & compare_variables()
    print(f"\n{'='*60}")
    print("RESULT:", "CLEAN — no differences." if clean else "DIFFERENCES DETECTED — see above.")
    print(f"{'='*60}\n")
    sys.exit(0 if clean else 1)
