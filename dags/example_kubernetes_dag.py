"""
example_kubernetes_dag.py
~~~~~~~~~~~~~~~~~~~~~~~~~
A sample Apache Airflow DAG that demonstrates how to use the
KubernetesPodOperator alongside standard operators, written using
the TaskFlow API annotation format (@dag / @task decorators).

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

from airflow.decorators import dag, task
from airflow.operators.python import get_current_context
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
# DAG definition using the @dag annotation
# ---------------------------------------------------------------------------
@dag(
    dag_id="example_kubernetes_dag",
    description="Example DAG: local Docker testing + Kubernetes pod tasks",
    schedule=timedelta(days=1),
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["example", "kubernetes"],
)
def example_kubernetes_dag():
    # ------------------------------------------------------------------
    # Task 1 – @task.bash: simple shell command, runs inside the
    #           Airflow worker container (or locally in Docker Compose).
    # ------------------------------------------------------------------
    @task.bash
    def greet() -> str:
        return 'echo "Starting pipeline at $(date)"'

    # ------------------------------------------------------------------
    # Task 2 – @task: arbitrary Python logic that also runs
    #           inside the Airflow worker process.
    # ------------------------------------------------------------------
    @task
    def generate_data() -> dict:
        """Simulate producing a small payload pushed to XCom."""
        context = get_current_context()
        payload = {"batch_id": context["run_id"], "items": list(range(5))}
        print(f"Generated payload: {payload}")
        return payload

    # ------------------------------------------------------------------
    # Task 3 – @task.kubernetes: launches a disposable pod in the
    #           configured Kubernetes cluster.  The decorated function
    #           body runs inside a lightweight Python image.
    #
    #   • in_cluster=False  → uses ~/.kube/config (local testing / CI)
    #   • in_cluster=True   → uses the pod's service-account token
    #                          (set via AIRFLOW__KUBERNETES__IN_CLUSTER)
    #
    #   Override `namespace` and `image` to match your environment.
    # ------------------------------------------------------------------
    @task.kubernetes(
        name="airflow-process-data-pod",
        namespace="airflow",
        image="python:3.11-slim",
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
    def process_data():
        # Imports must live inside @task.kubernetes functions because the
        # function body is serialised and executed inside the remote pod.
        import json  # noqa: PLC0415

        data = {"status": "processed", "result": [x**2 for x in range(5)]}
        print(json.dumps(data))

    # ------------------------------------------------------------------
    # Task 4 – @task.bash: final summary step.
    # ------------------------------------------------------------------
    @task.bash
    def summarize() -> str:
        return 'echo "Pipeline complete at $(date)"'

    # ------------------------------------------------------------------
    # Task dependency chain
    # ------------------------------------------------------------------
    greet() >> generate_data() >> process_data() >> summarize()


example_kubernetes_dag()
