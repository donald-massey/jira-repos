"""DAG comparison — paste DAG source and fill variables below, then run: python compare.py"""

import difflib
import json
import sys

# fmt: off

PROD_DAG = '''
import ast
import json
import time
import boto3
from airflow import DAG
from datetime import datetime
from airflow.models import Variable
from airflow.hooks.base_hook import BaseHook
from airflow.hooks.http_hook import HttpHook
from airflow.utils.log.logging_mixin import LoggingMixin
from airflow.operators import PythonOperator, DummyOperator
from airflow.operators.nomad_dispatch_job_plugin import NomadDispatchOperator

config = Variable.get('land_lease_producer', deserialize_json=True)


class DataBricksServerError(Exception):
    pass


class DataBricksRunException(Exception):
    pass


class AWSGlueRunException(Exception):
    pass


default_args = {
    'owner': 'stage',
    'depends_on_past': False,
    'email': config['email_on_failure'],
    'email_on_failure': True,
    'retries': 0
}

dag = DAG(
    dag_id='land_lease_producer',
    start_date=datetime(2021, 1, 7),
    default_args=default_args,
    schedule_interval=config['schedule'],
    max_active_runs=1,
    catchup=False
)

dag.doc_md = """####**land-lease-producer** \n
Launches DataBricks Notebook that converts XML strings into WKT format, then using the Shapely library verifies each geometry is valid. \n
If the geometries are invalid repairs them and appends the geometries to a defaultdict(list). \n
Then the Polygons/MultiPolygons are checked whether they are contained within another, if so they are removed from the containing geometry. \n
Next, the geometries are loaded into a GeoPandas DataFrame and the CRS are applied in this order CRS: 4267 -> CRS: 4269 -> CRS: 4326 \n
Finally, the geometries are validated and insert into the target table. \n
The DataBricks Notebook source code can be found in [land.landtracs-geom-update-spark](https://github.com/enverus-ea/land.landtracs-geom-update-spark) \n
**Source: (gis_stage.gis_stg.V_Landtrac_SVG_XML)** \n
**Target: (gis_exports.sde.DI_LANDTRAC_POLYGONS)** \n
--- \n
Next, the land_lease_producer_job pulls from CSTitle/Div1 and produces messages to kafka topic. \n
[https://git.drillinginfo.com/Land/land-lease-producer](https://git.drillinginfo.com/Land/land-lease-producer) \n
--- \n
Finally, dispatches [land-aws-glue](https://git.drillinginfo.com/Land/land-aws-glue) to move data from Kafka to S3/DS9/Hendrix/ElasticSearch \n

    Variables: land_lease_producer
    Connections: [land_aws_svc, land.databricks]
    Triggers: https://git.drillinginfo.com/Land/land-aws-glue
"""


class DataBricks(object):

    def __init__(self, config):
        self._runid = None
        self._jobid = config['job_id']
        self._connection_id = config['connection_id']
        self._databricks_token = BaseHook.get_connection(self._connection_id).password

        self._headers = {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + self._databricks_token
        }

    def submit_async_job(self):
        """
        Submits a DataBricks JobID. The submittal is asynchronous, and the ID of the running job is returned
        immediately, regardless of job status.

        :return:
        """

        payload = {"job_id": self._jobid}
        api_path = '/api/2.1/jobs/run-now'
        post_http_hook = HttpHook(http_conn_id=self._connection_id, method='POST')
        post_http_hook.get_conn(self._headers)
        r = post_http_hook.run(api_path, headers=self._headers, data=json.dumps(payload))

        if r.status_code == 200:
            try:
                self._runid = r.json()['run_id']
                return
            except KeyError:
                raise DataBricksServerError(
                    'Job submitted successfully but no job id returned. Response from server: {}'.format(r.content))
        elif r.status_code == 400:
            raise DataBricksServerError('Status code 400: Supplied value for a parameter was invalid.')
        elif r.status_code == 401:
            raise DataBricksServerError(
                'Status code 401: The request does not have valid authentication credentials for the operation.')
        elif r.status_code == 403:
            raise DataBricksServerError(
                'Status code 403: Caller does not have permission to execute the specified operation.')
        elif r.status_code == 404:
            raise DataBricksServerError(
                'Status code 404: If a given user/entity is trying to use a feature which has been disabled.')
        elif r.status_code == 429:
            raise DataBricksServerError(
                'Status code 429: Request is rejected due to throttling.')
        elif r.status_code == 500:
            raise DataBricksServerError(
                'Status code 500: Internal error.')
        else:
            raise DataBricksServerError('Status code {}: Unknown error'.format(r.status_code))

    def monitor_job_status(self, runid, check_interval=30):
        """
        Given an ID, this retrieves the record for a transformation job, regardless of whether it is queued,
        running or completed.
        :param runid: int or str: the Run Id of the DataBricks job.
        :param check_interval: int Number of seconds to wait between pinging the server for status updates.
        :return:
        """

        api_path = '/api/2.1/jobs/runs/get?run_id={}'.format(runid)
        get_http_hook = HttpHook(http_conn_id=self._connection_id, method='GET')
        get_http_hook.get_conn(self._headers)

        result_state = "NONE"
        life_cycle_state = "STARTED"
        conn_errors = 0
        while life_cycle_state.upper() in ["PENDING", "QUEUED", "RUNNING", "STARTED", "STARTED_RUNNING"]:
            time.sleep(check_interval)
            try:
                r = get_http_hook.run(api_path, headers=self._headers)
            except ConnectionError:
                conn_errors += 1
                if conn_errors > 10:
                    raise
                else:
                    continue
            if r.status_code == 200:
                try:
                    life_cycle_state = r.json()['state']['life_cycle_state']
                    LoggingMixin().log.info('life_cycle_state: ' + life_cycle_state)
                except KeyError:
                    raise DataBricksServerError('Request successful but no job status returned. Response from server: \
                    {}'.format(r.content))
            elif r.status_code == 400:
                raise DataBricksServerError(
                    'Status code 400: Supplied value for a parameter was invalid.')
            elif r.status_code == 401:
                raise DataBricksServerError('Status code 401: The request does not have valid authentication \
                credentials for the operation.')
            elif r.status_code == 403:
                raise DataBricksServerError('Status code 403: Caller does not have permission to execute the specified \
                operation.')
            elif r.status_code == 429:
                raise DataBricksServerError('Status code 429: Request is rejected due to throttling.')
            elif r.status_code == 500:
                raise DataBricksServerError('Status code 500: Internal error.')

            if result_state == "NONE":
                try:
                    result_state = r.json()['state']['result_state']
                except KeyError:
                    pass

            if result_state.upper() == "SUCCEEDED":
                LoggingMixin().log.info('DataBricks Job {runid} finished successfully.'.format(runid=runid))
                return

            elif result_state.upper() in ["CANCELED", "FAILED", "TIMEDOUT", "SKIPPED",
                                          "MAXIMUM_CONCURRENT_RUNS_REACHED", "INTERNAL_ERROR", "BLOCKED",
                                          "SUCCESS_WITH_FAILURES", "UPSTREAM_FAILED", "UPSTREAM_CANCELED"]:
                r = get_http_hook.run(api_path, headers=self._headers, extra_options={})
                message = r.json()['state']['state_message']
                raise DataBricksServerError('DataBricks Job {0} Failed: {1}: {2}'.format(runid, life_cycle_state,
                                                                                         message))


class LandtracsGeomUpdate(DataBricks):
    """
    subclass of DataBricks() basically extends key features (e.g. job monitoring, submission) for a specific job
    definition (provided by config) config is found under the "DataBricks" key in variable
    "datadelivery.landtracs_geom_update"
    """

    def submit_job(self):  # submit the job
        self.submit_async_job()

        if self._runid:
            self.monitor_job_status(self._runid)
            return True
        else:
            raise DataBricksRunException('Received None-Type job id from submit_job!')


class AWSGlue(object):

    def __init__(self, config):
        self.config = config
        self.response = None
        self._aws_token = ast.literal_eval(BaseHook.get_connection(self.config['connection_id']).password)
        self.session = boto3.session.Session(aws_access_key_id=self._aws_token['key'],
                                             aws_secret_access_key=self._aws_token['secret'],
                                             region_name=self.config['region_name'])
        self.glue_client = self.session.client('glue')

    def start_job(self):
        try:
            self.response = self.glue_client.start_job_run(JobName=self.config["glue_job_name"])
            LoggingMixin().log.info('self.response: {response}'.format(response=self.response))
        except Exception as e:
            raise AWSGlueRunException('Failed to start Glue Job, exception: {e}'.format(e=e))

        if self.response:
            return
        else:
            raise AWSGlueRunException('Failed to start Glue job, response: {response}'.format(response=self.response))

    def monitor_job_status(self, check_interval=30):
        job_run_state = "STARTING"

        while job_run_state.upper() in ["STARTING", "RUNNING"]:
            LoggingMixin().log.info('job_run_state: {0}; job_run_id: {1}'
                                    .format(job_run_state, self.response["JobRunId"]))
            time.sleep(check_interval)
            try:
                job_run_state = self.glue_client.get_job_run(JobName=self.config["glue_job_name"],
                                                             RunId=self.response["JobRunId"])["JobRun"]["JobRunState"]
            except Exception as e:
                raise AWSGlueRunException('Failed to get Glue Job status, exception: {e}'.format(e=e))

            if job_run_state.upper() in ["SUCCEEDED"]:
                LoggingMixin().log.info('Glue Job {job_run_id} finished successfully.'.format(
                    job_run_id=self.response["JobRunId"]))
                return

            elif job_run_state.upper() in ["STOPPED", "FAILED", "TIMEOUT", "ERROR"]:
                raise AWSGlueRunException('Glue Job failed, state: {0}; job_run_id: {1}'
                                          .format(job_run_state, self.response["JobRunId"]))


class LandtracsAWSGlue(AWSGlue):

    def submit_job(self):
        self.start_job()
        self.monitor_job_status()

def submit_landtracs_geom_update_job_callable():
    job = LandtracsGeomUpdate(config=config['databricks'])
    job.submit_job()

def submit_landtracs_aws_glue_callable():
    job = LandtracsAWSGlue(config=config)
    job.submit_job()

submit_landtracs_geom_update_job = PythonOperator(
    task_id='submit_landtracs_geom_update_spark',
    python_callable=submit_landtracs_geom_update_job_callable,
    trigger_rule='all_done',
    provide_context=False,
    dag=dag
)

submit_landtracs_aws_glue = PythonOperator(
    task_id='submit_landtracs_aws_glue',
    python_callable=submit_landtracs_aws_glue_callable,
    trigger_rule='all_done',
    provide_context=False,
    dag=dag
)

ch_lease_exporter_tasks = []
number_of_ch_lease_exporter_successive_tasks = 7
for i in range(number_of_ch_lease_exporter_successive_tasks):
    task = NomadDispatchOperator(
        dag=dag,
        task_id='ch_lease_exporter_{}'.format(str(i + 1)),
        job_name='ch_lease_exporter_job',
        region='vmw-ash',
        meta=None,
        poll=config["poll"],
        poll_interval_sec=config["poll_interval_sec"],
        trigger_rule='all_done'
    )
    ch_lease_exporter_tasks.append(task)
for i in range(len(ch_lease_exporter_tasks) - 1):
    ch_lease_exporter_tasks[i] >> ch_lease_exporter_tasks[i + 1]

ch_lease_exporter_tasks[-1] >> submit_landtracs_geom_update_job
for x in range(config["jobs"]):
    task_id = "nomad_land_lease_producer_job_{}".format(str(x + 1))
    nomad_job = NomadDispatchOperator(
        dag=dag,
        task_id=task_id,
        job_name='land_lease_producer_job',
        region='vmw-ash',
        trigger_rule='all_done',
        meta=None,
        poll=config["poll"],
        poll_interval_sec=config["poll_interval_sec"]
    )
    submit_landtracs_geom_update_job >> nomad_job >> submit_landtracs_aws_glue
'''

DEV_DAG = '''
from __future__ import annotations
from typing import Optional, Union, Any, Dict, List, Iterator
from datetime import datetime
from pydantic import BaseModel, Field


from airflow import DAG
from airflow.models import Variable, BaseOperator
from airflow.utils.trigger_rule import TriggerRule
from airflow.providers.databricks.operators.databricks import DatabricksRunNowOperator
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

from enverus.custom_operator.nomad_dispatch_operator import NomadDispatchOperator


dag_doc = """\
# land_lease_producer

## Summary:

Launches DataBricks Notebook that converts XML strings into WKT format, then using the Shapely library verifies each geometry is valid.

If the geometries are invalid repairs them and appends the geometries to a defaultdict(list).

Then the Polygons/MultiPolygons are checked whether they are contained within another, if so they are removed from the containing geometry.

Next, the geometries are loaded into a GeoPandas DataFrame and the CRS are applied in this order CRS: 4267 -> CRS: 4269 -> CRS: 4326

Finally, the geometries are validated and insert into the target table.

The DataBricks Notebook source code can be found in [land.landtracs-geom-update-spark](https://github.com/enverus-ea/land.landtracs-geom-update-spark) 

**Source: (gis_stage.gis_stg.V_Landtrac_SVG_XML)**
**Target: (gis_exports.sde.DI_LANDTRAC_POLYGONS)**

--- 
Next, the land_lease_producer_job pulls from CSTitle/Div1 and produces messages to kafka topic.
[https://git.drillinginfo.com/Land/land-lease-producer](https://git.drillinginfo.com/Land/land-lease-producer) 

--- 
Finally, dispatches [land-aws-glue](https://git.drillinginfo.com/Land/land-aws-glue) to move data from Kafka to S3/DS9/Hendrix/ElasticSearch

## Config:

**Variable:**
- land_lease_producer
```json
{
  "schedule": "0 17 * * *",
  "email_on_failure": true,
  "email": [
    "..."
  ],
  "aws_glue": {
    "connection_id": "aws_default",
    "region": "us-east-1",
    "glue_job_name": "land-dev-kafka-to-adl"
  },
  "databricks": {
    "connection_id": "ev_databricks",
    "job_id": "178246000480874"
  },
  "nomad": {
    "ch_lease_exporter": {
      "connection_id": "ev_nomad",
      "job_name": "ch_lease_exporter_job",
      "region": "vmw-ash",
      "meta": null,
      "poll": true,
      "poll_interval_sec": 60,
      "jobs": 7
    },
    "land_lease_producer": {
      "connection_id": "ev_nomad",
      "job_name": "land_lease_producer_job",
      "region": "vmw-ash",
      "meta": null,
      "poll": true,
      "poll_interval_sec": 60,
      "jobs": 1
    }
  }
}
```

**Connections:**
- aws_default
- ev_databricks
- ev_nomad

**Triggers:**
 - https://git.drillinginfo.com/Land/land-aws-glue
"""

# -----------------------------------------------------------------------------
# DAG Variable Model
# -----------------------------------------------------------------------------
class LeaseProducerNomadJobConfig(BaseModel):
    connection_id: str = Field(default="ev_nomad")
    job_name: str
    region: str
    meta: Optional[Dict[str, Any]] = None
    poll: Optional[bool] = Field(default=True)
    poll_interval_sec: Optional[int] = Field(default=60)
    jobs: Optional[int] = Field(default=1)

class LeaseProducerNomadConfig(BaseModel):
    ch_lease_exporter: LeaseProducerNomadJobConfig
    land_lease_producer: LeaseProducerNomadJobConfig

class LeaseProducerAWSGlueJobConfig(BaseModel):
    connection_id: Optional[str] = Field(default="aws_default")
    region: Optional[str] = Field(default="us-east-1")
    glue_job_name: str

class LeaseProducerDatabricksConfig(BaseModel):
    connection_id: str
    job_id: str

class LeaseProducerConfig(BaseModel):
    schedule: str
    email_on_failure: Optional[bool] = Field(default=True)
    email: Optional[Union[str, List[str]]] = Field(default_factory=list)
    owner: str = Field(default="stage")
    retries: int = Field(default=0)
    depends_on_past: bool = Field(default=False)
    aws_glue: LeaseProducerAWSGlueJobConfig
    databricks: LeaseProducerDatabricksConfig
    nomad: LeaseProducerNomadConfig

    def get_dag_default_args(self) -> Dict[str, Any]:

        # Check if "email" is a single string, list of strings, or None
        if isinstance(self.email, str):
            email_list = [self.email]
        elif isinstance(self.email, list) and len(self.email) > 0:
            email_list = self.email
        else:
            email_list = []

        # Determine whether to send emails based on the email_on_failure property and email_list
        if self.email_on_failure is None or self.email_on_failure == True:
            send_emails = True if len(email_list) > 0 else False
        else:
            send_emails = False

        return {
            "owner": self.owner,
            "depends_on_past": self.depends_on_past,
            "email_on_failure": send_emails,
            "email": email_list,
            "retries": self.retries
        }





# -----------------------------------------------------------------------------
# DAG Definition
# -----------------------------------------------------------------------------
DAG_NAME = "land_lease_producer"

# Pull DAG variable as a string
dag_var_json = Variable.get(DAG_NAME, deserialize_json=False)

# Parse and validate DAG variable against model
dag_config = LeaseProducerConfig.model_validate_json(dag_var_json)


with DAG(
    dag_id=DAG_NAME,
    start_date=datetime(2021, 1, 7),
    schedule_interval=dag_config.schedule,
    default_args=dag_config.get_dag_default_args(),
    max_active_runs=1,
    catchup=False
) as dag:

    # SET DAG DOC IN UI
    dag.doc_md = dag_doc


    # Declare all the ch_lease_exporter Nomad Jobs
    ch_lease_exporter_tasks = []
    for x in range(dag_config.nomad.ch_lease_exporter.jobs):

        # If there is only 1 job, there is no suffix, if there are multiple then make the task_id end in "_{x + 1}"
        task_id_suffix = "" if dag_config.nomad.ch_lease_exporter.jobs == 1 else f"_{x + 1}"
        task_id = "nomad_" + dag_config.nomad.ch_lease_exporter.job_name.replace("-", "_") + task_id_suffix

        nomad_job = NomadDispatchOperator(
            task_id=task_id,
            connection_id=dag_config.nomad.ch_lease_exporter.connection_id,
            job_name=dag_config.nomad.ch_lease_exporter.job_name,
            region=dag_config.nomad.ch_lease_exporter.region,
            meta=dag_config.nomad.ch_lease_exporter.meta,
            poll=dag_config.nomad.ch_lease_exporter.poll,
            poll_interval_sec=dag_config.nomad.ch_lease_exporter.poll_interval_sec,
            trigger_rule=TriggerRule.ALL_DONE
        )
        ch_lease_exporter_tasks.append(nomad_job)


    # Declare all the land_lease_producer Nomad Jobs
    land_lease_producer_tasks = []
    for x in range(dag_config.nomad.land_lease_producer.jobs):

        # If there is only 1 job, there is no suffix, if there are multiple then make the task_id end in "_{x + 1}"
        task_id_suffix = "" if dag_config.nomad.land_lease_producer.jobs == 1 else f"_{x + 1}"
        task_id = "nomad_" + dag_config.nomad.land_lease_producer.job_name.replace("-", "_") + task_id_suffix

        nomad_job = NomadDispatchOperator(
            task_id=task_id,
            connection_id=dag_config.nomad.land_lease_producer.connection_id,
            job_name=dag_config.nomad.land_lease_producer.job_name,
            region=dag_config.nomad.land_lease_producer.region,
            meta=dag_config.nomad.land_lease_producer.meta,
            poll=dag_config.nomad.land_lease_producer.poll,
            poll_interval_sec=dag_config.nomad.land_lease_producer.poll_interval_sec,
            trigger_rule=TriggerRule.ALL_DONE
        )
        land_lease_producer_tasks.append(nomad_job)


    # Declare the Databricks landtracs_geom_update Spark job
    submit_landtracs_geom_update_spark_task = DatabricksRunNowOperator(
        task_id="submit_landtracs_geom_update_spark",
        databricks_conn_id=dag_config.databricks.connection_id,
        job_id=dag_config.databricks.job_id,
        wait_for_termination=True
    )

    # Declare the landtracs AWS Glue job
    submit_landtracs_aws_glue_task = GlueJobOperator(
        task_id="submit_landtracs_aws_glue",
        aws_conn_id=dag_config.aws_glue.connection_id,
        region_name=dag_config.aws_glue.region,
        job_name=dag_config.aws_glue.glue_job_name,
        wait_for_completion=True,
    )

    # The order of the tasks should be:
    # 1. All the ch_lease_exporter Nomad jobs
    # 2. The Databricks landtracs_geom_update_spark job
    # 3. All the land_lease_producer Nomad jobs
    # 4. The AWS Glue job land-dev-kafka-to-adl
    all_tasks = [
        *ch_lease_exporter_tasks,
        submit_landtracs_geom_update_spark_task
    ]

    task_iter: Iterator[BaseOperator] = iter(all_tasks)
    prev_task: BaseOperator = next(task_iter)

    for current_task in task_iter:
        prev_task.set_downstream(current_task)
        prev_task = current_task


    all_tasks[-1].set_downstream([*land_lease_producer_tasks])

    submit_landtracs_aws_glue_task.set_upstream([*land_lease_producer_tasks])
'''

PROD_VARIABLES = {
    "schedule": "0 23 * * *",
    "notify_on_failure": ["@all"],
    "email_on_failure": ["LandDevTeam@drillinginfo.com"],
    "poll": True,
    "poll_interval_sec": 60,
    "connection_id": "land_aws_svc",
    "glue_job_name": "land-prod-kafka-to-adl",
    "region_name": "us-east-1",
    "databricks": {
        "job_id": "81309356829448",
        "connection_id": "land.databricks"
    },
    "jobs": 12
}

DEV_VARIABLES = {
  "schedule": "0 17 * * *",
  "owner": "stage",
  "email_on_failure": True,
  "email": [
    "chris.sekira@drillinginfo.com",
    "LandDevTeam@drillinginfo.com"
  ],
  "aws_glue": {
    "connection_id": "ev_aws_legacy_airflow_svc",
    "region": "us-east-1",
    "glue_job_name": "land-dev-kafka-to-adl"
  },
  "databricks": {
    "connection_id": "ev_aws_databricks_land_sp",
    "job_id": "665399352133077"
  },
  "nomad": {
    "ch_lease_exporter": {
      "connection_id": "ev_nomad",
      "job_name": "ch_lease_exporter_job",
      "region": "azure-hci-ash",
      "meta": None,
      "poll": True,
      "poll_interval_sec": 60,
      "jobs": 7
    },
    "land_lease_producer": {
      "connection_id": "ev_nomad",
      "job_name": "land_lease_producer_job",
      "region": "azure-hci-ash",
      "meta": None,
      "poll": True,
      "poll_interval_sec": 60,
      "jobs": 12
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
