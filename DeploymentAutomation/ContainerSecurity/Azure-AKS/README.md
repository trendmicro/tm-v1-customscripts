# Automated Container Security Deployment on AKS

This repository documents and centralizes the processes used to automate the deployment of **Trend Vision One - Container Security** on **Azure Kubernetes Service (AKS)** clusters.

## Objective

The purpose of this space is to document (scripts, templates, and procedures) the steps required to implement Container Security in an **automated and repeatable** way across large-scale infrastructures — that is, environments with a large number of existing AKS clusters/resources, where a manual, cluster-by-cluster installation is neither viable nor sustainable over time.

## Context and Scope

In large-scale infrastructures, the Container Security deployment must meet the following requirements:

- **Automation over existing resources**: the processes documented here are designed to be applied to already provisioned (brownfield) AKS clusters, without relying on protection being included from the initial provisioning.
- **Scalability**: the scripts and workflows must be able to run against multiple subscriptions, resource groups, and clusters at scale, without manual intervention per resource.
- **100% coverage**: the end goal is to ensure and maintain that **all** AKS clusters in scope have Container Security deployed and operational, including the detection and remediation of clusters that fall out of compliance (drift) due to new deployments or configuration changes.
- **Ongoing maintenance**: this is not just an initial deployment — it also requires processes that periodically verify the state of the protection and reapply the configuration when necessary.

## Content

The following items will be added to this folder over time, as they are documented:

- Automated deployment scripts (CLI/Az CLI, Terraform, Bicep, Helm, etc.)
- Configuration templates (`overrides.yaml` and similar) for Container Security on AKS
- Coverage validation/auditing processes over the cluster portfolio
- Step-by-step guides for large-scale deployment scenarios

## Requirements

- Azure subscription with sufficient permissions over the target AKS resources
- Trend Vision One account with access to Container Security
- Command-line tools: Azure CLI, `kubectl`, `helm` (depending on the script)
