# homelab-iac

[![pipeline](https://git.jacklouallen.info/jackl/homelab-iac/badges/main/pipeline.svg)](https://git.jacklouallen.info/jackl/homelab-iac/-/pipelines)

My cybersecurity oriented homelab infrastructure-as-code.

The primary copy of this repository is on a self-hosted GitLab, [git.jacklouallen.info/jackl/homelab-iac](https://git.jacklouallen.info/jackl/homelab-iac). This GitHub repository mirrors its `main` branch. Every push runs the [pipeline](.gitlab-ci.yml): a secrets scan of the full history, `ansible-lint` at the production profile, the Python tests, the edge nginx configuration exercised in a container, and `tofu validate` for each OpenTofu module.
