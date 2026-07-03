# MLflow on AWS Fargate with OpenTofu

Provision a serverless [MLflow](https://mlflow.org/) tracking server on AWS using
[OpenTofu](https://opentofu.org/) (or Terraform). The server runs on AWS Fargate behind a
Network Load Balancer, stores artifacts in Amazon S3, and uses an Amazon RDS for MySQL
instance as its backend store.

## Architecture

```
Client ──▶ Network Load Balancer ──▶ ECS Fargate (MLflow server) ──┬──▶ Amazon S3   (artifact store)
                                                                    └──▶ Amazon RDS  (MySQL backend store)
                                     Amazon ECR ──▶ container image
```

| Component | Purpose |
| --- | --- |
| VPC (`terraform-aws-modules/vpc`) | Public, private, and isolated subnets across 2 AZs with a single NAT gateway |
| ECR | Stores the MLflow container image |
| ECS Fargate | Runs the MLflow server (default 4 vCPU / 8 GB) |
| Network Load Balancer | Exposes the MLflow UI/API on port 80 |
| RDS MySQL 8.4 | Backend store for experiments, runs, and the model registry |
| S3 | Artifact store |
| Secrets Manager | Holds the generated database password |
| Auto Scaling | Scales the Fargate service on CPU utilization (max 2 tasks) |

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) `>= 1.6` (or Terraform)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with credentials
- A container CLI: [Docker](https://www.docker.com/) or [Podman](https://podman.io/) (used to build and push the image)
- An S3 bucket for remote state (see [`backend.tf`](backend.tf))

## Configuration

Key variables (see [`var.tf`](var.tf)):

| Variable | Default | Description |
| --- | --- | --- |
| `region` | `us-east-1` | AWS region |
| `project_name` | `mlflow` | Prefix used for resource names |
| `db_name` | `mlflowdb` | Backend database name |
| `db_username` | `master` | Backend database user |
| `db_port` | `3306` | Backend database port |
| `container_port` | `5000` | Port the MLflow server listens on |
| `container_cli` | `docker` | CLI used to build/push the image (`docker` or `podman`) |

## Deploy

Using the helper script (auto-detects `docker`/`podman` and `tofu`/`terraform`):

```bash
./deploy_stack.sh apply mlflow
```

Or directly:

```bash
tofu init
tofu apply -var project_name=mlflow -var container_cli=podman
```

When it finishes, the MLflow tracking server URL is printed as the `mlflow_url` output.

## Use with your ML workflow

Point your code at the tracking server:

```python
import mlflow
mlflow.set_tracking_uri("http://<load-balancer-dns>")
```

Example notebooks are provided in [`lab/`](lab/):

- `1_track_experiments.ipynb`
- `2_track_experiments_hpo.ipynb`
- `3_deploy_model.ipynb`

## Tear down

```bash
./deploy_stack.sh destroy mlflow
```

> If the S3 artifact bucket contains objects, empty it first
> (`aws s3 rm s3://<project_name>-artifacts-<account-id> --recursive`) or add
> `force_destroy = true` to the bucket resource.

## Cost

The Fargate task (4 vCPU / 8 GB) is the main cost driver. Reduce `cpu`/`memory` in the task
definition for lighter dev/test usage, and always run `destroy` when you are done.

## Notes

- The Network Load Balancer is internet-facing by default. For production, consider an internal
  load balancer in private subnets.
- Open-source MLflow does not provide built-in user access control; anyone who can reach the
  server can modify experiments and models.

## License

Licensed under the MIT License. See [`LICENSE`](LICENSE).
