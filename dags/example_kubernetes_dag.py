"""
example_kubernetes_dag.py
~~~~~~~~~~~~~~~~~~~~~~~~~
A sample Apache Airflow DAG that demonstrates how to use the
KubernetesPodOperator alongside standard operators.

Local testing (Docker Compose)
-------------------------------
Run `docker compose up -d` from the repo root.  The scheduler will pick up
this file from ./dags and make it available in the web UI at
http://localhost:8080.  The KubernetesPodOperator tasks will use the kubeconfig
mounted at ~/.kube/config to spin up pods in the configured namespace.

Kubernetes deployment
---------------------
When the Airflow deployment itself lives inside a Kubernetes cluster (see
kubernetes/ for the manifests) the KubernetesPodOperator tasks run in the
same cluster with in-cluster authentication.  Set the environment variable
  AIRFLOW__KUBERNETES__IN_CLUSTER=true
in the Deployment manifests to enable this mode.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client import models as k8s

# ---------------------------------------------------------------------------
# Default arguments applied to every task in the DAG
# ---------------------------------------------------------------------------
default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

# ---------------------------------------------------------------------------
# DAG definition
# ---------------------------------------------------------------------------
with DAG(
    dag_id="example_kubernetes_dag",
    description="Example DAG: local Docker testing + Kubernetes pod tasks",
    schedule=timedelta(days=1),
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["example", "kubernetes"],
) as dag:

    # ------------------------------------------------------------------
    # Task 1 – BashOperator: simple shell command, runs inside the
    #           Airflow worker container (or locally in Docker Compose).
    # ------------------------------------------------------------------
    greet = BashOperator(
        task_id="greet",
        bash_command='echo "Starting pipeline at $(date)"',
    )

    # ------------------------------------------------------------------
    # Task 2 – PythonOperator: arbitrary Python logic that also runs
    #           inside the Airflow worker process.
    # ------------------------------------------------------------------
    def _generate_data(**context) -> dict:
        """Simulate producing a small payload pushed to XCom."""
        payload = {"batch_id": context["run_id"], "items": list(range(5))}
        print(f"Generated payload: {payload}")
        return payload

    generate_data = PythonOperator(
        task_id="generate_data",
        python_callable=_generate_data,
    )

    # ------------------------------------------------------------------
    # Task 3 – KubernetesPodOperator: launches a disposable pod in the
    #           configured Kubernetes cluster.  The pod runs a lightweight
    #           Python image to simulate a processing step.
    #
    #   • in_cluster=False  → uses ~/.kube/config (local testing / CI)
    #   • in_cluster=True   → uses the pod's service-account token
    #                          (set via AIRFLOW__KUBERNETES__IN_CLUSTER)
    #
    #   Override `namespace` and `image` to match your environment.
    # ------------------------------------------------------------------
    process_data = KubernetesPodOperator(
        task_id="process_data",
        name="airflow-process-data-pod",
        namespace="airflow",
        image="python:3.11-slim",
        cmds=["python", "-c"],
        arguments=[
            (
                "import json, sys; "
                "data = {'status': 'processed', 'result': [x**2 for x in range(5)]}; "
                "print(json.dumps(data))"
            )
        ],
        # Resource requests keep the demo pod small
        container_resources=k8s.V1ResourceRequirements(
            requests={"cpu": "100m", "memory": "128Mi"},
            limits={"cpu": "200m", "memory": "256Mi"},
        ),
        # Delete the pod after it finishes so the cluster stays clean
        on_finish_action="delete_pod",
        get_logs=True,
        # Use in-cluster config when running inside Kubernetes;
        # set to False (default) when testing locally via Docker Compose.
        in_cluster=False,
    )

    # ------------------------------------------------------------------
    # Task 4 – BashOperator: final summary step.
    # ------------------------------------------------------------------
    summarize = BashOperator(
        task_id="summarize",
        bash_command='echo "Pipeline complete at $(date)"',
    )

    # ------------------------------------------------------------------
    # Task dependency chain
    # ------------------------------------------------------------------
    greet >> generate_data >> process_data >> summarize
